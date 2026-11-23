//! Antigravity CLI transcripts, bound through the process itself. While it shows a conversation
//! the CLI holds `presence/<conversation>.lock` open for writing, and it appends every finished
//! step to `brain/<conversation>/.system_generated/logs/transcript.jsonl` as it happens. The
//! SQLite store beside them lags by up to half a minute and is not read.
use crate::{command, model::Session, process::Provider, session_data};
use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    process::Command,
    time::Duration,
};

pub fn read(sessions: &[&Session]) -> HashMap<String, session_data::Metadata> {
    let targets: Vec<_> = sessions
        .iter()
        .filter(|s| s.provider == Provider::Antigravity)
        .collect();
    if targets.is_empty() {
        return HashMap::new();
    }
    let Some(home) = std::env::var_os("HOME").map(PathBuf::from) else {
        return HashMap::new();
    };
    let Ok(root) = std::fs::canonicalize(home.join(".gemini/antigravity-cli")) else {
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
    let shown = conversations(&output, &root);
    targets
        .into_iter()
        .filter_map(|s| {
            let [conversation] = shown.get(&s.pid)?.as_slice() else {
                return None;
            };
            let transcript = root
                .join("brain")
                .join(conversation)
                .join(".system_generated/logs/transcript.jsonl");
            let text = session_data::tail(&transcript)?;
            let metadata = session_data::parse(&text, Provider::Antigravity, conversation);
            Some((s.id.clone(), metadata))
        })
        .collect()
}

/// The conversations each PID holds a writable presence lock for, from `lsof -Fpfan` output.
/// Two locks under one PID do not say which conversation is on screen, so the caller binds
/// only a single one.
fn conversations(output: &str, root: &Path) -> HashMap<u32, Vec<String>> {
    let presence = root.join("presence");
    let mut shown: HashMap<u32, Vec<String>> = HashMap::new();
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
        } else if let (Some(pid), Some(value), true) = (pid, line.strip_prefix('n'), writable) {
            let id = Path::new(value)
                .strip_prefix(&presence)
                .ok()
                .and_then(|name| name.to_str())
                .and_then(|name| name.strip_suffix(".lock"))
                .filter(|id| uuid(id));
            if let Some(id) = id {
                let ids = shown.entry(pid).or_default();
                if !ids.iter().any(|known| known == id) {
                    ids.push(id.to_owned());
                }
            }
        }
    }
    shown
}

/// The id becomes a path component, so it must be nothing but a UUID.
fn uuid(id: &str) -> bool {
    id.len() == 36
        && id.bytes().enumerate().all(|(i, c)| {
            if [8, 13, 18, 23].contains(&i) {
                c == b'-'
            } else {
                c.is_ascii_hexdigit()
            }
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_a_writable_presence_lock_names_the_conversation() {
        let root = Path::new("/Users/me/.gemini/antigravity-cli");
        let id = "61c12e25-0a39-48f9-be84-33f837dce041";
        let other = "e939662f-e855-4dac-bc94-0b884c2c97a6";
        let output = format!(
            "p100\nf3\nar\nn{root}/presence\nf9\nau\nn{root}/presence/{id}.lock\nf10\naw\nn{root}/log/cli.log\n\
             p200\nf4\nar\nn{root}/presence/{other}.lock\nf5\nau\nn{root}/presence/../../x.lock\n\
             p300\nf4\nau\nn{root}/presence/{id}.lock\nf5\nau\nn{root}/presence/{other}.lock\n",
            root = root.display()
        );
        let shown = conversations(&output, root);
        assert_eq!(shown[&100], [id]);
        assert!(
            !shown.contains_key(&200),
            "A read-only lock and a non-UUID name bind nothing"
        );
        assert_eq!(
            shown[&300].len(),
            2,
            "Two locks are left for the caller to refuse"
        );
    }
}
