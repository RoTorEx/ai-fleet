# Bundled Session Hub adapter

This private executable embeds unchanged AI Session Hub sources pinned in
upstream.json. It is built for each release architecture inside AI Fleet.
The standalone CLI is not required.

src/main.rs owns the Fleet JSON-lines adapter. vendor belongs to upstream:
compare a reviewed Hub revision, copy the required modules/license unchanged,
then update the revision and hashes together. Never patch discovery or Jump in
this copy. make check verifies source hashes and runs inherited behavior tests.

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

Optional requestedAt and lastMessageAt are epoch-second timestamps exported only
from process-bound provider metadata. updatedAt may represent an observed terminal
change, so consumers must not present it as a provider message time. Missing
metadata stays null and does not become a process-start or polling timestamp.

workingStartedAt comes from an explicit live terminal status duration, observed
through the same PID/start validation before and after the read. The adapter owns
this timing extension; pinned vendor modules remain unchanged. It is absent when
no recognized live timer is available, never inferred from process age.

codex_metadata.rs handles current larger session headers and explicitly marked
helper transcripts. It uses writable process-bound file descriptors, canonical
root checks, unique primary selection and bounded reads, with before/after process
identity validation supplied by the adapter. Current response-item messages are
normalized alongside legacy event messages in chronological order, preserving
actual message timestamps. It does not patch vendored code.
