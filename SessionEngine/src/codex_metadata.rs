//! Fleet-owned adaptation for current Codex headers and inherited helper logs.
//! A transcript belongs to a session when the validated interactive PID holds it open for
//! writing. Codex 0.171 moved transcripts into a shared app-server, which records no client
//! PID; there a live transcript is taken by the conversation name the pane's title carries,
//! and only when that name points at one transcript and one pane.
use crate::{command, model::Session, process::Provider, session_data};
use serde_json::Value;
use std::{
    collections::HashMap,
    fs::File,
    io::{BufRead, BufReader, Read, Seek, SeekFrom},
    path::{Path, PathBuf},
    process::Command,
    time::Duration,
};

const BOUND: u64 = 1_048_576;

pub fn read(
    sessions: &[&Session],
    titles: &[Option<String>],
) -> HashMap<String, session_data::Metadata> {
    let targets: Vec<_> = sessions
        .iter()
        .enumerate()
        .filter(|(_, s)| s.provider == Provider::Codex)
        .collect();
    if targets.is_empty() {
        return HashMap::new();
    }
    let Some(home) = std::env::var_os("HOME").map(PathBuf::from) else {
        return HashMap::new();
    };
    let home = std::env::var_os("CODEX_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| home.join(".codex"));
    let Ok(root) = std::fs::canonicalize(home.join("sessions")) else {
        return HashMap::new();
    };
    // Selections are ORed: the session PIDs, and every Codex process for the shared server.
    let mut cmd = Command::new("/usr/sbin/lsof");
    cmd.args([
        "-p",
        &targets
            .iter()
            .map(|(_, s)| s.pid.to_string())
            .collect::<Vec<_>>()
            .join(","),
        "-c",
        "codex",
        "-Fpfan",
    ]);
    let Ok(output) = command::output(cmd, Duration::from_secs(2)) else {
        return HashMap::new();
    };
    let mut files: HashMap<u32, Vec<PathBuf>> = HashMap::new();
    let mut pid = None;
    let mut writable = false;
    for line in output.lines() {
        if let Some(value) = line.strip_prefix('p') {
            pid = value.parse::<u32>().ok();
            writable = false;
        } else if line.starts_with('f') {
            writable = false;
        } else if let Some(value) = line.strip_prefix('a') {
            writable = value == "w" || value == "u";
        } else if let Some(value) = line.strip_prefix('n') {
            if !writable {
                continue;
            }
            let Some(pid) = pid else { continue };
            let Ok(path) = std::fs::canonicalize(value) else {
                continue;
            };
            if path.starts_with(&root) && path.extension().is_some_and(|e| e == "jsonl") {
                let paths = files.entry(pid).or_default();
                if !paths.contains(&path) {
                    paths.push(path);
                }
            }
        }
    }
    let mut bound: HashMap<String, (PathBuf, String)> = targets
        .iter()
        .filter_map(|(_, s)| Some((s.id.clone(), primary(files.get(&s.pid)?)?)))
        .collect();
    let shared: Vec<_> = files
        .iter()
        .filter(|(pid, _)| !targets.iter().any(|(_, s)| s.pid == **pid))
        .flat_map(|(_, paths)| paths)
        .filter_map(|path| Some((path.clone(), header(path)??)))
        .collect();
    let unbound: Vec<_> = targets
        .iter()
        .filter(|(_, s)| !bound.contains_key(&s.id))
        .map(|(i, s)| {
            let title = titles.get(*i).and_then(|t| t.as_deref());
            let title = title.or(s.location.as_ref().map(|p| p.name.as_str()));
            (s.id.clone(), title_parts(title.unwrap_or(""), s))
        })
        .collect();
    if !shared.is_empty() && !unbound.is_empty() {
        let names = thread_names(&home.join("session_index.jsonl"));
        let live: Vec<_> = shared
            .into_iter()
            .filter_map(|(path, id)| Some((names.get(&id)?.clone(), path, id)))
            .collect();
        bound.extend(by_name(&unbound, &live));
    }
    bound
        .into_iter()
        .filter_map(|(session, (path, id))| {
            let mut file = File::open(path).ok()?;
            let start = file.metadata().ok()?.len().saturating_sub(BOUND);
            file.seek(SeekFrom::Start(start)).ok()?;
            let mut bytes = Vec::new();
            file.take(BOUND).read_to_end(&mut bytes).ok()?;
            let raw = String::from_utf8_lossy(&bytes);
            let text = if start > 0 {
                raw.split_once('\n')?.1
            } else {
                &raw
            };
            Some((session, parse(text, &id)))
        })
        .collect()
}

/// What a Codex pane title can name: its parts between " | ", without the spinner Codex puts
/// first while a turn runs. The folder closes the title and is not a conversation name.
fn title_parts(title: &str, session: &Session) -> Vec<String> {
    let folder = |path: &str| {
        Path::new(path)
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
    };
    let folders = [
        folder(&session.project),
        session.cwd.as_deref().and_then(folder),
    ];
    title
        .split(" | ")
        .map(|part| {
            part.trim()
                .trim_start_matches(|c| ('\u{2800}'..='\u{28ff}').contains(&c))
                .trim()
                .to_owned()
        })
        .filter(|part| !part.is_empty() && !folders.contains(&Some(part.clone())))
        .collect()
}

/// Conversation names from Codex's own index; a rename appends a row, so the last one wins.
fn thread_names(index: &Path) -> HashMap<String, String> {
    let mut names = HashMap::new();
    let Ok(mut file) = File::open(index) else {
        return names;
    };
    let start = file.metadata().map_or(0, |m| m.len().saturating_sub(BOUND));
    let mut bytes = Vec::new();
    if file.seek(SeekFrom::Start(start)).is_err()
        || file.take(BOUND).read_to_end(&mut bytes).is_err()
    {
        return names;
    }
    for line in String::from_utf8_lossy(&bytes).lines() {
        let Ok(row) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        if let (Some(id), Some(name)) = (row["id"].as_str(), row["thread_name"].as_str())
            && !name.trim().is_empty()
        {
            names.insert(id.to_owned(), name.trim().to_owned());
        }
    }
    names
}

/// Binds a pane to a live transcript by conversation name. A name carried by two live
/// transcripts or shown by two panes says nothing about which is which, and binds neither.
fn by_name(
    panes: &[(String, Vec<String>)],
    live: &[(String, PathBuf, String)],
) -> HashMap<String, (PathBuf, String)> {
    panes
        .iter()
        .filter_map(|(session, parts)| {
            let mut named = live.iter().filter(|(name, _, _)| parts.contains(name));
            let (name, path, id) = named.next()?;
            let shown = panes.iter().filter(|(_, p)| p.contains(name)).count();
            (named.next().is_none() && shown == 1)
                .then(|| (session.clone(), (path.clone(), id.clone())))
        })
        .collect()
}

/// Current Codex writes conversation messages as response items; preserve their
/// chronological order alongside older event messages for the pinned parser. A question is a
/// call of a `request_user_input` tool. The asynchronous one returns `{"accepted":true}` at
/// once and is answered by a later user message; any other result is the answer itself.
fn parse(source: &str, id: &str) -> session_data::Metadata {
    let normalized = source
        .lines()
        .map(|line| {
            let Ok(mut value) = serde_json::from_str::<Value>(line) else {
                return line.to_owned();
            };
            if value["type"] != "response_item" {
                return line.to_owned();
            }
            let payload = &value["payload"];
            let event = match payload["type"].as_str() {
                Some("message") => {
                    let kind = match payload["role"].as_str() {
                        Some("user") => "user_message",
                        Some("assistant") => "agent_message",
                        _ => return line.to_owned(),
                    };
                    serde_json::json!({"type":kind,"message":payload["content"]})
                }
                Some("function_call")
                    if payload["name"]
                        .as_str()
                        .is_some_and(|name| name.starts_with("request_user_input")) =>
                {
                    let asked = payload["arguments"]
                        .as_str()
                        .and_then(|a| serde_json::from_str::<Value>(a).ok())
                        .and_then(|a| session_data::question_text(&a));
                    let Some(asked) = asked else {
                        return line.to_owned();
                    };
                    serde_json::json!({"type":"question","message":asked,"call":payload["call_id"]})
                }
                Some("function_call_output") => {
                    let accepted = payload["output"]
                        .as_str()
                        .and_then(|o| serde_json::from_str::<Value>(o).ok())
                        .is_some_and(|o| o["accepted"] == true);
                    if accepted {
                        return line.to_owned();
                    }
                    serde_json::json!({"type":"question_answered","call":payload["call_id"]})
                }
                _ => return line.to_owned(),
            };
            value["type"] = serde_json::json!("event_msg");
            value["payload"] = event;
            value.to_string()
        })
        .collect::<Vec<_>>()
        .join("\n");
    session_data::parse(&normalized, Provider::Codex, id)
}

/// The conversation id of a primary transcript, or `Some(None)` for a subagent's helper log.
/// Only the first line is read, up to the bound: a daemon holds many transcripts, some of
/// them tens of megabytes.
fn header(path: &Path) -> Option<Option<String>> {
    let mut line = Vec::new();
    BufReader::new(File::open(path).ok()?.take(BOUND))
        .read_until(b'\n', &mut line)
        .ok()?;
    let header: Value = serde_json::from_slice(&line).ok()?;
    if header["type"] != "session_meta" {
        return None;
    }
    let source = &header["payload"]["source"];
    if source
        .as_object()
        .is_some_and(|value| value.contains_key("subagent"))
        || source == "subagent"
    {
        return Some(None);
    }
    let id = header["payload"]["id"].as_str()?;
    (id.len() == 36
        && id.bytes().enumerate().all(|(i, c)| {
            if [8, 13, 18, 23].contains(&i) {
                c == b'-'
            } else {
                c.is_ascii_hexdigit()
            }
        }))
    .then(|| Some(id.to_owned()))
}

fn primary(paths: &[PathBuf]) -> Option<(PathBuf, String)> {
    let mut candidate = None;
    for path in paths {
        let Some(id) = header(path)? else { continue };
        if candidate.is_some() {
            return None;
        }
        candidate = Some((path.clone(), id));
    }
    candidate
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn response_messages_preserve_timestamps_and_chronological_order() {
        let raw = r#"{"type":"response_item","timestamp":"2026-11-03T09:00:00Z","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Request"}]}}
{"type":"response_item","timestamp":"2026-11-03T09:01:00Z","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Answer"}]}}
{"type":"event_msg","timestamp":"2026-11-03T09:02:00Z","payload":{"type":"user_message","message":"Next"}}"#;
        let metadata = parse(raw, "session");
        assert_eq!(metadata.request.as_deref(), Some("Next"));
        assert_eq!(metadata.updated_at, metadata.requested_at);
        assert!(metadata.last_message.is_none());
        let metadata = parse(
            &raw.lines().take(2).collect::<Vec<_>>().join("\n"),
            "session",
        );
        assert_eq!(metadata.last_message.as_deref(), Some("Answer"));
        assert!(metadata.updated_at > metadata.requested_at);
    }

    #[test]
    fn asynchronous_question_stays_pending_until_the_user_writes() {
        let call = |name: &str| {
            json!({"type":"response_item","payload":{"type":"function_call","name":name,"call_id":"call_1",
                "arguments":json!({"questions":[{"title":"Connect the drive?","options":["Connected","Later"]}]}).to_string()}})
            .to_string()
        };
        let output = |output: &str| {
            json!({"type":"response_item","payload":{"type":"function_call_output","call_id":"call_1","output":output}}).to_string()
        };
        let said = |role: &str, text: &str| {
            json!({"type":"response_item","payload":{"type":"message","role":role,"content":[{"type":"output_text","text":text}]}}).to_string()
        };
        let asked = [
            call("request_user_input_async"),
            output(r#"{"accepted":true}"#),
            said("assistant", "Meanwhile I keep checking."),
        ]
        .join("\n");
        let metadata = parse(&asked, "session");
        assert_eq!(
            metadata.question.as_deref(),
            Some("Connect the drive?\n• Connected\n• Later")
        );
        assert_eq!(
            metadata.last_message.as_deref(),
            Some("Meanwhile I keep checking.")
        );
        let answered = format!("{asked}\n{}", said("user", "Connected"));
        assert!(parse(&answered, "session").question.is_none());
        // The synchronous tool returns the answer as its result.
        let sync = [
            call("request_user_input"),
            output(r#"{"answers":["Later"]}"#),
        ]
        .join("\n");
        assert!(parse(&sync, "session").question.is_none());
        assert!(
            parse(&call("request_user_input"), "session")
                .question
                .is_some()
        );
    }

    #[test]
    fn a_shared_transcript_binds_only_by_a_name_one_pane_and_one_transcript_carry() {
        let session = |project: &str| Session {
            id: "s".into(),
            pid: 1,
            started: 1,
            provider: Provider::Codex,
            cwd: Some(project.into()),
            project: project.into(),
            status: "",
            location: None,
            link_reason: None,
        };
        let parts = |title: &str| title_parts(title, &session("/Users/me/fleet"));
        assert_eq!(
            parts("[ ! ] Action Required | Audit the drive | fleet (codex)"),
            ["[ ! ] Action Required", "Audit the drive", "fleet (codex)"]
        );
        assert_eq!(parts("⠹ Audit the drive | fleet"), ["Audit the drive"]);
        assert!(parts("fleet").is_empty());

        let live = |name: &str, id: &str| (name.to_owned(), PathBuf::from(id), id.to_owned());
        let pane = |id: &str, title: &str| (id.to_owned(), parts(title));
        let threads = [live("Audit the drive", "a"), live("Fix the build", "b")];
        let bound = by_name(
            &[
                pane("one", "⠹ Audit the drive | fleet (codex)"),
                pane("two", "Unnamed | fleet (codex)"),
            ],
            &threads,
        );
        assert_eq!(bound.len(), 1);
        assert_eq!(bound["one"].1, "a");
        // Two panes showing one name, or two live transcripts sharing it, bind nothing.
        let twice = [
            pane("one", "Audit the drive | fleet (codex)"),
            pane("two", "Audit the drive | other (codex)"),
        ];
        assert!(by_name(&twice, &threads).is_empty());
        let same = [live("Audit the drive", "a"), live("Audit the drive", "c")];
        assert!(by_name(&twice[..1], &same).is_empty());
    }

    #[test]
    fn large_headers_and_helper_logs_do_not_hide_or_replace_the_primary() {
        let root = std::env::temp_dir().join(format!("fleet-metadata-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        let main = root.join("main.jsonl");
        let helper = root.join("helper.jsonl");
        let id = "00000000-0000-0000-0000-000000000001";
        let header = json!({"type":"session_meta", "payload":{"id":id,"source":"cli","base_instructions":"x".repeat(30000)}});
        std::fs::write(&main, format!("{header}\n")).unwrap();
        let header = json!({"type":"session_meta", "payload":{"id":"00000000-0000-0000-0000-000000000002","source":{"subagent":"review"}}});
        std::fs::write(&helper, format!("{header}\n")).unwrap();
        assert_eq!(primary(&[helper.clone(), main.clone()]).unwrap().0, main);
        assert_eq!(primary(&[main.clone(), helper.clone()]).unwrap().1, id);
        assert!(primary(std::slice::from_ref(&helper)).is_none());
        let invalid = root.join("invalid.jsonl");
        std::fs::write(&invalid, "incomplete header").unwrap();
        assert!(primary(&[main.clone(), invalid]).is_none());
        let other = root.join("other.jsonl");
        std::fs::copy(&main, &other).unwrap();
        assert!(primary(&[main.clone(), other]).is_none());
        std::fs::remove_dir_all(root).unwrap();
    }
}
