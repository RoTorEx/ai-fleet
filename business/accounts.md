# Shared accounts and global provider login

An AI Fleet account is a labelled identity with a stable Greek badge (the first ten are α, β, γ, δ, ε, ζ, η, θ, ι, κ) and
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
The action changes only that provider's default command account. In next-launch-only mode running agents continue under their existing credentials.
Codex and Claude stopping modes follow [Switch recovery](switch-recovery.md). New launches use native isolated homes;
Sign in remains a separate action and never silently changes the default. The
→ mark means default for the next launch, falling back to observed native identity
before integration. Independently measured accounts keep their own colors/limits.
Rows sort by tool name, then strictly by Greek badge.

Codex Save current login retains existing authorization without repeating browser
login. Its adapter and guarded internal recovery path are documented in
[Codex authorization](codex-profiles.md). Switching through the UI never invokes the old shared-file replacement; its
process policy determines whether it waits for or stops bound consumers.

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
that shared login and do not require terminating existing agents. Stopping Switch policies and manual process controls require explicit confirmation. The active
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

Authentication and limit measurement remain independent internally. Each menu
row has exactly one leading mark, all in one monospaced font and sharing the ×
optical center (arrows may run longer than × and •):
- ↓ the lowest positive current quota among all accounts, whichever it is;
- → the current account of a provider with several saved accounts, meaning the
  account the next ordinary provider command uses after terminal integration,
  not the identity of existing processes;
- • any other connection with current limits (including 0%);
- × sign-in required; ? limits unavailable or unknown.
Unavailable marks win over → and •. Any connection without current limits is
gray, even if its CLI reports a configured login; a missing measurement never
looks ready. Quota rows sit in shared columns (period, right-aligned remaining,
reset) indented slightly inside the provider name. An unavailable row keeps its
short reason visible and reserves the height of the provider's usual quota lines
(its measured accounts' count, else 5h/7d for Codex and Claude, else one) so rows
stay balanced. "Login status unknown" means the login check gave no answer;
"Sign in required" means the CLI confirmed no login; providers are separated by
spacing, not lines. Row-level notes are not shown under rows: important notes
(quota notices, sign-in/switch failures, terminal rehash) appear briefly in the
Status section of the ⓘ card, and a dot on ⓘ (orange for problems) shows they
exist. Sign-in progress with Cancel stays in the header detail line.
Email/plan hover and login actions retain actual authentication
state. Account-specific errors cannot borrow another account's limits or tokens.
Old shared session history is not split by badge.

The header status reflects AI Fleet's monitoring lifecycle: Active while periodic
monitoring is enabled, Paused after monitoring stops. Authentication of a named
account appears as a detail line below it; refreshing limits spins the Refresh
icon. Provider measurement problems belong to their own rows and never become an
unscoped app error. The `measured/saved` count counts current measurements; the
footer names the last provider check. Account authentication errors remain under
their named provider.
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
- The Codex Usage dashboard keeps the standard global scope. Its Accounts view
  compares independent monitoring profiles using only provider-reported totals;
  old common local history is not attributed to them.

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

## Verified connections and isolated reauthentication

For Codex and Claude, automatic native-login import requires signed-in status and
an observed nonempty email. Email matching trims whitespace and ignores case.
Unknown identity, duplicate labels and conflicting known organization/workspace
identity do not bind or receive another account's measurements. Explicitly detached
or removed provider/email pairs persist in accounts.dismissedImports; Refresh and
restart do not recreate them. Import login explicitly removes that suppression.
Other providers retain their existing matching behavior.

Connection metadata optionally records verifiedIdentity. Old records retain their
IDs, badges and paths and acquire identity only after observation. A connected
account's email cannot be edited into another identity; disconnect first. Names
remain editable. First verified login may fill an empty email.

Account-targeted Codex and Claude Sign in uses a separate candidate credential
home. Pending home UUIDs persist across failed retries. A verified matching result
changes the connection's profile pointer without moving its files. Claude Keychain
selectors therefore retain the exact native login path. Failure, cancellation,
wrong identity or lost association cannot replace the previous connection.
Credentials and history in the previous home are retained. Sign in does not change
the existing command selection; Switch explicitly selects the refreshed connection.

ProviderLaunchProfile.credentialHomeID and CodexMonitoringProfile.credentialHomeID
are optional UUIDs; absent values retain legacy account/profile directories. Codex
launch selection uses the credential-home UUID, while ownership markers retain the
real account UUID. New paths remain inside existing protected provider roots.

Disconnect provider forgets that association and its command selection. Remove
account does so for its connections; neither performs logout or terminates sessions.
Sign out remains a separate native operation. Authentication and removal respect
the existing Switch/busy guards. Real-account acceptance is deferred until after
design and does not block subsequent technical stages.

Menu visibility and measurement counts follow the [monitoring contract](../docs/contracts/menu-monitoring.md).
