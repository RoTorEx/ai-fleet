# Security

## Credential boundary

AI Fleet reads existing provider credentials from the current user's home
directory. Kimi and Codex credentials are used only for HTTPS requests to the
corresponding provider endpoints documented in the architecture. Claude
credentials also provide subscription quota status; Qwen credentials are used
for local auth detection. Explicit Sign out
removes the monitored native credentials and cached identity without launching
provider commands; see [Accounts](business/accounts.md) for exact stores and
limitations. Ordinary status polling does not remove credentials. Tokens are
not logged or shown in the UI.

AI Fleet also reads local Codex session JSONL files under `~/.codex/sessions`
and `~/.codex/archived_sessions`, and Claude Code transcripts under
`~/.claude/projects` (including nested subagent logs)
to extract numeric token-usage metadata for the Statistics window. The app does
not display prompt, response, diff, or file content from those logs.

The optional Kimi API key fallback lives at
`~/Library/Application Support/AI Fleet/config.json`. The Statistics window also
caches the latest numeric usage snapshot at
`~/Library/Application Support/AI Fleet/usage-analytics-cache.json`. AI Fleet
restricts that directory to mode `0700` and those files to mode `0600` when it
reads or writes them. Never copy real credentials, auth files, local usage
caches, or environment files into this repository.

## Public-source check

Run `make public-audit` before pushing. The audit rejects tracked credential
filenames and searches the working tree and reachable Git history for common
private-key and access-token formats. It reports locations only, never matched
secret values.

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub's private vulnerability
reporting feature in the repository's Security tab. Do not open a public issue
containing credentials, exploit details, or other sensitive data.
