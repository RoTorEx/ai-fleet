# Security

## Credential boundary

AI Fleet reads existing provider credentials from the current user's home
directory. Kimi and Codex credentials are used only for HTTPS requests to the
corresponding provider endpoints documented in the architecture. Claude
credentials also provide subscription quota status; Qwen credentials are used
for local auth detection. Explicit Sign out
uses native `codex logout` for Codex after a current-user process preflight;
other providers remove monitored credentials locally without launching their CLI; see [Accounts](business/accounts.md) for exact stores and
limitations. Ordinary status polling does not remove credentials. Tokens are
not logged or shown in the UI.

AI Fleet also reads local Codex session JSONL files under `~/.codex/sessions`
and `~/.codex/archived_sessions`, and Claude Code transcripts under
`~/.claude/projects` (including nested subagent logs)
to extract numeric token-usage metadata for the Statistics window. Statistics does
not display prompt, response, diff, or file content from those logs.

The optional Kimi API key fallback lives at
`~/Library/Application Support/AI Fleet/config.json`. The Statistics window also
caches the latest numeric usage snapshot at
`~/Library/Application Support/AI Fleet/usage-analytics-cache.json`. AI Fleet
restricts that directory to mode `0700` and those files to mode `0600` when it
reads or writes them. Never copy real credentials, auth files, local usage
caches, or environment files into this repository.

## Independent Codex profiles

Monitoring credentials are created directly by native Codex in separate
`~/Library/Application Support/AI Fleet/CodexProfiles/<UUID>` homes. Nothing is
copied from `~/.codex`. Login, logout and account usage always select that exact
home and file credential storage. Directories use 0700 and successful auth files
0600. Redirected auth/config paths are refused. UserDefaults contains only
account IDs, profile IDs, labels and a launch selection. Confirmed shared-login
numeric windows may persist with their measurement time and email as explicitly
stale history; credentials and tokens never enter that cache. Explicit terminal
launch uses an account home and `--no-daemon`; its PID marker blocks Fleet login
changes for that account until the wrapper exits. See
[business/codex-profiles.md](business/codex-profiles.md) for isolation and retention.

## Local session overview

Agents additionally reads bounded visible iTerm2 screens and process-bound local
provider metadata through the embedded AI Session Hub core. Request/answer text
stays in memory; it is not persisted, uploaded or logged. Jump only selects a
freshly validated existing pane. It never types into terminals. See
[business/agents.md](business/agents.md) for data and lifecycle boundaries.

## Public-source check

Run `make public-audit` before pushing. The audit rejects tracked credential
filenames and searches the working tree and reachable Git history for common
private-key and access-token formats. It reports locations only, never matched
secret values.

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub's private vulnerability
reporting feature in the repository's Security tab. Do not open a public issue
containing credentials, exploit details, or other sensitive data.
