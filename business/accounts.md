# Shared accounts and global provider login

An AI Fleet account is a labelled identity with a stable α, β, γ badge and
zero or one association with each supported provider. One badge can represent
Claude, Codex, Kimi, and Qwen. Labels are app metadata, not credentials.

## Login and interface

Each provider has one current standard global CLI login. The row’s **…** menu
contains only **Sign in…**, which launches the provider’s native login in
Terminal: Claude `auth login`, Codex/Kimi `login`, and Qwen’s interactive CLI.
It unsets inherited provider directory and API/account overrides and uses the
native default location. No project chooser, isolated session launch, manual
Use action, or credential swapping is exposed. The account is chosen in the
provider’s browser/SSO flow; the badge does not force that flow’s email.
Completing login changes the standard provider credentials used by ordinary
CLI commands. Already-running processes may retain cached credentials until
they refresh or authenticate again; AI Fleet does not control their lifetime.
Selective per-session login is deferred until requested.

Status checks read only one native default connection per provider, regardless
of the number of registered identities. A reported email matches a unique label
case-insensitively. A confirmed login with a new email registers a new badge
and provider association. Duplicate email labels are ambiguous: no badge is
marked current and no row is given that quota. The provider summary still shows
the native status. With no reported email, status belongs to the native-default
connection’s existing owner as a label fallback, without claiming verified
identity. Historical manual selections do not determine status or login.

The menu shows one row per association for installed/enabled providers, with a
small parenthesized badge after the name, such as Codex (α). Status markers stay
in tightly spaced aligned columns on the left; only … occupies the right.
**→** marks the detected global login only when authentication is confirmed.
Other accounts are gray and read `Not signed in globally`, with no borrowed
quota, plan, or provider identity. Badge hover immediately shows an inline
overlay containing only email and plan; missing plans are omitted and the label
email is a fallback. There is no new account-management window.

Authentication and quota remain independent: ○ signed in, × requires sign-in
or explicit access denial, ? unknown check. Exhaustion is red 0%, not missing
login. Quota errors retain independently confirmed auth except explicit HTTP
401 credential rejection. Stale/unknown quota cannot drive alerts or Lowest.
The **↓** marker means lowest positive current global quota. The existing
legend retains Color, Auth, Selection, and Quota; Selection describes global
login and gray other accounts. No automatic fallback or request routing exists.

Settings → Accounts edits labels and provider associations; its picker only
chooses the record to edit. **+** opens the inline email/provider form;
**Add & sign in…** registers metadata and starts global native login. Cancel
creates nothing. Provider toggles add associations without creating credential
folders. **Sign in…** has the same global meaning on every badge. Folder import
and selective launch controls are deferred. General owns only shortcut,
notifications, and analytics; Menu visibility in Accounts applies globally.

## Storage and preservation

- `fleet.accounts` and `fleet.nextBadge` store labels, stable IDs, and provider
  associations. A `globalAssociation` connection is metadata with a unique row
  ID and no custom configuration directory. Removed badges are not reused.
- Exactly one native-default connection per provider is retained. Removing an
  account preserves any native-default connection on another identity. Legacy
  `fleet.selections` is retained for recovery, but is not the active-login source.
- Existing isolated paths, credential files, session history, and legacy Claude
  profile metadata remain intact. They are not polled or launched by this UI.
  Removing metadata does not delete credentials. Internal scoped readers and
  command generation remain covered by compatibility tests for recovery.
- Native selectors are `CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `KIMI_CODE_HOME`, and
  `QWEN_HOME`; global login removes inherited values without writing shell
  startup files or bypassing native policies. AI Fleet never copies or swaps
  tokens between accounts.
- Claude’s native Keychain service is `Claude Code-credentials`. Native auth
  status and OAuth quota checks retain the existing hashed account/credential
  cache keys, cooldowns, no-redirect requests, and token secrecy. Polling rules
  are owned by BUSINESS.md. A changed native identity cannot reuse another
  subscription’s quota cache.
- Codex reads native `~/.codex/auth.json`; JWT email/plan are display hints, not
  proof of authorization. Keychain-only/ephemeral storage remains outside this
  reader. Kimi retains native credential refresh and balance fallback. Qwen
  retains local OAuth detection and explicitly unsupported quota.
- Alerts are evaluated only for the current global row, with connection and
  reported account/organization scope. Inactive associations have no quota.
- Statistics keeps the standard global Codex scope. Multi-account historical
  analytics remains a separate queued task.

## Verification

GlobalAccountsTests covers observed login overriding legacy manual selection,
case-insensitive matching, new-email discovery, ambiguous labels, restart and
association removal, no quota leakage, native login commands, and preservation
of legacy credential files. Scoped reader/command compatibility tests remain.
Real corporate browser/SSO login requires the user’s authentication and is not
established by fixtures; development checks do not change live provider login.
