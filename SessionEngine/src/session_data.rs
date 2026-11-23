//! Optional metadata from a provider file bound to a live process, never by recency.
use crate::{command, model::Session, process::Provider};
use chrono::{DateTime, Utc};
use serde_json::Value;
use std::{
    collections::HashMap,
    fs::File,
    io::{Read, Seek, SeekFrom},
    path::{Path, PathBuf},
    process::Command,
    time::{Duration, SystemTime},
};

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Metadata {
    pub model: Option<String>,
    pub reasoning: Option<String>,
    pub updated_at: Option<SystemTime>,
    pub requested_at: Option<SystemTime>,
    pub request: Option<String>,
    pub last_message: Option<String>,
    /// What the agent asked through its question tool and the user has not answered yet.
    pub question: Option<String>,
}

// A bounded tail keeps refresh work independent of the complete conversation size.
const TAIL_BYTES: u64 = 1_048_576;

pub fn read(sessions: &[&Session]) -> HashMap<String, Metadata> {
    let Some(home) = std::env::var_os("HOME").map(PathBuf::from) else {
        return HashMap::new();
    };
    let codex_root = std::env::var_os("CODEX_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| home.join(".codex"));
    let claude_root = std::env::var_os("CLAUDE_CONFIG_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| home.join(".claude"));
    let codex: Vec<_> = sessions
        .iter()
        .filter(|s| s.provider == Provider::Codex)
        .map(|s| s.pid.to_string())
        .collect();
    let mut files: HashMap<u32, Vec<PathBuf>> = HashMap::new();
    if !codex.is_empty() {
        let mut cmd = Command::new("/usr/sbin/lsof");
        cmd.args(["-a", "-p", &codex.join(","), "-Fn"]);
        if let Ok(output) = command::output(cmd, Duration::from_secs(2)) {
            let mut pid = None;
            for line in output.lines() {
                if let Some(p) = line.strip_prefix('p') {
                    pid = p.parse::<u32>().ok();
                }
                if let (Some(pid), Some(path)) = (pid, line.strip_prefix('n')) {
                    let path = PathBuf::from(path);
                    if path.starts_with(codex_root.join("sessions"))
                        && path.extension().is_some_and(|e| e == "jsonl")
                    {
                        let paths = files.entry(pid).or_default();
                        if !paths.contains(&path) {
                            paths.push(path);
                        }
                    }
                }
            }
        }
    }
    sessions
        .iter()
        .filter_map(|s| {
            let binding = match s.provider {
                Provider::Codex => {
                    let paths = files.get(&s.pid)?;
                    if paths.len() != 1 {
                        return None;
                    }
                    let path = paths[0].clone();
                    let mut first = Vec::new();
                    File::open(&path)
                        .ok()?
                        .take(16_384)
                        .read_to_end(&mut first)
                        .ok()?;
                    let first: Value =
                        serde_json::from_slice(first.split(|b| *b == b'\n').next()?).ok()?;
                    if first["type"] != "session_meta" {
                        return None;
                    }
                    (path, first["payload"]["id"].as_str()?.to_owned())
                }
                Provider::Claude => claude_binding(s, &claude_root)?,
                _ => return None,
            };
            let text = tail(&binding.0)?;
            Some((s.id.clone(), parse(&text, s.provider, &binding.1)))
        })
        .collect()
}

fn claude_binding(s: &Session, root: &Path) -> Option<(PathBuf, String)> {
    let text = std::fs::read(root.join("sessions").join(format!("{}.json", s.pid))).ok()?;
    if text.len() > 16_384 {
        return None;
    }
    let v: Value = serde_json::from_slice(&text).ok()?;
    let start = DateTime::<Utc>::from_timestamp((s.started / 1_000_000) as i64, 0)?;
    if v["pid"].as_u64()? != s.pid as u64
        || v["pidDomain"] != "darwin"
        || v["kind"] != "interactive"
        || v["procStart"].as_str()? != start.format("%a %b %e %T %Y").to_string()
    {
        return None;
    }
    let id = v["sessionId"].as_str()?;
    if id.len() != 36 || !id.chars().all(|c| c.is_ascii_hexdigit() || c == '-') {
        return None;
    }
    // Search exact IDs in project directories; cwd/mtime never chooses a conversation.
    let paths: Vec<_> = std::fs::read_dir(root.join("projects"))
        .ok()?
        .flatten()
        .map(|d| d.path().join(format!("{id}.jsonl")))
        .filter(|p| p.is_file())
        .collect();
    (paths.len() == 1).then(|| (paths[0].clone(), id.to_owned()))
}

pub fn tail(path: &Path) -> Option<String> {
    let mut f = File::open(path).ok()?;
    let len = f.metadata().ok()?.len();
    let start = len.saturating_sub(TAIL_BYTES);
    f.seek(SeekFrom::Start(start)).ok()?;
    let mut bytes = Vec::new();
    f.take(TAIL_BYTES).read_to_end(&mut bytes).ok()?;
    let text = String::from_utf8_lossy(&bytes);
    Some(if start > 0 {
        text.split_once('\n')?.1.to_owned()
    } else {
        text.into_owned()
    })
}

fn timestamp(v: &Value) -> Option<SystemTime> {
    Some(
        DateTime::parse_from_rfc3339(v.as_str()?)
            .ok()?
            .with_timezone(&Utc)
            .into(),
    )
}
fn text(v: &Value) -> Option<String> {
    if let Some(s) = v.as_str() {
        return Some(s.chars().take(8192).collect());
    }
    let parts: Vec<_> = v
        .as_array()?
        .iter()
        .filter(|p| {
            matches!(
                p["type"].as_str(),
                Some("text" | "input_text" | "output_text")
            )
        })
        .filter_map(|p| p["text"].as_str())
        .collect();
    (!parts.is_empty()).then(|| parts.join("\n").chars().take(8192).collect())
}
/// Antigravity wraps what the user typed in `<USER_REQUEST>` and appends its own context.
fn user_request(content: &str) -> String {
    let inner = content
        .split_once("<USER_REQUEST>")
        .and_then(|(_, rest)| rest.split_once("</USER_REQUEST>"))
        .map_or(content, |(request, _)| request);
    inner.trim().chars().take(8192).collect()
}
/// A question tool call as text: each question, then its options as bullets. Codex names the
/// question `title` and lists options as strings; Claude names it `question` and labels options.
pub fn question_text(input: &Value) -> Option<String> {
    let questions: Vec<String> = input["questions"]
        .as_array()?
        .iter()
        .filter_map(|q| {
            let ask = q["question"].as_str().or_else(|| q["title"].as_str())?;
            let options = q["options"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(|o| o.as_str().or_else(|| o["label"].as_str()))
                .map(|o| format!("• {}", o.trim()));
            (!ask.trim().is_empty()).then(|| {
                std::iter::once(ask.trim().to_owned())
                    .chain(options)
                    .collect::<Vec<_>>()
                    .join("\n")
            })
        })
        .collect();
    let numbered = questions.len() > 1;
    let text = questions
        .iter()
        .enumerate()
        .map(|(i, q)| {
            if numbered {
                format!("{}. {q}", i + 1)
            } else {
                q.clone()
            }
        })
        .collect::<Vec<_>>()
        .join("\n\n");
    (!text.is_empty()).then(|| text.chars().take(8192).collect())
}
pub fn parse(source: &str, provider: Provider, session_id: &str) -> Metadata {
    let mut result = Metadata::default();
    // The call that asked the pending question; its answer names the same call.
    let mut pending: Option<String> = None;
    if !matches!(
        provider,
        Provider::Codex | Provider::Claude | Provider::Antigravity
    ) {
        return result;
    }
    for line in source.lines() {
        let Ok(v) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        let time = timestamp(&v["timestamp"]).or_else(|| timestamp(&v["created_at"]));
        let mut request = None;
        let mut message = None;
        let mut asked: Option<(Option<String>, String)> = None;
        let mut answered = false;
        match provider {
            Provider::Codex => {
                if v["type"] == "turn_context" {
                    result.model = v["payload"]["model"]
                        .as_str()
                        .map(str::to_owned)
                        .or(result.model);
                    result.reasoning = v["payload"]["effort"]
                        .as_str()
                        .or_else(|| v["payload"]["reasoning_effort"].as_str())
                        .map(str::to_owned)
                        .or(result.reasoning);
                }
                let p = &v["payload"];
                if v["type"] != "event_msg" {
                    continue;
                }
                let call = || p["call"].as_str().map(str::to_owned);
                match p["type"].as_str() {
                    Some("user_message") => request = text(&p["message"]),
                    Some("agent_message") => message = text(&p["message"]),
                    Some("question") => asked = text(&p["message"]).map(|t| (call(), t)),
                    Some("question_answered") => answered = pending.is_some() && call() == pending,
                    _ => {}
                }
            }
            Provider::Claude => {
                if v["sessionId"].as_str() != Some(session_id) || v["isSidechain"] == true {
                    continue;
                }
                let content = &v["message"]["content"];
                let parts = || content.as_array().into_iter().flatten();
                if v["type"] == "assistant" {
                    result.model = v["message"]["model"]
                        .as_str()
                        .filter(|m| *m != "<synthetic>")
                        .map(str::to_owned)
                        .or(result.model);
                    result.reasoning = v["perTurnEffort"]
                        .as_str()
                        .or_else(|| v["effort"].as_str())
                        .map(str::to_owned)
                        .or(result.reasoning);
                    message = text(content);
                    asked = parts()
                        .find(|p| p["type"] == "tool_use" && p["name"] == "AskUserQuestion")
                        .and_then(|p| {
                            Some((
                                p["id"].as_str().map(str::to_owned),
                                question_text(&p["input"])?,
                            ))
                        });
                } else if v["type"] == "user" {
                    if v.get("toolUseResult").is_none() && v["isMeta"] != true {
                        request = text(content);
                    }
                    answered = pending.is_some()
                        && parts().any(|p| {
                            p["type"] == "tool_result"
                                && p["tool_use_id"].as_str() == pending.as_deref()
                        });
                }
            }
            // Antigravity writes one record per finished step. A question is an `ask_question`
            // tool call closing a planner response; the next record is its result.
            Provider::Antigravity => match v["type"].as_str() {
                Some("USER_INPUT") => request = v["content"].as_str().map(user_request),
                Some("PLANNER_RESPONSE") => {
                    result.model = v["model"].as_str().map(str::to_owned).or(result.model);
                    message = text(&v["content"]).filter(|m| !m.trim().is_empty());
                    asked = v["tool_calls"]
                        .as_array()
                        .into_iter()
                        .flatten()
                        .find(|call| call["name"] == "ask_question")
                        .and_then(|call| call["args"]["questions"].as_str())
                        .and_then(|raw| serde_json::from_str::<Value>(raw).ok())
                        .and_then(|questions| {
                            question_text(&serde_json::json!({ "questions": questions }))
                        })
                        .map(|text| (None, text));
                    answered = asked.is_none();
                }
                _ => answered = true,
            },
            _ => continue,
        }
        if request.is_some() || message.is_some() || asked.is_some() {
            result.updated_at = time.or(result.updated_at);
        }
        // A new request also answers whatever was asked before it.
        if answered || request.is_some() {
            result.question = None;
            pending = None;
        }
        if let Some(request) = request {
            result.request = Some(request);
            result.requested_at = time;
            result.last_message = None;
        }
        if message.is_some() {
            result.last_message = message;
        }
        if let Some((call, text)) = asked {
            result.question = Some(text);
            pending = call;
        }
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn claude_binding_rejects_stale_pid_and_ambiguous_transcripts() {
        let root = std::env::temp_dir().join(format!("ai-fleet-binding-{}", std::process::id()));
        struct Cleanup(PathBuf);
        impl Drop for Cleanup {
            fn drop(&mut self) {
                let _ = std::fs::remove_dir_all(&self.0);
            }
        }
        std::fs::create_dir(&root).unwrap();
        let _cleanup = Cleanup(root.clone());
        std::fs::create_dir(root.join("sessions")).unwrap();
        std::fs::create_dir_all(root.join("projects/one")).unwrap();
        let id = "12345678-1234-1234-1234-123456789abc";
        let registry = serde_json::json!({"pid": 42, "sessionId": id, "pidDomain": "darwin", "kind": "interactive", "procStart": "Tue Oct 20 09:00:00 2026"});
        std::fs::write(root.join("sessions/42.json"), registry.to_string()).unwrap();
        let path = root.join("projects/one").join(format!("{id}.jsonl"));
        std::fs::write(&path, "").unwrap();
        let mut session = Session {
            id: "42-start".into(),
            pid: 42,
            started: 1792486800 * 1_000_000,
            provider: Provider::Claude,
            cwd: None,
            project: "irrelevant".into(),
            status: "Live",
            location: None,
            link_reason: None,
        };
        // Derive the fixture epoch rather than depending on the machine timezone.
        session.started = DateTime::parse_from_rfc3339("2026-10-20T09:00:00Z")
            .unwrap()
            .timestamp_micros() as u64;
        assert_eq!(claude_binding(&session, &root).unwrap().0, path);
        session.started += 1_000_000;
        assert!(claude_binding(&session, &root).is_none());
        session.started -= 1_000_000;
        std::fs::create_dir(root.join("projects/two")).unwrap();
        std::fs::write(root.join("projects/two").join(format!("{id}.jsonl")), "").unwrap();
        assert!(claude_binding(&session, &root).is_none());
    }

    #[test]
    fn claude_uses_real_requests_and_excludes_tools_sidechains_and_other_sessions() {
        let data = parse(
            r#"
{"type":"user","sessionId":"a","timestamp":"2026-10-20T09:00:00Z","message":{"content":[{"type":"text","text":"Fix layout"}]}}
{"type":"assistant","sessionId":"a","timestamp":"2026-10-20T09:00:10Z","effort":"high","message":{"model":"claude-sonnet","content":[{"type":"text","text":"Working on it"}]}}
{"type":"user","sessionId":"a","timestamp":"2026-10-20T09:00:20Z","toolUseResult":{},"message":{"content":[{"type":"tool_result","content":"done"}]}}
{"type":"user","sessionId":"other","timestamp":"2026-10-20T09:01:00Z","message":{"content":"Wrong request"}}
{"type":"assistant","sessionId":"a","isSidechain":true,"message":{"model":"wrong"}}
{"type":"assistant","sessionId":"a","timestamp":"2026-10-20T09:00:30Z","message":{"model":"claude-sonnet","content":[{"type":"text","text":"Fixed"}]}}
incomplete json
"#,
            Provider::Claude,
            "a",
        );
        assert_eq!(data.request.as_deref(), Some("Fix layout"));
        assert_eq!(data.last_message.as_deref(), Some("Fixed"));
        assert_eq!(data.model.as_deref(), Some("claude-sonnet"));
        assert_eq!(data.reasoning.as_deref(), Some("high"));
        assert!(data.updated_at.unwrap() > data.requested_at.unwrap());
    }

    #[test]
    fn claude_question_tool_is_pending_until_its_result_or_a_new_request() {
        let asked = r#"{"type":"assistant","sessionId":"a","message":{"content":[{"type":"text","text":"I need one decision."}]}}
{"type":"assistant","sessionId":"a","message":{"content":[{"type":"tool_use","id":"toolu_1","name":"AskUserQuestion","input":{"questions":[{"question":"Which branch should I use?","header":"Branch","options":[{"label":"main","description":"The default"},{"label":"develop","description":"Work in progress"}]}]}}]}}"#;
        let data = parse(asked, Provider::Claude, "a");
        assert_eq!(
            data.question.as_deref(),
            Some("Which branch should I use?\n• main\n• develop")
        );
        assert_eq!(data.last_message.as_deref(), Some("I need one decision."));
        let other = r#"{"type":"user","sessionId":"a","toolUseResult":{},"message":{"content":[{"type":"tool_result","tool_use_id":"toolu_other"}]}}"#;
        assert!(
            parse(&format!("{asked}\n{other}"), Provider::Claude, "a")
                .question
                .is_some(),
            "Another tool's result answers nothing"
        );
        let answer = r#"{"type":"user","sessionId":"a","toolUseResult":{},"message":{"content":[{"type":"tool_result","tool_use_id":"toolu_1"}]}}"#;
        let request =
            r#"{"type":"user","sessionId":"a","message":{"content":"Never mind, use main"}}"#;
        for closing in [answer, request] {
            let data = parse(&format!("{asked}\n{closing}"), Provider::Claude, "a");
            assert!(data.question.is_none());
        }
    }
    #[test]
    fn antigravity_transcript_gives_request_reply_model_and_pending_question() {
        // Record shapes from Antigravity CLI 1.5.15's transcript.jsonl.
        let turn = r#"{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-11-23T12:19:10Z","content":"<USER_REQUEST>\nRun the tests\n</USER_REQUEST>\n<ADDITIONAL_METADATA>\nlocal time\n</ADDITIONAL_METADATA>"}
{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-23T12:19:11Z","model":"gemini-3.8-flash-high","thinking":"Plan.","tool_calls":[{"name":"run_command","args":{"CommandLine":"\"make test\""}}]}
{"step_index":2,"source":"MODEL","type":"GENERIC","status":"DONE","created_at":"2026-11-23T12:19:17Z","content":"Completed"}
{"step_index":3,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-23T12:20:02Z","model":"gemini-3.8-flash-high","content":"All tests pass."}"#;
        let data = parse(turn, Provider::Antigravity, "a");
        assert_eq!(data.request.as_deref(), Some("Run the tests"));
        assert_eq!(data.last_message.as_deref(), Some("All tests pass."));
        assert_eq!(data.model.as_deref(), Some("gemini-3.8-flash-high"));
        assert!(data.updated_at > data.requested_at);
        assert!(data.question.is_none());
        let asked = format!(
            "{turn}\n{}",
            r#"{"step_index":4,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-23T12:20:20Z","tool_calls":[{"name":"ask_question","args":{"questions":"[{\"is_multi_select\":false,\"options\":[\"Continue\",\"Explore\"],\"question\":\"How to proceed?\"}]"}}]}"#
        );
        let data = parse(&asked, Provider::Antigravity, "a");
        assert_eq!(
            data.question.as_deref(),
            Some("How to proceed?\n• Continue\n• Explore")
        );
        assert_eq!(data.last_message.as_deref(), Some("All tests pass."));
        let result = r#"{"step_index":5,"source":"MODEL","type":"GENERIC","status":"DONE","created_at":"2026-11-23T12:22:04Z","content":"A1: User Skipped"}"#;
        assert!(
            parse(&format!("{asked}\n{result}"), Provider::Antigravity, "a")
                .question
                .is_none()
        );
    }
    #[test]
    fn several_questions_are_numbered_and_codex_options_are_plain_strings() {
        let input = serde_json::json!({"questions":[
            {"title":"Release 0.2.2?","options":["Yes","Keep it in the repository"]},
            {"title":"Anything else?","options":null},
            {"title":"  "}
        ]});
        assert_eq!(
            question_text(&input).as_deref(),
            Some("1. Release 0.2.2?\n• Yes\n• Keep it in the repository\n\n2. Anything else?")
        );
        assert!(question_text(&serde_json::json!({"questions":[]})).is_none());
    }
    #[test]
    fn codex_uses_turn_context_and_submitted_events_and_clears_previous_answer() {
        let data = parse(
            r#"
{"type":"turn_context","payload":{"model":"gpt-6.1-sol","effort":"medium"}}
{"type":"event_msg","timestamp":"2026-10-20T09:00:00Z","payload":{"type":"user_message","message":"First"}}
{"type":"event_msg","timestamp":"2026-10-20T09:00:10Z","payload":{"type":"agent_message","message":"Done"}}
{"type":"event_msg","timestamp":"2026-10-20T09:00:20Z","payload":{"type":"user_message","message":"Next"}}
{"type":"event_msg","timestamp":"2026-10-20T09:00:30Z","payload":{"type":"token_count"}}
"#,
            Provider::Codex,
            "a",
        );
        assert_eq!(data.request.as_deref(), Some("Next"));
        assert!(data.last_message.is_none());
        assert_eq!(data.updated_at, data.requested_at);
        assert_eq!(data.model.as_deref(), Some("gpt-6.1-sol"));
        assert_eq!(data.reasoning.as_deref(), Some("medium"));
    }
}
