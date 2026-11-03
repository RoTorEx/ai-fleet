# Shared accounts and global provider login

An AI Fleet account is a labelled identity with a stable α, β, γ badge and
zero or one association with each supported provider. One badge can represent
Claude, Codex, Kimi, Qwen, and Gemini. Labels are app metadata, not credentials.

## Account model and interface

A Greek badge identifies one real account, independent of provider or credential
storage. Provider rows use only `Provider (badge)` in the compact menu, Settings
and account statistics. One account may connect several different providers but
may contain at most one connection for each provider. Internal fallback metadata
is not a visible account and consumes no Greek badge. New real accounts start
at α; later additions receive the next unused badge. Existing real badges stay
stable except when the user explicitly requests reassignment.

Settings → Accounts owns one account picker and a Connect provider form. The
form chooses a provider and either Existing account or New account before login.
An already-connected provider cannot be added again to the selected account.
Cancel creates nothing. Existing account IDs, associations, and labels remain
stored when hidden; provider visibility controls do not log out or delete data.

Codex saved authorizations belong to these same account IDs. There is no separate
user-facing profile list, Native/CLI account row, or second account editor. Each
Codex row's Sign in starts a private browser login for that account while
preserving standard terminal credentials and other account logins. Expected email
must match the authenticated email before quota or tokens are attributed to a
badge. The standard CLI credentials may supply read-only measurements to the
uniquely matching account until its independent login is connected. Once a saved
login is attached, its state controls that account, including explicit sign-out.
[Codex authorization](codex-profiles.md) owns isolation and storage details.

All providers use the same Switch action and [next-launch contract](provider-switching.md).
The action changes only that provider's default command account. Running agents
continue under their existing credentials. New launches use native isolated homes;
Sign in remains a separate action and never silently changes the default. The
→ mark means default for the next launch, falling back to observed native identity
before integration. Independently measured accounts keep their own colors/limits.
Rows sort by tool name, then strictly by Greek badge.

Codex Save current login retains existing authorization without repeating browser
login. Its adapter and guarded internal recovery path are documented in
[Codex authorization](codex-profiles.md). Switching through the UI never invokes
the old shared-file replacement or requires stopping background processes.

The menu's Limits summary counts connections with current reported quota, not
signed-in accounts. A signed-in provider without a measurement is excluded;
stale and unknown measurements are excluded too. A current exhausted (0%) quota
is still reported data and counts. For two measured Codex accounts and an
authenticated Claude without quota, the summary reads `2/3 loaded`.
Account login progress, cancellation and errors appear beneath that provider's
own row, never as an unscoped banner beneath the application version. Each
message retains its account badge, including after a failed login completes.

Codex's shared cached credentials can change while an existing CLI, IDE or
app-server process still holds the previous identity. On subsequent refresh,
Codex may reject that process with the account-changed token error. Repeating
login does not retarget its already-running conversations. AI Fleet previously
allowed this transition without checking processes and deleted `auth.json`
directly on sign-out; those were app-side gaps, even though native Codex also
reports the same failure without AI Fleet. The user's October 28 incident
showed this error after account switching and a successful fresh request after
old processes exited. That supports the stale-process explanation, without
establishing the exact order of every overnight failure.

Changes to the shared CLI login remain protected internally by a conservative
current-user Codex process check. Account-specific browser logins do not change
that shared login and do not require terminating existing agents. Fleet never terminates a process as a side effect of account selection. Explicit process controls in Agents are separate and require confirmation. The active
account's standard home is the only refresh consumer for its credential bundle;
its saved copy is checkpointed rather than polled in parallel.
Login/logout and account-usage reads are exclusive within each credential home;
browser login additionally serializes the localhost callback across homes.
Login allows 600 seconds and logout 30 seconds. Cancel and app termination stop
only Fleet's owned authentication child. Failure never claims a completed login.
Account sign-out removes only that account's independent saved authorization;
removing account metadata preserves its credential directory and history.


Claude removes the native `Claude Code-credentials` Keychain item,
`~/.claude/.credentials.json`, and only `oauthAccount` in `~/.claude.json`.
Kimi, Qwen, and Gemini remove monitored file-backed credentials; Gemini also
clears its cached active Google account, and Kimi clears Fleet's fallback API
key. An inherited `KIMI_API_KEY` blocks sign-out until removed and the app
restarted. Redirected credential paths are rejected. External API keys and
stores outside these integrations remain outside local sign-out. No provider login action opens a terminal. Supported browser-capable CLI login runs directly; other integrations report that manual login is required.

Status checks read only one native default connection per provider, regardless
of the number of registered identities. A reported email matches a unique label
case-insensitively. A confirmed login with a new email registers a new badge
and provider association. Duplicate email labels are ambiguous: no badge is
marked current and no row is given that quota. The provider summary still shows
the native status. With no reported email, status belongs to the native-default
connection’s existing owner as a label fallback, without claiming verified
identity. Historical manual selections do not determine status or login.

Authentication and limit measurement remain independent internally. Menu markers
communicate measurement availability: ○ current limits loaded (including 0%),
× sign-in required, ? limits unavailable or unknown. Any connection without
current limits is gray, even if its CLI reports a configured login; a missing
measurement never looks ready. The hover legend behind the info button has three independent rows: Capacity names the remaining
allowance bands (Enough ≥26%, Low 11–25%, Critical ≤10%); Access names connector
availability (○ ready, × sign in, ? unavailable); Marks explains → default and
↓ lowest remaining. Default describes the account for the next ordinary provider command after terminal integration, not the identity of existing processes. Unavailable access is visually muted without a separate
"gray" label attached to an arrow. Both arrows use the same vector rotated 90°
in equal square frames, in the rows and in the legend. Legend marks match the
adjacent access symbols' visible size. SF Symbol arrows use 70% of the access
symbol font size to match their visible ink, retaining equal layout cells and
baseline alignment. The default mark alone indicates a successful selection;
no permanent selected-account or command-setup notice appears below a menu row.
One-time terminal setup guidance belongs in Settings → Accounts. Completed
successful actions leave no banner; non-Codex action feedback can be dismissed.
Email/plan hover and login actions retain actual authentication
state. Account-specific errors cannot borrow another account's limits or tokens.
Old shared session history is not split by badge.

The top Status reflects AI Fleet's monitoring lifecycle: Active while periodic
monitoring is enabled, Paused after monitoring stops. Checking/downloading/installing
an update, authentication of a named account, temporarily shows its operation state. Routine limit refresh keeps Active stable. A successful version check returns to Active/Paused
with a secondary confirmation rather than replacing the monitor state. Provider
measurement problems belong to their own rows and never become an unscoped app
error. Last checked appears in the options footer; Providers counts current measurements.
The updater remains an internal compatibility path; the menu has no Update command. Account authentication errors remain under their named provider.
Expired or missing access is described without the generic "sign in again"
suffix; the account's existing Sign in action remains available.

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
  `QWEN_HOME`, plus Gemini’s `GEMINI_CLI_HOME`; global login removes inherited values without writing shell
  startup files or bypassing native policies. Explicit Codex save retains credentials; selecting a default updates only the next-launch preference.
- Claude’s native Keychain service is `Claude Code-credentials`. Native auth
  status and OAuth quota checks retain the existing hashed account/credential
  cache keys, cooldowns, no-redirect requests, and token secrecy. Polling rules
  are owned by BUSINESS.md. A changed native identity cannot reuse another
  subscription’s quota cache.
- Codex reads native `~/.codex/auth.json`; JWT email/plan are display hints, not
  proof of authorization. Keychain-only/ephemeral storage remains outside this
  reader. Kimi retains native credential refresh and balance fallback. Qwen
  retains local OAuth detection and explicitly unsupported quota.
- `codex.activeAccountID` tracks the saved checkpoint of the standard credentials.
  `codex.nextLaunchAccountID` mirrors the account selected in CodexLaunch/default.json;
  it never claims that already running processes changed identity.
- `codex.sharedLimitSnapshots` retains only confirmed numeric windows, email and
  measurement time for a uniquely matched shared-login account. After a global
  account change, these remain explicitly historical: unknown authentication,
  stale quota, gray rows, no Lowest/count/alerts, and no account token attribution.
  They survive restart but are discarded when identity metadata changes or the
  account is forgotten. No credentials are copied or reconstructed.
- Alerts retain the existing global-provider scope, with connection and
  reported account/organization identity. Independently measured profiles may
  display quotas without becoming that global notification source.
- Statistics combines selected local datasets. Its separate Provider reports panel
  compares identity-bound monitoring profiles using provider-reported totals;
  old common local history is not attributed to them or mixed into those reports.

Gemini login and quota boundaries are owned by [Gemini](gemini.md).

## Verification

GlobalAccountsTests covers observed login overriding legacy manual selection,
case-insensitive matching, new-email discovery, ambiguous labels, restart and
association removal, no quota leakage, native login commands, and preservation
of legacy credential files. Scoped reader/command compatibility tests remain.
CodexAuthenticationTests protects process detection, fail-closed preflight,
non-launch/non-mutation on refusal, native command/environment selection,
statistics/auth exclusion, preserved status after refusal, pending/cancel,
failure/timeout/retry and saved history. Real corporate browser/SSO login requires the user’s authentication and is not
established by fixtures; development checks do not change live provider login.

## Interface ownership

[Interface](interface.md) owns menu/options placement and Settings destinations.
Authentication actions are exclusive: signed-in rows show Sign out; other rows
show Sign in. Switch follows that action. Authentication and selection remain
separate. Provider action icons are deliberately different in the local redesign
for user comparison; do not infer authentication from the selected icon.
