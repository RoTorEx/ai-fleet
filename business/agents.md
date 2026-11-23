# Agents

## Workflow

The configured global shortcut opens AI Fleet. The menu has three tabs under
the header: Providers, Agents (grouped by collapsible location) and Processes.
Tabs split the full width and look like bookmarks: the active tab and its page
are one shape. Click a tab or press ← / →, which wrap around; the last tab is
remembered across openings and restarts. An amber dot on Agents flags a session waiting for approval or
an answer. The session engine runs while the menu is open or agent session
alerts are enabled. Processes rescans while the menu is open so its tab shows a count. The menu grows up to
80% of the screen's visible height; past that only the active tab scrolls, with
a terminal-style overlay scroller. No Command-A registration remains.

Each row shows the terminal session name without spinner glyphs or the iTerm
job suffix such as "(codex)"; provider and model sit on the second line. The
top-right time is an exact running stopwatch while the session works and a
rough one-unit age (~40s, ~5m, ~16h, ~3d) since the last message or observed
change otherwise. All / Needs you / Working / Idle / Unknown filters with counts sit above
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

Fleet owns the whole session engine in `SessionEngine/`: discovery,
PID/start/TTY/ancestry identity, UUID Jump, activity parsing, the private
JSON-lines protocol, native UI, lifecycle and packaging. Parser and discovery
fixes are made there directly. The engine started as byte-for-byte copies of AI
Session Hub sources pinned by revision and checksum; every parser fix then took
a Hub commit, a copy and a re-pin, so since 1.6.0 the copies are ordinary Fleet
code and the pin is gone. AI Session Hub is a separate, deprecated project:
Fleet neither reads nor follows it. The presentation-independent
[session contract](../docs/contracts/agent-sessions.md) owns typed states, evidence,
identity and timing for future UI composition.

Local interactive Codex, Claude, Kimi, Qwen, Gemini and Grok sessions in iTerm2
are discoverable and support exact-pane Jump. SSH, tmux, GUI conversations and
other terminals remain outside this reader. Codex/Claude retain their verified
terminal-state and transcript parsers. Kimi Code 0.39.x uses its own moon/braille Working markers and explicit approval
choices, gated by native editor/footer chrome for work. With that chrome on
screen and no marker on its row (above the Todo block, or above the editor
without one) the session is Idle. When that row is out of the sampled screen,
because only Todo items are visible, the state stays Unknown rather than
implying Idle. Thinking-effort configuration does not mean Working. Kimi
transcript messages are not inferred. Qwen/Gemini/Grok remain
explicitly Unknown without borrowed status or transcript data; Unknown has its own filter and is
never counted as Idle. Running sessions are independent of quota-provider
visibility settings. Activity,
questions and blockers use visible terminal markers and are heuristic. Missing
markers remain Unknown. Provider metadata must be process-bound,
never selected by newest file or cwd. Codex 0.171 moved transcripts into a
shared app-server that records no client PID, which left every Codex session
without a transcript; there a live transcript is bound by the conversation name
in the pane's title, and only when one live transcript and one pane carry that
name. The [session contract](../docs/contracts/agent-sessions.md) owns the rule.
Global login badges are not assigned to already running agents.

Bounded request/answer observations stay in memory. Hover exposes a last request
and location. Fleet persists, uploads and logs no session text, and makes no model
requests for Agents. The one exit is the opt-in alert text handed to macOS
notifications, described under Lifecycle and defaults.

## Lifecycle and defaults

One private fleet-session-engine ships inside Contents/MacOS. Protocol-1 JSON
lines travel over pipes with request IDs. Commands are refresh and jump; no shell,
external CLI lookup, sockets or daemon installation are needed.

Inventory runs every 2 seconds while the menu is open or agent session alerts
are enabled. Window/Git mapping is
cached for 30 seconds, refreshed on new identities or manual refresh. All-session
activity is sampled at most every 5 seconds, immediately on entry/manual refresh
or inventory change. These split intervals bound reads while keeping the visible
monitor current; short between-poll events may be missed. Jump has an independent
warmed worker, so it never waits behind a status scan. At most two JXA helpers are
needed regardless of session count.

Visible Agents keeps updating after loss of keyboard focus; the standalone TUI's
60-second user-idle sleep does not apply here. Closing the menu with alerts off,
turning alerts off with the menu closed, or quitting sends EOF. Workers finish
bounded in-flight work and drop/reap helpers. Scans never overlap in Swift. A
pending scan after 15 seconds is marked stale; an unconfirmed Jump after 8 seconds
becomes retryable. Those deadlines bound UI uncertainty rather than establish
process death. Replies must match request ID and connection generation. Failed
scans retain and mark the last snapshot stale; activity animations stop.

**Agent session alerts** in Settings → General → Notifications are off by default.
With macOS notification permission, Fleet alerts on a newly observed completed
reply after work, or when a session newly requests approval, asks a question,
or reports a blocker. Each session starts from a silent baseline, including
after enabling alerts, app restart or a scan interruption. Cached samples and
repeated waiting states stay quiet. CLI exit and long-running work generate no
alert. Codex and Claude use the existing heuristic activity reader. Kimi
notifies for recognized approvals, for a finished turn and for a turn that
stopped on a provider error. Short events between samples may be missed.

For Codex the reader also takes the status Codex writes into its terminal title,
read with the screen: a spinner means the turn is still running, `Action
Required` means it waits for the user. Screen markers alone raised a false Done
when Codex hid its status line while streaming a message mid-turn, and showed a
queued question as Working. `Action Required` without a recognized approval
screen alerts as Question.

A question asked through the provider's question tool is read from the bound
transcript and stays pending until it is answered. While the session waits on
it, the alert and the row show the question and its options, `Which branch? •
main • develop`, numbered when there are several, instead of the agent's last
message: an alert should carry what the agent wants, not how to operate its
interface. Codex queues such a question under its status line as `Queued
follow-up inputs · 1 question · ⇧← to answer` and never prints the question
itself; through 1.6.3 that block was read as the agent's reply and became the
alert text. It is now skipped as chrome. Claude's question dialog replaces the
status line and the prompt, so it read as Unknown and raised no alert; its key
hints on the last row now read as Idle. A Codex session that cannot be bound to
its transcript shows the agent's last visible message.

A reply counts as new by the latest agent message in the session's bound
transcript (Codex, Claude). The screen sample is 24 rows, so the marker that
opens a longer reply is above it; judged from the screen alone, most Claude
replies raised no Done and a closing question no Question. Sessions without a
bound transcript still use the visible reply.

Kimi has no bound transcript, so its visible response stands in as reply
evidence: a turn that ends with the screen changed raises Done, without message
text. A provider error closing the response, such as
`Error: [provider.api_error] 429 …` on an exhausted quota, raises Blocked with
that line as the agent's text. Whether Kimi hides its marker between steps is
not verified, so its turn ends only when two samples in a row read Idle: its
alerts arrive about five seconds later than the others. Until 1.6.1 Kimi had no
Idle state at all and went from Working to Unknown, so it never raised Done.

Alert layout follows the board in `design/notifications/` and one scheme shared
with quota alerts: glyph, provider, then the specifics. The title is the type
glyph, the provider and the project folder: `✅ Claude · ai-fleet`. The glyph
alone is the type (✋ approval, 💬 question, ⛔ blocked, ✅ done); no type word is
spelled. The home folder is not shown as a project, because sessions start there
by default and it identifies nothing. The subtitle is the session name on its
own bold line: terminal session name, then tab title, without a Codex status
prefix such as `[ ! ] Action Required |` or a trailing project folder. It is
omitted when it says no more than the project. Each session keeps one banner: a
newer alert replaces the older one, and banners stack by project. Alerts that
need the user and Done use different system sounds (Funk and Glass).

The body is sized to what macOS shows, measured on macOS 26: title and subtitle
take one line of about 40 characters each, the body three lines (about 115
characters) while the banner is closed and ten lines (about 390) once it is
opened with its chevron. Ten lines is the ceiling: a longer or styled view needs
a notification content extension, which Fleet's build does not produce.

The body reads as a dialogue in paragraphs separated by a blank line, because a
run of unbroken text was hard to read. Done answers a request, so it shows a
little of the request on one line, marked `👤:` and cut at 32 characters, then
the reply marked `🤖:`, cut at 190. A question, a blocker and an approval are
the agent speaking alone: only the `🤖:` paragraph, up to 250 characters. Quota
alerts carry no dialogue. Blank lines count against the budget: a closed Done
banner shows the request and the first reply line, an open one shows it all.
Markdown marks are dropped and whitespace collapsed.

The place is the last paragraph, out of the header because a click already
opens the exact pane: `Personal AI — tab 8`. It names the window only when the
user named it; an unnamed iTerm2 window shows the title of whichever session is
active, which would point at the wrong session. The engine tells the two apart
by comparing the window title with its active tab and session. Then come the tab
number and the pane number for a split. The project path was tried there in
1.6.2 and removed: the project already stands in the title.

**Show message text in alerts** is on by default: without the text an alert says
only that something happened, and the switch went unnoticed while it was off.
Off, or without a bound transcript (a finished Kimi turn), the body is the place alone. macOS
stores notification text and can show it on the lock screen and during screen
sharing, which is why the switch remains. The engine reports that an approval is
pending, not which action; until it does, Approval shows the agent's last
message. The request comes from the bounded tail of the transcript, so a long
turn can leave it unavailable; the reply is then shown alone.

An alert lasts only while it is still true. Fleet withdraws it from the screen
and Notification Center once a later scan shows that the session was opened (its
pane was current while iTerm2 was frontmost), started new work, raised a
different request, or ended. A question or blocker therefore stays however often
it is viewed, until the agent moves on. Unknown and Untracked states prove
nothing and keep the alert. An alert is judged from the scan after the one that
fired it, so a reply landing in the pane being watched still sounds and then
leaves. Alerts delivered before a Fleet restart are not tracked and stay in
Notification Center until dismissed.

Clicking an alert selects that exact iTerm2 window, tab and pane by session ID.
If the session has ended or the pane cannot be verified, Fleet opens Agents with
the reason. Alerts have no buttons, and Fleet keeps no alert history of its own:
1.5 had both, but the list only repeated the banner inside the app, while
everything needed is meant to be read in the notification. Notification Center
is the list of alerts still open.

The engine's Rust tests protect identity replacement, ambiguity, noninteractive
exclusion, state precedence and provider binding. Swift tests exercise real pipe
framing, grouping, failed Jump, missing engine and light/dark layout. Release
smoke checks require the helper in both architecture archives. Installed
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
including native version-named Claude binaries, known package entrypoints and
rewritten Node provider titles such as kimi-code.
Detached processes can remain after terminals close; their exact role/account
remains unknown without evidence, so rows say only "terminal" or "detached". Native libproc discovery uses
executable paths, UID, controlling-terminal presence and microsecond start identity;
A failed executable lookup with ENOENT may use the kernel-recorded absolute
launch executable, so an update cannot hide a process still using an unlinked
old binary. Permission failures never use that fallback. Prompts and environment
are not exported or logged; only executable/initial runtime arguments are retained
for process recognition. UID and start identity are checked around collection. The visible list
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
