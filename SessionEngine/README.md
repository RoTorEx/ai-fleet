# Session engine

A private executable bundled in `Contents/MacOS` and built for each release
architecture. It discovers running interactive Codex, Claude, Kimi, Qwen, Gemini
and Grok sessions in iTerm2, selects an exact pane on request (Jump) and reads
activity. Activity parsing is verified for Codex and Claude, and for Kimi work,
approvals, finished turns and provider errors; other providers keep an explicit
Unknown state.

All of it is Fleet code and is changed here directly:

| File | Owns |
| --- | --- |
| `src/main.rs` | JSON-lines protocol, scan and Jump workers, row assembly |
| `src/process.rs`, `src/command.rs` | provider process discovery and identity |
| `src/model.rs` | sessions, pane linkage, Jump validation |
| `src/iterm.rs`, `src/iterm.js` | the iTerm2 helper: pane list, screen and title samples, Jump |
| `src/content.rs`, `src/activity.rs` | screen parsing, state and reply/attention tracking |
| `src/session_data.rs`, `src/codex_metadata.rs` | transcript binding, messages and pending questions |

The discovery, Jump and activity modules began as copies of AI Session Hub
(MIT, same author) at revision `690bad1`. Since Fleet 1.6.0 they are ordinary
Fleet code; AI Session Hub is deprecated and is not a source of updates.

Input (one JSON object per line):

```json
{"requestId":1,"command":"refresh","force":true}
{"requestId":2,"command":"jump","sessionId":"PID-START"}
```

Responses contain protocol: 1, requestID, kind and optional error. Snapshots
contain sessions and observedAt in epoch seconds. Sessions retain process
identity, project, terminal-derived name, optional location, observed activity
and optional bound provider metadata. Errors are not empty successful snapshots.
EOF joins workers and drops their helpers. There is no accepted terminal text or
shell command. Product/lifecycle contract: business/agents.md in the parent.

Additive row dataVersion 1 exposes process identity, activity sample time,
provider message/request times and a work-time source. The complete meanings,
precedence and unknown/stale behavior are owned by
[Agent session contract](../docs/contracts/agent-sessions.md).
