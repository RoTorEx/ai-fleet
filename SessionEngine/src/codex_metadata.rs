//! Fleet-owned adaptation for current Codex headers and inherited helper logs.
//! Files must be open for writing by an already validated interactive PID.
use crate::{command, model::Session, process::Provider, session_data};
use serde_json::Value;
use std::{
    collections::HashMap,
    fs::File,
    io::{Read, Seek, SeekFrom},
    path::PathBuf,
    process::Command,
    time::Duration,
};

const BOUND: u64 = 1_048_576;

pub fn read(sessions: &[&Session]) -> HashMap<String, session_data::Metadata> {
    let targets: Vec<_> = sessions
        .iter()
        .filter(|s| s.provider == Provider::Codex)
        .collect();
    if targets.is_empty() {
        return HashMap::new();
    }
    let Some(home) = std::env::var_os("HOME").map(PathBuf::from) else {
        return HashMap::new();
    };
    let root = std::env::var_os("CODEX_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| home.join(".codex"))
        .join("sessions");
    let Ok(root) = std::fs::canonicalize(root) else {
        return HashMap::new();
    };
    let mut cmd = Command::new("/usr/sbin/lsof");
    cmd.args([
        "-a",
        "-p",
        &targets
            .iter()
            .map(|s| s.pid.to_string())
            .collect::<Vec<_>>()
            .join(","),
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
    targets
        .into_iter()
        .filter_map(|s| {
            let (path, id) = primary(files.get(&s.pid)?)?;
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
            Some((s.id.clone(), parse(text, &id)))
        })
        .collect()
}

/// Current Codex writes conversation messages as response items; preserve their
/// chronological order alongside older event messages for the pinned parser.
fn parse(source: &str, id: &str) -> session_data::Metadata {
    let normalized = source
        .lines()
        .map(|line| {
            let Ok(mut value) = serde_json::from_str::<Value>(line) else {
                return line.to_owned();
            };
            if value["type"] != "response_item" || value["payload"]["type"] != "message" {
                return line.to_owned();
            }
            let kind = match value["payload"]["role"].as_str() {
                Some("user") => "user_message",
                Some("assistant") => "agent_message",
                _ => return line.to_owned(),
            };
            let content = value["payload"]["content"].clone();
            value["type"] = serde_json::json!("event_msg");
            value["payload"] = serde_json::json!({"type":kind,"message":content});
            value.to_string()
        })
        .collect::<Vec<_>>()
        .join("\n");
    session_data::parse(&normalized, Provider::Codex, id)
}

fn primary(paths: &[PathBuf]) -> Option<(PathBuf, String)> {
    let mut candidate = None;
    for path in paths {
        let mut bytes = Vec::new();
        File::open(path)
            .ok()?
            .take(BOUND)
            .read_to_end(&mut bytes)
            .ok()?;
        let header: Value = serde_json::from_slice(bytes.split(|b| *b == b'\n').next()?).ok()?;
        if header["type"] != "session_meta" {
            return None;
        }
        let source = &header["payload"]["source"];
        if source
            .as_object()
            .is_some_and(|value| value.contains_key("subagent"))
            || source == "subagent"
        {
            continue;
        }
        let id = header["payload"]["id"].as_str()?;
        if id.len() != 36 || !id.chars().all(|c| c.is_ascii_hexdigit() || c == '-') {
            return None;
        }
        if candidate.is_some() {
            return None;
        }
        candidate = Some((path.clone(), id.to_owned()));
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
