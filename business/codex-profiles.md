# Saved Codex authorization per account

## Outcome and boundaries

Users can keep multiple Codex accounts signed in and select which account the next
ordinary `codex` command uses. Its UI action is Switch, following the
[provider-independent contract](provider-switching.md). Selecting an account never replaces standard credentials or retargets an existing
conversation. Process stopping follows the explicit [Switch recovery](switch-recovery.md) policy. A terminal
already open needs one initial `rehash` after command integration is installed;
subsequent selections apply on the next command without reopening the terminal.
Fleet never creates terminals or starts conversations. Native shared-credential
replacement remains an internal recovery path guarded by running-process checks.

The command integration is a Fleet-owned `~/.local/bin/codex` shim invoking the
installed app's terminal entry point. It reads the atomically written
`~/Library/Application Support/AI Fleet/CodexLaunch/default.json` on every launch.
That file contains account/profile/workspace IDs, email and whether the existing
standard home owns this account; it contains no credential. A conflicting executable
or redirected installation path is refused rather than replaced. Native executable
discovery skips the Fleet shim and tracks package-manager updates. The app's own
quota/login readers always use native Codex rather than the shim.

New interactive launches use `--no-daemon`, file credential storage and the selected
workspace ID, so an existing background server cannot impose its account. `resume`
and `fork` use the same selection; history remains shared. Explicit CODEX_HOME,
CODEX_SQLITE_HOME, access-token and remote-server invocations retain their native
scope. Server control, agents/queue, installation, help and version commands retain
native behavior. `codex agents` describes the native shared server, not all isolated
processes; Fleet's Agents view remains the local session overview.

For the account already owning the standard login, new commands retain that home:
Fleet never creates a second refresh consumer from its saved checkpoint. Other
accounts use their own saved credential homes. Only credentials remain isolated;
config, global instructions, rules, skills, plugin assets, packages, session rollouts,
history, session index, shared memory files and session locks reference the existing
standard home. SQLite state uses the standard home through both environment and
an explicit sqlite_home override. Existing profile assets replaced by these links
are preserved under `.fleet-before-shared/`; unrelated files and auth.json are
untouched. Link preparation is repeatable and rolls back its own partial changes.
Only the exact standard config link is accepted by the profile path validator;
redirected credential files/directories remain refused. Standard config changes
therefore apply to subsequent launches without copying stale configuration.

A session marker follows the terminal entry point's PID through exec. Login/logout
refuses while that account has registered live sessions; selecting another account
remains allowed. Stale markers are removed on later launches. Provider quota
selection does not migrate running requests or establish cross-account resumability;
that full live transition remains a separate user check. Account-wide tokens never
borrow the shared local history's model/cost accounting.

Each saved login has an accountID linking it to the existing FleetAccount and
its Greek badge. The label is internal legacy metadata, not another account.
In Settings → Accounts, Sign In on an account's Codex row starts the browser
flow. Connect Provider never adds a duplicate provider association. The same `Codex (badge)` appears in the
menu, Settings and Statistics → Codex → Accounts. Internal auth homes and the
standard CLI login are never presented as additional user accounts.

A uniquely matching standard CLI login can provide read-only quota when no
independent login is attached. Its old numeric usage cache has no account identity
and is never assigned to a badge; account token totals require the saved login. Credentials are copied only by explicit save, guarded internal replacement and active-account checkpointing. Shared fallback rows disclose their dependence on the terminal login and offer
Connect separate login. Confirmed shared numeric measurements may be retained
as explicitly stale history after the shared login changes; they never count as
fresh quota or preserve the expired login. After an independent login is
attached, that saved login owns the account's status.
Authenticated email must match the account's expected email before quota or
tokens are shown. A wrong browser account shows a mismatch, without its quota.

Existing unbound 1.3.2 login metadata is adopted by unique account name/email;
unmatched saved logins receive a real account record. UUID credential paths and
existing real badges remain unchanged. No credentials are moved or deleted.
Only independently connected account logins can remain available after an
external tool replaces the standard CLI credentials; past signed-out credentials
cannot be reconstructed from labels or numeric quota snapshots.

## Credential isolation and lifecycle

`codex.monitoringProfiles` in UserDefaults stores UUIDs, legacy labels and account IDs. Credentials
are created by native Codex under
`~/Library/Application Support/AI Fleet/CodexProfiles/<UUID>/auth.json`.
The profile root and directories use mode 0700; successful auth files are
restricted to mode 0600. Native login/logout and app-server reads set CODEX_HOME
to exactly that profile and explicitly select file credential storage. Inherited
CODEX_HOME, CODEX_SQLITE_HOME, API-key and access-token overrides are removed.
Shared config/history references are prepared only for terminal integration, with originals retained. Credential checkpointing remains explicit as described below.
Redirected profile directories, auth.json and config.toml paths are refused.
Invalid or repeated UUID metadata is ignored; no supplied path is trusted.

Each credential home has its own exclusive consumer lock. Account-usage reads
and auth changes within one home cannot overlap; other homes remain usable.
Browser login uses an additional cross-profile lock because native login shares
a localhost callback port. The internal recovery action replacing the standard login is guarded by the global
credential lock and two current-user Codex process checks. A running CLI or daemon
blocks the write; Fleet does not stop processes or claim that file replacement
retargets them. Native login/logout for an active account uses the same preflight.

Save current login copies the current verified-format credential bundle into the
matching saved account without signing out or opening a browser. The recovery-only shared-login replacement saves
the outgoing bundle first, then atomically replaces only standard auth.json with
the selected account's bundle using mode 0600. Normal account selection never uses
this path. Redirected paths, wrong identities,
unknown outgoing owners, explicit non-file credential stores and concurrent
external file changes fail closed. Standard config/history/state are untouched.
While active, only the standard home is measured/refreshed. Its saved copy is a
checkpoint, not a parallel refresh consumer. Inactive accounts use their own homes.
On an external identity change the active association is cleared, preserving saved
data. Provider-side revocation or unsaved external token rotation can still require
reconnection; a file copy cannot guarantee perpetual authorization.

Cancel and app termination stop only the authentication child owned by Fleet.
Login and logout retain the native integration's 600-second browser and 30-second
logout deadlines. Native logout acts only on that profile's credential store;
other profiles, the standard ~/.codex home, and session history are preserved.
After any auth outcome, old measurements are discarded and native state is
reconciled; cancellation is not a rollback of a login that already completed.
Remove Account forgets the corresponding metadata and saved-login association,
leaving credential directories and history intact. Sign out first to clear login.

## Measurement and accounting

The app checks refresh eligibility every 60 seconds and on panel entry. Profile
refreshes are spaced 300 seconds apart by default; an explicit Refresh bypasses
that interval. These app-defined values limit background network and subprocess
work while retaining timely visibility. Simultaneous refreshes join the current
scan; login/logout is disabled until it finishes. Profiles are measured serially.
Unconnected profiles never launch app-server. Startup reloads metadata and
refreshes actual credentials, rather than presenting old measurements as fresh.

The profile's native account/usage/read request supplies all-time tokens and
provider-reported daily buckets. It can renew its own native auth as needed.
The existing quota reader then reads that same home's credentials and fetches
main 5h/7d quota windows. Token and quota availability are independent. Identity
is checked before and after measurement; changing or unavailable identity
suppresses the token result rather than attaching another account's total.
401 or missing credentials requires sign-in; transport errors do not invent quota.

All-time tokens use the account lifetime value. Period totals sum only the
provider-reported dates in the selected range and explicitly identify that source;
their day boundaries are not claimed to match locally timestamped sessions.
Missing daily coverage yields an unavailable period total, not a false zero.
No local model/input/output mix, shared historical sessions, or dollar estimate
is assigned to monitoring profiles. Profiles signed into the same actual account
share that account's quota; separate logins do not create extra allowance.
Account measurements participate in menu Lowest using the account badge.
Threshold alerts retain the existing standard-login scope.

## Evidence and verification

The native CODEX_HOME and file credential-store contracts are documented in
[OpenAI authentication](https://learn.chatgpt.com/docs/auth) and
[environment variables](https://learn.chatgpt.com/docs/config-file/environment-variables).
CodexMonitoringTests exercises two independent homes through native-process
fixtures, scoped account-usage requests, native-home preservation, profile logout,
metadata restart, missing credentials, credential/directory redirection,
cancellation, accounting boundaries and Settings/Statistics light/dark layout.
CodexAuthenticationTests continues protecting global-login process refusal.
Real browser/SSO completion requires the user and is not established by fixtures.
