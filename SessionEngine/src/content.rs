//! Parses a bounded sample of a pane's visible screen into state and conversation turns.
//! It never supplies process identity or authorizes navigation.
use crate::{model, process::Provider};

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Role {
    You,
    Agent,
    Action,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Message {
    pub role: Role,
    pub text: String,
}
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Content {
    pub state: &'static str,
    pub messages: Vec<Message>,
    pub context: String,
    pub model: Option<String>,
    pub reasoning: Option<String>,
}
fn clean(line: &str) -> String {
    model::safe_text(line).trim_end().to_owned()
}

pub fn parse(text: &str, provider: Provider) -> Content {
    // Discovery/Jump support does not imply a verified terminal-state grammar.
    if provider == Provider::Kimi {
        return Content {
            state: kimi_state(text),
            ..Content::default()
        };
    }
    if !matches!(provider, Provider::Codex | Provider::Claude) {
        return Content {
            state: "Live · activity unknown",
            context: text.chars().take(8192).collect(),
            ..Content::default()
        };
    }
    let lines: Vec<_> = text.lines().map(clean).collect();
    let tail = lines
        .iter()
        .rev()
        .take(24)
        .cloned()
        .collect::<Vec<_>>()
        .join("\n");
    // Claude Code's selection dialog, such as a question with options, replaces the status line
    // and the prompt, so its key hints are the last row.
    let choosing = provider == Provider::Claude
        && lines
            .iter()
            .rev()
            .find(|line| !line.trim().is_empty())
            .is_some_and(|line| line.contains("Enter to select") && line.contains("Esc to cancel"));
    let state = if tail.contains("Would you like to run")
        || tail.contains("Do you trust")
        || tail.contains("Do you want to proceed")
        || tail.contains("Yes, proceed")
    {
        "Needs approval"
    } else if choosing {
        "Waiting for input"
    } else if tail.contains("esc to interrupt") || tail.contains("ctrl+c to interrupt") {
        "Working"
    } else if tail.contains("context left")
        || tail.contains("? for shortcuts")
        || tail.contains("bypass permissions")
        // Claude Code replaces the shortcuts hint with its permission-mode line.
        || tail.contains("shift+tab to cycle")
    {
        "Waiting for input"
    } else {
        "Live · activity unknown"
    };
    let mut messages = Vec::new();
    let mut current: Option<Message> = None;
    for line in &lines {
        let trimmed = line.trim_start();
        // Status/footer and the current input/draft are not conversation turns.
        if trimmed.contains("esc to interrupt")
            || trimmed.contains("context left")
            || trimmed.starts_with("tab to queue")
            || trimmed.contains("? for shortcuts")
        {
            continue;
        }
        // Codex lists what waits for the user under its status line: "Queued follow-up inputs",
        // a count and a key hint. The block is chrome, not something the agent said.
        if provider == Provider::Codex
            && trimmed
                .strip_prefix('•')
                .is_some_and(|rest| rest.trim() == "Queued follow-up inputs")
        {
            if let Some(previous) = current.take() {
                push(&mut messages, previous);
            }
            continue;
        }
        let marker = match provider {
            Provider::Codex if trimmed.starts_with('›') => {
                Some((Role::You, trimmed.trim_start_matches('›').trim()))
            }
            Provider::Claude if trimmed.starts_with('❯') || trimmed.starts_with('>') => {
                Some((Role::You, trimmed.trim_start_matches(['❯', '>']).trim()))
            }
            Provider::Codex if trimmed.starts_with('•') => {
                let text = trimmed.trim_start_matches('•').trim();
                let action = [
                    "Ran ",
                    "Running ",
                    "Read ",
                    "Edited ",
                    "Updated ",
                    "Searched ",
                    "Explored ",
                ]
                .iter()
                .any(|p| text.starts_with(p));
                Some((if action { Role::Action } else { Role::Agent }, text))
            }
            Provider::Claude if trimmed.starts_with('⏺') => {
                let body = trimmed.trim_start_matches('⏺').trim();
                let action = [
                    "Read(", "Bash(", "Write(", "Edit(", "Update(", "Grep(", "Glob(",
                ]
                .iter()
                .any(|prefix| body.starts_with(prefix));
                Some((if action { Role::Action } else { Role::Agent }, body))
            }
            _ => None,
        };
        if let Some((role, body)) = marker {
            if let Some(previous) = current.take() {
                push(&mut messages, previous);
            }
            current = Some(Message {
                role,
                text: body.to_owned(),
            });
        } else if let Some(message) = current.as_mut()
            && message.text.len() < 8192
        {
            message.text.push('\n');
            message.text.push_str(trimmed);
        }
    }
    // An unanswered bottom prompt can be an unsubmitted draft/queued message.
    // Do not label it as a request that the agent has already received.
    if let Some(last) = current
        && last.role != Role::You
    {
        push(&mut messages, last);
    }
    if messages.len() > 32 {
        messages.drain(..messages.len() - 32);
    }
    let context = if messages.is_empty() {
        lines
            .iter()
            .rev()
            .take(32)
            .rev()
            .cloned()
            .collect::<Vec<_>>()
            .join("\n")
    } else {
        String::new()
    };
    Content {
        state,
        messages,
        context,
        model: metadata(text, "model"),
        reasoning: metadata(text, "reasoning").or_else(|| metadata(text, "effort")),
    }
}
/// What a Kimi Code screen shows. It has no bound transcript, so its visible response stands in
/// as reply evidence and a trailing provider error as the reason it stopped.
#[derive(Default)]
pub struct Kimi {
    pub state: &'static str,
    /// Response rows above the status row; empty unless the state is known.
    pub screen: String,
    pub error: Option<String>,
}
fn kimi_state(text: &str) -> &'static str {
    kimi(text).state
}
/// Kimi Code 0.39.x: chrome is distinct from response text and thinking configuration.
pub fn kimi(text: &str) -> Kimi {
    let state = |state| Kimi {
        state,
        ..Kimi::default()
    };
    let lines: Vec<_> = text
        .lines()
        .rev()
        .take(24)
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .map(str::trim)
        .collect();
    let choice = |line: &str| {
        let line = line.trim_start_matches(['❯', '●', '○', ' ']);
        let line =
            line.trim_start_matches(|c: char| c.is_ascii_digit() || matches!(c, '.' | ')' | ' '));
        matches!(
            line,
            "Approve once" | "Approve for this session" | "Reject" | "Reject with feedback"
        )
    };
    if lines.iter().filter(|line| choice(line)).count() >= 2 {
        return state("Needs approval");
    }
    let border = |line: &&str| {
        line.chars().count() >= 8
            && line
                .chars()
                .all(|c| matches!(c, '─' | '━' | '╭' | '╮' | '╰' | '╯' | '┌' | '┐' | '└' | '┘'))
    };
    let borders: Vec<_> = lines
        .iter()
        .enumerate()
        .filter(|(_, line)| border(line))
        .map(|(index, _)| index)
        .collect();
    let Some(&bottom) = borders.last() else {
        return state("Live · activity unknown");
    };
    let Some(&top) = borders.iter().rev().nth(1) else {
        return state("Live · activity unknown");
    };
    // Require the actual editor frame and the model/mode footer below it.
    // A prose quote or a model's configured thinking effort is not live work.
    let chrome = bottom - top <= 8
        && lines[bottom + 1..].iter().any(|line| {
            line.contains(" thinking")
                || line
                    .split_whitespace()
                    .next()
                    .is_some_and(|s| matches!(s, "auto" | "yolo" | "plan" | "swarm" | "tower"))
        });
    if !chrome {
        return state("Live · activity unknown");
    }
    let active = lines[..top].iter().any(|line| {
        let mut chars = line.chars();
        let Some(first) = chars.next() else {
            return false;
        };
        let tail = chars.as_str().trim_start_matches('\u{fe0f}');
        let separated = tail.is_empty() || tail.starts_with(char::is_whitespace);
        if !separated {
            return false;
        }
        if "🌑🌒🌓🌔🌕🌖🌗🌘".contains(first) {
            return true;
        }
        "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏".contains(first)
            && (tail.trim_start().starts_with("thinking...")
                || tail.trim_start().starts_with("working..."))
    });
    // The working marker sits on the row above the Todo block, or above the editor without one.
    let separator = borders
        .iter()
        .rev()
        .nth(2)
        .copied()
        .filter(|&i| i + 1 == top || lines.get(i + 1).is_some_and(|line| *line == "Todo"));
    let reply = &lines[..separator.unwrap_or(top)];
    // Without a visible separator, rows of bullets alone may be the tail of a tall Todo list with
    // the marker row scrolled off. Then nothing proves the turn is over.
    let marker_row_visible = match separator {
        Some(row) => row > 0,
        None => reply
            .iter()
            .any(|line| !line.is_empty() && !line.starts_with(['●', '○', '✓'])),
    };
    if active {
        return state("Working");
    }
    if !marker_row_visible {
        return state("Live · activity unknown");
    }
    let shown: Vec<_> = reply.iter().filter(|line| !line.is_empty()).collect();
    Kimi {
        state: "Waiting for input",
        screen: shown
            .iter()
            .map(|line| **line)
            .collect::<Vec<_>>()
            .join("\n"),
        error: shown
            .iter()
            .rev()
            .take(6)
            .find(|line| line.starts_with("Error: ["))
            .map(|line| (**line).to_owned()),
    }
}

fn metadata(text: &str, label: &str) -> Option<String> {
    text.lines().find_map(|line| {
        let line = line.trim().trim_matches(['│', ' ']);
        let (key, value) = line.split_once(':')?;
        (key.trim().eq_ignore_ascii_case(label) && !value.trim().is_empty())
            .then(|| value.trim().to_owned())
    })
}

fn push(messages: &mut Vec<Message>, mut message: Message) {
    message.text = message.text.trim().chars().take(8192).collect();
    if !message.text.is_empty() {
        messages.push(message);
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn kimi_uses_its_own_active_chrome_and_does_not_confuse_thinking_configuration() {
        let screen = |body: &str| {
            format!(
                "{body}\n╭──────────────────╮\n  draft\n╰──────────────────╯\nauto K2.8 Preview thinking: high\n"
            )
        };
        for spinner in ["🌑", "🌒", "🌘", "⠋ thinking...", "⠹ working..."] {
            assert_eq!(parse(&screen(spinner), Provider::Kimi).state, "Working");
        }
        assert_eq!(
            parse(&screen("✓ Finished"), Provider::Kimi).state,
            "Live · activity unknown"
        );
        assert_eq!(
            parse(&screen("quoted 🌑 work\n> ⠋ thinking..."), Provider::Kimi).state,
            "Waiting for input",
            "A quoted marker is not live work, and the marker row is in sight"
        );
        assert_eq!(
            parse("🌑\nno editor", Provider::Kimi).state,
            "Live · activity unknown"
        );
        assert_eq!(
            parse("unrecognized output", Provider::Kimi).state,
            "Live · activity unknown"
        );
        assert_eq!(
            parse(
                &screen("🌑\n❯ Approve once\n  Approve for this session\n  Reject"),
                Provider::Kimi
            )
            .state,
            "Needs approval"
        );
        // Taken from a session that stopped on its usage limit, Todo block above the editor.
        let stopped = kimi(&screen(
            "● Ran a command\n  ALL_CHECKS_PASSED\n  Error: [provider.api_error] 429 You've reached your 5-hour usage limit.\n  If this persists, run `/export-debug-zip`.\n\n──────────────────\n  Todo\n  ● Check the patches\n  ○ Prepare the package",
        ));
        assert_eq!(stopped.state, "Waiting for input");
        assert!(
            stopped.screen.ends_with("run `/export-debug-zip`."),
            "The Todo block is not response text"
        );
        assert_eq!(
            stopped.error.as_deref(),
            Some("Error: [provider.api_error] 429 You've reached your 5-hour usage limit.")
        );
        assert_eq!(
            kimi(&screen(
                "● Check the patches\n○ Prepare the package\n✓ Read the report"
            ))
            .state,
            "Live · activity unknown",
            "Todo items alone may hide the marker row above the sample"
        );
        assert_eq!(
            kimi(&screen(
                "🌖 Working\n──────────────────\n  Todo\n  ● Check the patches"
            ))
            .state,
            "Working"
        );
        let content = parse(&screen("🌑"), Provider::Kimi);
        assert!(
            content.messages.is_empty(),
            "State evidence cannot invent a transcript"
        );
    }

    #[test]
    fn new_provider_screens_cannot_borrow_codex_or_claude_activity() {
        for provider in [
            Provider::Kimi,
            Provider::Qwen,
            Provider::Gemini,
            Provider::Grok,
        ] {
            let content = parse(
                "• old quoted answer\ncontext left\nesc to interrupt",
                provider,
            );
            assert_eq!(content.state, "Live · activity unknown");
            assert!(content.messages.is_empty());
        }
    }
    #[test]
    fn reads_visible_turns_actions_and_status_without_treating_draft_as_request() {
        let c = parse(
            "› Fix this\n  please\n• Ran cargo test\n  all passed\n• Fixed it\n• Working (1s • esc to interrupt)\n› unsent draft\n69% context left",
            Provider::Codex,
        );
        assert_eq!(c.state, "Working");
        assert_eq!(c.messages.len(), 3);
        assert_eq!(c.messages[0].text, "Fix this\nplease");
        assert_eq!(c.messages[1].role, Role::Action);
        assert_eq!(c.messages[2].text, "Fixed it");
    }
    #[test]
    fn claude_selection_dialog_waits_for_input_only_as_the_last_row() {
        let dialog = "⏺ Done so far.\n────\n ☐ Branch\n│ Which branch?\n❯ 1. main\n  2. develop\n────\n\nEnter to select · ↑/↓ to navigate · Esc to cancel\n";
        assert_eq!(parse(dialog, Provider::Claude).state, "Waiting for input");
        assert_eq!(
            parse(dialog, Provider::Codex).state,
            "Live · activity unknown"
        );
        let quoted =
            "⏺ The dialog says: Enter to select · Esc to cancel\n\n✻ Cooking… (esc to interrupt)";
        assert_eq!(parse(quoted, Provider::Claude).state, "Working");
    }
    #[test]
    fn approval_has_priority_and_unrecognized_screens_remain_unknown() {
        assert_eq!(
            parse(
                "Do you trust this folder?\n? for shortcuts",
                Provider::Claude
            )
            .state,
            "Needs approval"
        );
        let c = parse("unrecognized output", Provider::Claude);
        assert_eq!(c.state, "Live · activity unknown");
        assert_eq!(c.context, "unrecognized output");
    }
    #[test]
    fn claude_permission_mode_footer_is_idle_until_work_is_in_progress() {
        let screen = |footer: &str| {
            format!("❯ Task\n⏺ Done.\n❯ \n──────\n  user@host:repo [Model]\n  {footer}")
        };
        let idle = parse(
            &screen("⏵⏵ auto mode on (shift+tab to cycle)"),
            Provider::Claude,
        );
        assert_eq!(idle.state, "Waiting for input");
        assert_eq!(idle.messages.last().unwrap().text, "Done.");
        assert_eq!(
            parse(
                &screen("⏵⏵ auto mode on (shift+tab to cycle) · esc to interrupt"),
                Provider::Claude
            )
            .state,
            "Working"
        );
    }
}
