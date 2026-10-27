# Agents

## Workflow

The configured global shortcut opens AI Fleet. Agents sits after Refresh now and
before Statistics. Command-A toggles Usage/Agents while the menu is open, also
after Jump transfers focus to iTerm2. The temporary Command-A registration is
removed on close. The existing configured global shortcut is preserved.

The compact colorful view follows the user's IMG_1195.MP4 reference: project
headings, collapsible groups, stable session rows, provider/model when known,
explicit status, last-event time, rotating working indicators and indeterminate
activity stripes. All/Needs you/Working/Idle/Unknown filters support larger lists.
Reduced Motion disables repeating animation. Percent completion and parent/child
relationships are never guessed from a directory or title.

Click opens the exact existing iTerm2 window/tab/split and leaves the overview
open. No agent receives text, approvals, start/stop commands or tab closure.
Command-A returns to Usage. Escape, outside click or the global toggle closes the
menu. Ambiguous/exited links report an error rather than choosing a similar title.
Opening a pane does not prove the user read its response.

## Ownership and data

AI Session Hub owns discovery, PID/start/TTY/ancestry identity, UUID Jump and
activity parsing. Its required MIT sources are vendored byte-for-byte at the
revision/checksums in SessionEngine/upstream.json. Updates must come from reviewed
upstream sources; make check verifies the pin. Fleet owns the private JSON-lines
adapter, native UI, lifecycle and packaging. The standalone Hub CLI/TUI is
independent and is not required by the app.

Only local interactive Codex/Claude in iTerm2 are supported. SSH, tmux, GUI
conversations and other providers/terminals remain outside this reader. Activity,
questions and blockers use visible terminal markers and are heuristic. Missing
markers remain Unknown. Provider metadata must be process-bound under Hub's
contract, never selected by newest file or cwd. Global login badges are not
assigned to already running agents.

Bounded request/answer observations stay in memory. Hover exposes a last request
and location. No session text is persisted, uploaded or logged; no model requests
are made for Agents.

## Lifecycle and defaults

One private fleet-session-engine ships inside Contents/MacOS. Protocol-1 JSON
lines travel over pipes with request IDs. Commands are refresh and jump; no shell,
external CLI lookup, sockets or daemon installation are needed.

Inventory runs every 2 seconds while Agents is visible. Window/Git mapping is
cached for 30 seconds, refreshed on new identities or manual refresh. All-session
activity is sampled at most every 5 seconds, immediately on entry/manual refresh
or inventory change. These split intervals bound reads while keeping the visible
monitor current; short between-poll events may be missed. Jump has an independent
warmed worker, so it never waits behind a status scan. At most two JXA helpers are
needed regardless of session count.

Visible Agents keeps updating after loss of keyboard focus; the standalone TUI's
60-second user-idle sleep does not apply here. Usage/close sends EOF; workers finish
bounded in-flight work and drop/reap helpers. Scans never overlap in Swift. A
pending scan after 15 seconds is marked stale; an unconfirmed Jump after 8 seconds
becomes retryable. Those deadlines bound UI uncertainty rather than establish
process death. Replies must match request ID and connection generation. Failed
scans retain and mark the last snapshot stale; activity animations stop.

Inherited Rust tests protect identity replacement, ambiguity, noninteractive
exclusion, state precedence and provider binding. Swift tests exercise real pipe
framing, grouping, failed Jump, missing engine and light/dark layout. Release
smoke checks require the helper/license in both architecture archives. Installed
checks cover shortcuts, live Jump, menu retention and helper cleanup.
