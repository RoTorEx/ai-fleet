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
