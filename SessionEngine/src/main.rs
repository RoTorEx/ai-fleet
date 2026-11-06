//! Private JSON-lines bridge. No network, terminal writes, or daemon installation.
#![allow(dead_code)]
#[path = "../vendor/activity.rs"]
mod activity;
mod codex_metadata;
#[path = "../vendor/command.rs"]
mod command;
#[path = "../vendor/content.rs"]
mod content;
#[path = "../vendor/iterm.rs"]
mod iterm;
#[path = "../vendor/model.rs"]
mod model;
#[path = "../vendor/process.rs"]
mod process;
#[path = "../vendor/session_data.rs"]
mod session_data;

use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    io::{BufRead, Write},
    sync::{Arc, Mutex, mpsc},
    thread,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Request {
    request_id: u64,
    command: String,
    #[serde(default)]
    force: bool,
    session_id: Option<String>,
}

fn emit(output: &Mutex<std::io::Stdout>, request_id: u64, mut value: Value) {
    value["requestID"] = json!(request_id);
    value["protocol"] = json!(1);
    let mut out = output.lock().unwrap();
    let _ = writeln!(out, "{value}");
    let _ = out.flush();
}

fn timestamp(time: Option<SystemTime>) -> Option<f64> {
    time.and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_secs_f64())
}

fn row(session: &model::Session, progress: &activity::Progress) -> Value {
    json!({
        "id": session.id,
        "dataVersion": 1,
        "pid": session.pid,
        "processStarted": session.started,
        "cwd": session.cwd,
        "stateSource": "terminalHeuristic",
        "provider": session.provider,
        "project": session.project,
        "title": session.location.as_ref().map(|p| model::safe_text(&p.name))
            .filter(|s| !s.trim().is_empty()).unwrap_or_else(|| session.provider.to_string()),
        "location": session.location,
        "linkReason": session.link_reason,
        "state": progress.label(),
        "explanation": progress.explanation(),
        "model": progress.model,
        "reasoning": progress.reasoning,
        "request": progress.request,
        "answer": progress.last_message,
        "updatedAt": timestamp(progress.updated_at),
        "requestedAt": if progress.native_metadata { timestamp(progress.requested_at) } else { None },
        "lastMessageAt": if progress.native_metadata { timestamp(progress.updated_at) } else { None },
    })
}

fn apply(
    snapshot: activity::Snapshot,
    sessions: &[model::Session],
    states: &mut HashMap<String, activity::Progress>,
) {
    // Bound-file evidence can disappear without the process exiting. Do not keep
    // old provider timestamps looking like fresh bindings after that happens.
    for (id, progress) in states.iter_mut() {
        if progress.native_metadata && !snapshot.metadata.contains_key(id) {
            progress.native_metadata = false;
            progress.requested_at = None;
            progress.updated_at = None;
        }
    }
    for (id, observation) in snapshot.sessions {
        let focused = sessions
            .iter()
            .find(|s| s.id == id)
            .and_then(|s| s.location.as_ref())
            .is_some_and(|p| snapshot.focused.as_ref() == Some(&p.id));
        states
            .entry(id)
            .or_default()
            .observe(observation.as_ref(), focused);
    }
    for (id, metadata) in snapshot.metadata {
        if let Some(p) = states.get_mut(&id) {
            p.native_metadata = true;
            p.model = metadata.model.or(p.model.take());
            p.reasoning = metadata.reasoning.or(p.reasoning.take());
            p.updated_at = metadata.updated_at;
            p.requested_at = metadata.requested_at;
            p.request = metadata.request.or(p.request.take());
            p.last_message = metadata.last_message;
        }
    }
}

/// Display-only timing from the same panes and PID/start checks as the pinned reader.
fn read_activity(
    sessions: &[model::Session],
    terminal: &mut iterm::Client,
) -> anyhow::Result<(activity::Snapshot, HashMap<String, SystemTime>)> {
    let table = process::scan()?;
    let valid: Vec<_> = sessions
        .iter()
        .filter(|s| {
            s.location
                .as_ref()
                .is_some_and(|p| model::valid_identity(s, p, &table))
        })
        .collect();
    let panes: Vec<_> = valid.iter().filter_map(|s| s.location.clone()).collect();
    let observed = terminal.observe(&panes)?;
    let claude: Vec<_> = valid
        .iter()
        .copied()
        .filter(|s| s.provider == process::Provider::Claude)
        .collect();
    let mut metadata = crate::session_data::read(&claude);
    metadata.extend(codex_metadata::read(&valid));
    // Reject identity reuse during the file read.
    let after = process::scan()?;
    metadata.retain(|id, _| {
        valid.iter().any(|s| {
            &s.id == id
                && after
                    .iter()
                    .any(|p| p.pid == s.pid && p.started == s.started)
        })
    });
    let now = SystemTime::now();
    let working_starts = valid
        .iter()
        .enumerate()
        .filter_map(|(index, session)| {
            if !after
                .iter()
                .any(|p| p.pid == session.pid && p.started == session.started)
            {
                return None;
            }
            let text = observed.texts.get(index)?.as_deref()?;
            if activity::Observation::parse(text, session.provider).state
                != activity::State::Working
            {
                return None;
            }
            let elapsed = working_elapsed(text)?;
            now.checked_sub(elapsed)
                .map(|start| (session.id.clone(), start))
        })
        .collect();
    let sessions = sessions
        .iter()
        .map(|s| {
            let live = after
                .iter()
                .any(|p| p.pid == s.pid && p.started == s.started);
            let text = valid
                .iter()
                .position(|v| v.id == s.id)
                .and_then(|i| observed.texts.get(i))
                .and_then(|s| s.as_deref());
            (
                s.id.clone(),
                text.filter(|_| live)
                    .map(|text| activity::Observation::parse(text, s.provider)),
            )
        })
        .collect();
    Ok((
        activity::Snapshot {
            sessions,
            focused: observed.focused,
            metadata,
        },
        working_starts,
    ))
}

fn working_elapsed(text: &str) -> Option<Duration> {
    let line =
        text.lines().rev().take(24).find(|line| {
            line.contains("esc to interrupt") || line.contains("ctrl+c to interrupt")
        })?;
    let duration = line.rsplit_once('(')?.1.split(['•', '·']).next()?.trim();
    let mut number = String::new();
    let mut seconds = 0u64;
    let mut parts = 0;
    for c in duration.chars() {
        if c.is_ascii_digit() {
            number.push(c);
        } else if c.is_whitespace() {
            continue;
        } else {
            let factor = match c {
                'd' => 86400,
                'h' => 3600,
                'm' => 60,
                's' => 1,
                _ => return None,
            };
            let value: u64 = number.parse().ok()?;
            seconds = seconds.checked_add(value.checked_mul(factor)?)?;
            number.clear();
            parts += 1;
        }
    }
    (parts > 0 && number.is_empty()).then(|| Duration::from_secs(seconds))
}

fn work_timing(
    id: &str,
    progress: &activity::Progress,
    explicit: Option<SystemTime>,
    observed: &mut HashMap<String, SystemTime>,
    now: SystemTime,
) -> Option<(SystemTime, &'static str)> {
    if progress.label() != "Working" {
        observed.remove(id);
        return None;
    }
    let baseline = *observed.entry(id.to_owned()).or_insert(now);
    let request = progress
        .native_metadata
        .then_some(progress.requested_at)
        .flatten()
        .filter(|t| *t <= now);
    Some(if let Some(t) = explicit.filter(|t| *t <= now) {
        (t, "terminalTimer")
    } else if let Some(t) = request {
        (t, "providerRequest")
    } else {
        (baseline, "observed")
    })
}

fn main() {
    let output = Arc::new(Mutex::new(std::io::stdout()));
    let sessions = Arc::new(Mutex::new(Vec::<model::Session>::new()));
    let (scan_tx, scan_rx) = mpsc::channel::<Request>();
    let (jump_tx, jump_rx) = mpsc::channel::<Request>();
    let scan = {
        let output = output.clone();
        let sessions = sessions.clone();
        thread::spawn(move || {
            let mut collector = model::Collector::new(30);
            let mut states = HashMap::<String, activity::Progress>::new();
            let mut working_starts = HashMap::<String, SystemTime>::new();
            let mut observed_work = HashMap::<String, SystemTime>::new();
            let mut last_activity: Option<Instant> = None;
            let mut activity_observed_at = None;
            for request in scan_rx {
                let result = (|| -> anyhow::Result<Value> {
                    let found = collector.scan(request.force)?;
                    let changed = *sessions.lock().unwrap() != found;
                    *sessions.lock().unwrap() = found.clone();
                    states.retain(|id, _| found.iter().any(|s| &s.id == id));
                    observed_work.retain(|id, _| found.iter().any(|s| &s.id == id));
                    if request.force
                        || changed
                        || last_activity.is_none_or(|t| t.elapsed() >= Duration::from_secs(5))
                    {
                        let (snapshot, starts) = read_activity(&found, &mut collector.terminal)?;
                        working_starts = starts;
                        apply(snapshot, &found, &mut states);
                        last_activity = Some(Instant::now());
                        activity_observed_at = Some(SystemTime::now());
                    }
                    Ok(
                        json!({"kind": "snapshot", "sessions": found.iter().map(|s| {
                            let progress = states.entry(s.id.clone()).or_default();
                            let mut value = row(s, progress);
                            value["activityObservedAt"] = json!(timestamp(activity_observed_at));
                            if let Some((start, basis)) = work_timing(&s.id, progress, working_starts.get(&s.id).copied(), &mut observed_work, SystemTime::now()) {
                                value["workStartedAt"] = json!(timestamp(Some(start)));
                                value["workTimeSource"] = json!(basis);
                            } else {
                                value["workStartedAt"] = Value::Null;
                                value["workTimeSource"] = Value::Null;
                            }
                            value["workingStartedAt"] = if progress.label() == "Working" { json!(timestamp(working_starts.get(&s.id).copied())) } else { Value::Null };
                            value
                        }).collect::<Vec<_>>(),
                        "observedAt": timestamp(Some(SystemTime::now()))}),
                    )
                })();
                if result.is_err() {
                    observed_work.clear();
                    working_starts.clear();
                    last_activity = None;
                    activity_observed_at = None;
                }
                emit(
                    &output,
                    request.request_id,
                    result.unwrap_or_else(|e| json!({"kind":"snapshot", "error":e.to_string()})),
                );
            }
            // EOF closes the worker and drops/reaps the owned JXA helper.
        })
    };
    let jump = {
        let output = output.clone();
        let sessions = sessions.clone();
        thread::spawn(move || {
            let mut terminal = iterm::Client::default();
            // Warm Jump independently; scans never hold this channel.
            let _ = terminal.warm();
            for request in jump_rx {
                let selected = sessions
                    .lock()
                    .unwrap()
                    .iter()
                    .find(|s| Some(&s.id) == request.session_id.as_ref())
                    .cloned();
                let result = selected
                    .ok_or_else(|| anyhow::anyhow!("Session exited; refresh Agents"))
                    .and_then(|s| model::jump_with(&s, &mut terminal));
                emit(
                    &output,
                    request.request_id,
                    match result {
                        Ok(()) => json!({"kind":"jump", "sessionID":request.session_id}),
                        Err(e) => {
                            json!({"kind":"jump", "sessionID":request.session_id, "error":e.to_string()})
                        }
                    },
                );
            }
        })
    };
    for line in std::io::stdin().lock().lines() {
        let Ok(line) = line else { break };
        match serde_json::from_str::<Request>(&line) {
            Ok(r) if r.command == "refresh" => {
                let _ = scan_tx.send(r);
            }
            Ok(r) if r.command == "jump" => {
                let _ = jump_tx.send(r);
            }
            Ok(r) => emit(
                &output,
                r.request_id,
                json!({"kind":"error", "error":"Unsupported command"}),
            ),
            Err(_) => emit(
                &output,
                0,
                json!({"kind":"error", "error":"Invalid request"}),
            ),
        }
    }
    drop(scan_tx);
    drop(jump_tx);
    let _ = scan.join();
    let _ = jump.join();
}

#[cfg(test)]
mod bridge_tests {
    use super::*;
    #[test]
    fn repeated_polling_and_messages_do_not_restart_observed_work() {
        let mut p = activity::Progress::default();
        p.state = activity::State::Working;
        let mut observed = HashMap::new();
        let first = UNIX_EPOCH + Duration::from_secs(100);
        assert_eq!(
            work_timing("pid-start", &p, None, &mut observed, first),
            Some((first, "observed"))
        );
        p.last_message = Some("intermediate response".into());
        assert_eq!(
            work_timing(
                "pid-start",
                &p,
                None,
                &mut observed,
                first + Duration::from_secs(20)
            ),
            Some((first, "observed"))
        );
        p.state = activity::State::Idle;
        assert!(work_timing("pid-start", &p, None, &mut observed, first).is_none());
        p.state = activity::State::Working;
        let next = first + Duration::from_secs(30);
        assert_eq!(
            work_timing("pid-start", &p, None, &mut observed, next),
            Some((next, "observed"))
        );
    }

    #[test]
    fn missing_binding_discards_old_provider_times() {
        let mut states = HashMap::new();
        let mut progress = activity::Progress::default();
        progress.native_metadata = true;
        progress.updated_at = Some(UNIX_EPOCH);
        progress.requested_at = Some(UNIX_EPOCH);
        states.insert("pid-start".into(), progress);
        apply(
            activity::Snapshot {
                sessions: vec![],
                focused: None,
                metadata: HashMap::new(),
            },
            &[],
            &mut states,
        );
        let p = &states["pid-start"];
        assert!(!p.native_metadata);
        assert!(p.updated_at.is_none());
        assert!(p.requested_at.is_none());
    }

    #[test]
    fn working_clock_reads_only_explicit_live_status_durations() {
        assert_eq!(
            working_elapsed("• Working (12m 5s • esc to interrupt)"),
            Some(Duration::from_secs(725))
        );
        assert_eq!(
            working_elapsed("Working (1h 2m 3s · esc to interrupt)"),
            Some(Duration::from_secs(3723))
        );
        assert_eq!(
            working_elapsed("Working (0s • esc to interrupt)"),
            Some(Duration::ZERO)
        );
        assert_eq!(working_elapsed("Worked for 12m 5s"), None);
        assert_eq!(working_elapsed("A response mentions 12m 5s"), None);
        assert_eq!(
            working_elapsed("Working (unknown • esc to interrupt)"),
            None
        );
    }
    #[test]
    fn malformed_requests_cannot_become_jumps_and_rows_keep_unknown_state() {
        assert!(serde_json::from_str::<Request>(r#"{"command":"jump","sessionID":"1"}"#).is_err());
        let session = model::Session {
            id: "1-2".into(),
            pid: 1,
            started: 2,
            provider: process::Provider::Codex,
            cwd: None,
            project: "/project".into(),
            status: "Live",
            location: None,
            link_reason: Some("No confirmed iTerm2 pane".into()),
        };
        let value = row(&session, &activity::Progress::default());
        assert_eq!(value["state"], "Unknown");
        assert!(value["location"].is_null());
        assert!(value["updatedAt"].is_null());
        assert!(value["requestedAt"].is_null());
        assert!(value["lastMessageAt"].is_null());
        let mut observed = activity::Progress::default();
        observed.updated_at = Some(UNIX_EPOCH + Duration::from_secs(60));
        observed.requested_at = Some(UNIX_EPOCH + Duration::from_secs(30));
        assert!(row(&session, &observed)["lastMessageAt"].is_null());
        observed.native_metadata = true;
        assert_eq!(row(&session, &observed)["requestedAt"], json!(30.0));
        assert_eq!(row(&session, &observed)["lastMessageAt"], json!(60.0));
        assert!(value.get("percent").is_none());
    }
}
