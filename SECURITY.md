# Security

## Credential boundary

AI Fleet reads existing provider credentials from the current user's home
directory. Kimi and Codex credentials are used only for HTTPS requests to the
corresponding provider endpoints documented in the architecture. Claude and Qwen
credential files are currently used only to detect whether the local CLI appears
signed in. Tokens are not logged or shown in the UI.

The optional Kimi API key fallback lives at
`~/Library/Application Support/AI Fleet/config.json`. AI Fleet restricts that
directory to mode `0700` and the file to mode `0600` when it reads or writes the
configuration. Never copy real credentials, auth files, or environment files
into this repository.

## Public-source check

Run `make public-audit` before pushing. The audit rejects tracked credential
filenames and searches the working tree and reachable Git history for common
private-key and access-token formats. It reports locations only, never matched
secret values.

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub's private vulnerability
reporting feature in the repository's Security tab. Do not open a public issue
containing credentials, exploit details, or other sensitive data.
