//! Private JSON-lines bridge. No network, terminal writes, or daemon installation.
#![allow(dead_code)]
#[path = "../vendor/activity.rs"]
mod activity;
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
    })
}

fn apply(
    snapshot: activity::Snapshot,
    sessions: &[model::Session],
    states: &mut HashMap<String, activity::Progress>,
) {
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
            let mut last_activity: Option<Instant> = None;
            for request in scan_rx {
                let result = (|| -> anyhow::Result<Value> {
                    let found = collector.scan(request.force)?;
                    let changed = *sessions.lock().unwrap() != found;
                    *sessions.lock().unwrap() = found.clone();
                    states.retain(|id, _| found.iter().any(|s| &s.id == id));
                    if request.force
                        || changed
                        || last_activity.is_none_or(|t| t.elapsed() >= Duration::from_secs(5))
                    {
                        apply(
                            activity::read(&found, &mut collector.terminal)?,
                            &found,
                            &mut states,
                        );
                        last_activity = Some(Instant::now());
                    }
                    Ok(
                        json!({"kind": "snapshot", "sessions": found.iter().map(|s| row(s, states.entry(s.id.clone()).or_default())).collect::<Vec<_>>(),
                        "observedAt": timestamp(Some(SystemTime::now()))}),
                    )
                })();
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
        assert!(value.get("percent").is_none());
    }
}
