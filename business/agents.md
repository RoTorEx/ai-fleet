# Agents

## Workflow

The configured global shortcut opens the unified menu with Agents already
expanded below provider connections. A separate filter icon contains session
states; location groups collapse independently and show the last two path
components (home is ~). Processes lives under application options and returns
to the unified menu with Command-A. There is no separate Agents navigation step.
The existing configured global shortcut is preserved.

The compact monochrome view uses project headings, collapsible groups and stable
session rows. The full first line is the task title; provider/model and the state
share the second. Working includes elapsed request time in parentheses and a
moving strip beneath the row; Reduced Motion makes the strip static. The explicit timer in validated terminal output takes precedence over bound
request timestamps. With neither available, ≥ means continuously observed work duration only. Repeated
snapshots do not reset the clock; ending work, hiding monitoring or changing
process identity resets the fallback. Last message uses provider-log time or —.
Idle covers opened/untracked idle states; Ready means a newly completed reply has
not been opened since it arrived, without claiming to prove reading. Question,
Approval, Error (reported blocker), Unknown, Stale and Unlinked remain distinct.
Source activity glyphs and repeated trailing group paths are stripped only from
the display title. The list scrolls once the full menu reaches 75% of available
screen height. Completion percentages and process relationships are not guessed.

Click opens the exact existing iTerm2 window/tab/split and leaves the overview
open. Session Jump never sends text, approvals, stop commands or tab closure.
The separate Processes section offers explicit process termination as described below.
Command-A returns to Providers. Escape, outside click or the global toggle closes the
menu (outside-click dismissal can be disabled in General). Ambiguous/exited links report an error rather than choosing a similar title.
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
60-second user-idle sleep does not apply here. Providers/close sends EOF; workers finish
bounded in-flight work and drop/reap helpers. Scans never overlap in Swift. A
pending scan after 15 seconds is marked stale; an unconfirmed Jump after 8 seconds
becomes retryable. Those deadlines bound UI uncertainty rather than establish
process death. Replies must match request ID and connection generation. Failed
scans retain and mark the last snapshot stale; no stale row claims active work.

Inherited Rust tests protect identity replacement, ambiguity, noninteractive
exclusion, state precedence and provider binding. Swift tests exercise real pipe
framing, grouping, failed Jump, missing engine and light/dark layout. Release
smoke checks require the helper/license in the Apple Silicon archive. Installed
checks cover shortcuts, live Jump, menu retention and helper cleanup.

## Process controls

Agents exposes Sessions and Processes through its view menu. Processes lists only the current
user's exact Codex and codex-code-mode-host executables, including background
servers and updaters left after closing terminals. Native libproc discovery uses
executable paths, UID, controlling-terminal presence and microsecond start identity;
no prompts, environment or command-line arguments are collected. The visible list
refreshes every 3 seconds to show exits/restarts promptly without a permanent scan.
The timer stops when this section disappears.

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
may need resuming. No process is stopped automatically during account selection.
CodexProcessesTests covers ownership, PID replacement and real SIGTERM/SIGKILL
against only task-owned fixture processes.

### Current Codex metadata

The Fleet adapter reads only process-open writable Codex transcripts under the
canonical native sessions root. It accepts headers up to 1 MiB because current
session metadata includes longer base instructions, excludes explicitly declared
subagent transcripts, and requires exactly one remaining primary transcript.
Multiple primary candidates stay unknown; cwd, modification time and model names
never choose a conversation. PID/start identity is revalidated after the read.
The inherited parser consumes at most a 1 MiB tail. Pinned vendor code is unchanged.
