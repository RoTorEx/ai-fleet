# Shared accounts and provider subscriptions

An AI Fleet account is a user-defined identity, not an OAuth client. It has a
stable badge (α, β, γ…), a name, an optional email label, and zero or one
connection to each supported provider. The same badge can connect Claude,
Codex, Kimi, and Qwen. Different organizations under the same email can use
different badges. Grouping is explicit; the app never assumes matching emails
mean matching subscriptions.

## Interface and selection

The menu contains one row per installed, enabled provider. A circular badge for
its selected account is aligned at the right edge of the provider header, which
has no colon. Clicking it opens an account chooser with a checkmark on the
current account, plus Open, Sign in, and Add account actions. Choosing an account
changes that provider's displayed quota and future sessions launched through
AI Fleet. Hover contains only the provider-reported email and plan; missing
plans are omitted and the user-supplied email is a fallback. No quota, account
name, organization, or status text belongs in this tooltip.

Selection is manual and independent per provider. AI Fleet does not implement
automatic quota draining, fallback profiles, or traffic routing; the interface
must not advertise those behaviors. The downward arrow identifies the provider
with the lowest current remaining quota, not a routing target.

Settings uses its existing window, with General and Accounts tabs. Add account
from the provider chooser opens an inline form on Accounts with that provider
preselected. The + button opens the same form. Enter an email, optionally a name,
and choose a provider; Add & sign in creates an isolated connection and opens
native login. Cancel creates no identity or connection. Other providers can
later be attached to the same badge. The Accounts tab edits labels and provider
connections. Moving existing connections and importing configuration folders
are under Advanced for unlinked providers. Moving a connection preserves its
credential path, quota notification identity, and selection. An account can own
only one connection to a given provider; an already-linked connection cannot
be silently overwritten. No additional account-management window exists.

Sign in launches the provider's native CLI in Terminal. Claude uses `auth login`,
Codex and Kimi use `login`, and Qwen enters its interactive CLI login. Open asks
for a project directory; cancelling leaves selection unchanged. The app never
changes the login of an existing session or ordinary shell command. Selection
is independent for each provider and persists through restart.

## Storage and isolation

- `fleet.accounts`, `fleet.selections`, and `fleet.nextBadge` in UserDefaults
  hold only identity labels, stable IDs/badge indices, paths, and selections.
  Removed badges are not reassigned to future identities. The default identity
  initially groups existing default CLI connections and cannot be removed.
  Users can move those connections to badges that match their email labels.
- Newly attached providers use independent directories under
  `~/Library/Application Support/AI Fleet/Accounts/<account UUID>/<provider>/`.
  The app prepares the directory on launch; the native CLI performs login and
  owns credentials, settings, policy enforcement, and history. A custom path
  never falls back to another account's credential or global API balance.
- The producer and quota reader use the same selector:

  | Provider | Selector | Quota credential |
  | --- | --- | --- |
  | Claude | `CLAUDE_CONFIG_DIR` | `.credentials.json` or scoped Claude Keychain item |
  | Codex | `CODEX_HOME` | `auth.json` (file-backed OAuth storage) |
  | Kimi | `KIMI_CODE_HOME` | `credentials/kimi-code.json` |
  | Qwen | `QWEN_HOME` | `oauth_creds.json` / `credentials.json`; quota unsupported |

- Claude's default service is `Claude Code-credentials`. A custom profile uses
  `Claude Code-credentials-<first eight hex digits of SHA256(NFC(exact path))>`.
  The CLI-reported config directory must match the requested profile before
  reading credentials. Tokens stay in memory and are never logged or rewritten
  by AI Fleet. Usage requests do not follow redirects.
- Claude quota checks use a shared per-profile/account/credential request gate.
  Successful responses are reused for five minutes. HTTP 429 retains confirmed
  login and any last measurement, marks it as last known, and waits with
  exponential backoff plus `Retry-After`. Only hashed keys and retry deadlines
  persist; tokens and quota measurements do not. Changing login/organization
  cannot reuse another subscription's cache. Normal login checks continue when
  views open. Polling numbers and rationale are owned by BUSINESS.md.
- Codex email and plan are local JWT display hints, not verified authorization.
  Native Keychain-only/ephemeral Codex storage is outside the current file reader.
  Kimi preserves its established refresh behavior, writing renewed credentials
  only to the connection that produced the refresh token, with scoped device
  headers. Only the default Kimi connection may use the global API balance.
- Launches remove inherited account/API overrides for the chosen provider.
  They do not change shell startup files or bypass native managed policies.
- Notifications are evaluated for all connections, with connection IDs and
  reported account/organization hashes in their scopes. Alerts name the badge
  instead of exposing email. Rename/move preserves scope; re-login to another
  organization uses a different scope.
- Removal forgets app metadata, keeps provider credentials and session files,
  and restores a valid selection. Default CLI connections are preserved even
  when the user removes an identity to which they were moved.
- Legacy `claude.profiles` metadata migrates to shared identities, preserving
  IDs, exact configuration selectors, names, and selected login. The original
  metadata remains available for recovery. Native credentials are never copied.
- Statistics retains the existing default Codex analytics scope and selected
  Kimi quota view. Multi-account historical analytics is a separate queued task.

## Sources and verification

Native isolation is documented by
[Claude](https://code.claude.com/docs/en/authentication#log-in-with-multiple-accounts),
[Codex authentication](https://learn.chatgpt.com/docs/auth),
[Kimi data locations](https://www.kimi.com/code/docs/en/kimi-code-cli/configuration/data-locations.html),
and [Qwen configuration](https://qwenlm.github.io/qwen-code-docs/en/users/configuration/settings/).
Claude scoped service naming is tracked in the
[quota-axi implementation](https://github.com/kunchenguid/quota-axi).

Tests cover shared badges, independent provider selection, restart, migration,
connection moves, removal without credential deletion, literal shell quoting,
and distinct Claude account metadata/quota requests, including same-email
different-organization logins. Browser/SSO flows for two real corporate accounts
require the user to complete those companies' authentication and are not
established by fixture tests.
