# Agent session data contract

Fleet owns this additive protocol-1 extension and the Swift AgentSessionContract.
It prepares data for a future UI; it specifies no layout, labels, colors, icons,
animations or grouping controls. Existing wire fields and consumers remain valid.
Row dataVersion is 1. New fields are optional on decode so older engines remain
readable. Unknown raw states map to unknown rather than implying completion.

## Identity and evidence

Session id identifies PID plus process start, not a conversation or account.
`pid` is the local PID; `processStarted` is the pinned reader's integer microseconds
since Unix epoch and must not be rounded for identity comparison. `project` is the
project grouping path; optional `cwd` is the observed working directory. Neither
path nor title establishes account, parent/child agent relationships or transcript
ownership. `originalTitle` retains the safe original terminal title. No display
cleanup is applied to the source and no account is borrowed from global login.

Exact pane linkage and process identity are checked before metadata collection
and process identity is checked again after it. Codex metadata requires a unique
writable primary JSONL transcript beneath the canonical session root; helper logs
cannot replace it. Large session headers are bounded at 1 MiB, matching the tail
read bound, so pathological files become unknown rather than unbounded work.
Unsupported, ambiguous or missing data stays absent; newest file, mtime and cwd
are never transcript selection rules. Claude retains the pinned process-binding
and sidechain exclusion contract. Pinned vendor sources are unchanged.

## States

The typed states are working, idle, ready, question, approval, error, unknown,
stale and unlinked. The actual engine labels New reply, Opened, Untracked and
Blocked normalize to ready, idle, idle and error. Ready means an observed new
completed response not yet opened. Opening is not proof of reading. Terminal
activity and blockers are heuristic evidence; stateSource explicitly says so.

Stale scan/connection state takes precedence over an old activity state; an
unlinked pane cannot expose live work timing. The current service supplies this
freshness context through `contracts`, alongside the legacy raw sessions. Stopping
observation disables live work timing without deleting the retained snapshot.

## Independent clocks

All optional wall-clock fields use Unix epoch seconds, except processStarted.
`observedAt` is successful snapshot collection time; `activityObservedAt` is the
last actual activity sample, which can be older during cached inventory polls.
Neither is a message timestamp. Legacy updatedAt remains a change observation.

`lastMessageAt` comes only from bound provider message records (user or assistant).
`requestedAt` is the provider's latest recorded user request. Neither is inferred
from process age or file mtime. Loss of binding clears previous provider times.

`workStartedAt` and `workTimeSource` form one timing observation. Precedence is
validated terminal elapsed time, bound provider request time, then continuous
observed working time. The last is a lower-bound observation, not actual turn age.
Polling and intermediate messages do not reset it. Leaving Working, scan failure
or engine restart resets that observation. Future/invalid timestamps are rejected
by the typed Swift contract. Duration is unavailable while stale, idle or unlinked.

## Verification boundary

Rust tests cover current Codex response items, large headers, helper ambiguity,
explicit terminal durations, binding loss and stable observed timing. Swift tests
cover real engine labels, typed identity, independent timestamps, invalid dates
and stale/unlinked timing. Existing pipe, request-generation, Jump and layout
regressions run through make check. Actual terminal/provider-version acceptance
remains part of the combined user review after design, not proof from fixtures.
