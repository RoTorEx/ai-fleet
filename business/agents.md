# Agents

## Workflow

The configured global shortcut opens AI Fleet. The menu has three tabs under
the header: Providers, Agents (grouped by collapsible location) and Processes.
Tabs split the full width and look like bookmarks: the active tab and its page
are one shape. Click a tab or press ← / →, which wrap around; the last tab is
remembered across openings and restarts. A gold/yellow dot on Agents flags a session waiting for approval or
an answer. The session engine runs while the menu is open so that dot stays
current; Processes rescans while the menu is open so its tab shows a count. The menu grows up to
80% of the screen's visible height; past that only the active tab scrolls, with
a terminal-style overlay scroller. No Command-A registration remains.

Each row shows the terminal session name without spinner glyphs or the iTerm
job suffix such as "(codex)"; provider and model sit on the second line. The
top-right time is an exact running stopwatch while the session works and a
rough one-unit age (~40s, ~5m, ~16h, ~3d) since the last message or observed
change otherwise. All / Needs you / Working / Idle filters with counts sit above
the groups; the chosen filter persists while Fleet runs. Each card keeps its session color on its icon and provider
name; resting the pointer on a card shows the latest captured request and reply
with their times in a popover. Collapsed groups persist while Fleet runs. The list hides the scroller and fades
at the bottom edge when more rows follow.

The compact colorful view follows the user's IMG_1195.MP4 reference: project
headings, collapsible groups, stable session rows, provider/model when known,
explicit status, last-event time, rotating working indicators and indeterminate
activity stripes. All/Needs you/Working/Idle/Unknown filters support larger lists.
Reduced Motion disables repeating animation. Percent completion and parent/child
relationships are never guessed from a directory or title.

Click opens the exact existing iTerm2 window/tab/split and leaves the overview
open. Session Jump never sends text, approvals, stop commands or tab closure.
The Processes tab offers explicit process termination as described below.
Escape, outside click (unless disabled in General) or the global toggle closes
the menu. Ambiguous/exited links report an error rather than choosing a similar title.
Opening a pane does not prove the user read its response.

## Ownership and data

AI Session Hub owns discovery, PID/start/TTY/ancestry identity, UUID Jump and
activity parsing. Its required MIT sources are vendored byte-for-byte at the
revision/checksums in SessionEngine/upstream.json. Updates must come from reviewed
upstream sources; make check verifies the pin. Fleet owns the private JSON-lines
adapter, native UI, lifecycle and packaging. The presentation-independent
[session contract](../docs/contracts/agent-sessions.md) owns typed states, evidence,
identity and timing for future UI composition. The standalone Hub CLI/TUI is
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

## Process controls

Process rows are two thin lines: kind on the left; on the right a folder icon in
a fixed column and the PID pressed against a small ⋯ menu for Stop and Force Quit.
The folder and PID share one hover card with the value and "Click to copy", and
copy on click. The second line has account on the left and start time with
seconds on the right. A short "Copied …" notice confirms each copy.
Agents and processes share one neutral block style; provider rows are unboxed. All and per-provider filters (only providers with a running process) and newest/oldest sort
sit above the list; provider-wide and background stops are in one ⋯ menu.
The Processes tab lists the current user's recognized provider executables,
including native version-named Claude binaries and installed Node entrypoints such as Kimi and Gemini.
Detached processes can remain after terminals close; their exact role/account
remains unknown without evidence, so rows say only "terminal" or "detached". Native libproc discovery uses
executable paths, UID, controlling-terminal presence and microsecond start identity;
Prompts and environment are not exported or logged; a Node runtime entry argument
may be read solely to match an installed provider executable. The visible list
refreshes every 3 seconds to show exits/restarts promptly without a permanent scan.
The timer stops when the menu closes.

Each row offers Stop (SIGTERM) and Force Quit (SIGKILL), with confirmation naming
the selected PIDs and the effect on conversations/tools. Stop all background
processes snapshots only the visible background rows and uses SIGTERM; it never
escalates automatically. Before every signal the UID, executable, PID and start
identity are re-read. PID reuse, another owner, an exited process, and Fleet itself
are refused. Actual exit is observed for up to 2 seconds (ten 200-ms checks); a
survivor remains visible with an explicit Force Quit choice. Unknown observation
never claims successful exit. A client may restart its daemon; the next inventory
shows that new process rather than chasing and terminating it automatically.
Credentials, history and terminal tabs remain intact. Interrupted in-flight work
may need resuming. Switch process policies are owned by [Switch recovery](switch-recovery.md);
manual and switching controls remain separate from session discovery.
CodexProcessesTests covers ownership, PID replacement and real SIGTERM/SIGKILL
against only task-owned fixture processes.

## Backend preparation before design

The Agents service exposes typed contracts alongside legacy sessions. UI files
are unchanged in this stage. Current Codex response items and larger primary
transcript headers are adapted in Fleet-owned sources without changing the pin.
Terminal state remains explicitly heuristic. Provider message/request timestamps,
terminal timers and continuous observed duration have distinct provenance.
Backend preparation does not approve the prior experimental design; the future
interface can compose these fields independently. Combined user acceptance follows
design and does not block technical stages.
