# Saved Codex authorization per account

## Outcome and boundaries

Users can keep multiple Codex accounts signed in and compare their remaining
subscription quota and account-reported token usage without changing credentials
used by running CLI/IDE/desktop sessions. The same saved homes support independent monitoring and explicit new-session
launches. Use for new sessions persists a launch default; New session opens a
project picker and a new terminal command with that home and `--no-daemon`.
Existing processes and standard CLI credentials are never switched.
The existing native login remains readable and protected by its running-process
preflight. Profiles do not route prompts or pool subscription allowances.

Each saved login has an accountID linking it to the existing FleetAccount and
its Greek badge. The label is internal legacy metadata, not another account.
Settings → Accounts chooses the account; Sign in on its Codex connection starts
the browser flow. Connect provider first selects an existing or new account and
rejects a duplicate provider association. The same `Codex (badge)` appears in the
menu, Settings and Statistics → Codex → Accounts. Internal auth homes and the
standard CLI login are never presented as additional user accounts.

A uniquely matching standard CLI login can provide read-only quota when no
independent login is attached. Its old numeric usage cache has no account identity
and is never assigned to a badge; account token totals require the saved login. No credentials are copied. Shared fallback rows disclose their dependence on the terminal login and offer
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
No credentials or config files are copied from the native home or other profiles.
Redirected profile directories, auth.json and config.toml paths are refused.
Invalid or repeated UUID metadata is ignored; no supplied path is trusted.

Each credential home has its own exclusive consumer lock. Account-usage reads
and auth changes within one home cannot overlap; other homes remain usable.
Browser login uses an additional cross-profile lock because native login shares
a localhost callback port. Global Codex processes do not block a different
account's saved login. Explicit account launchers register their wrapper PID in
that home's private FleetSessions directory, and native login/logout is refused
while a wrapper is alive. The wrapper removes its PID marker and one-shot script on exit; copied
commands retain a reusable launcher with a separate marker per invocation.
Stale PID files do not establish activity; live or ambiguous markers fail closed.
Copied launch commands use the same wrapper and retain the terminal's directory.
The native home's conservative process guard remains. Raw external consumers
that deliberately change these private homes are outside Fleet's control.

New-session launch validates that the saved file contains credentials and matches
the selected account email, clears inherited home/SQLite/API-key/access-token
selectors, forces file storage, and bypasses the shared background server with
`--no-daemon`. The launcher also pins the saved workspace ID through native
forced_chatgpt_workspace_id when present, so a queued command cannot silently
start under a different workspace after a credential change. iTerm2 receives a
new window when available, preserving Agents integration; Terminal is the fallback.
Each home has its own native session history, config and skills;
existing standard-home history is preserved in place, not automatically migrated.
Fleet does not copy standard config, credentials, plugins or conversation files.
Switching a default is metadata only; separate credentials come from the native
browser login, never from duplicating refresh tokens.

Cancel and app termination stop only the authentication child owned by Fleet.
Login and logout retain the native integration's 600-second browser and 30-second
logout deadlines. Native logout acts only on that profile's credential store;
other profiles, the standard ~/.codex home, and session history are preserved.
After any auth outcome, old measurements are discarded and native state is
reconciled; cancellation is not a rollback of a login that already completed.
Remove account forgets the corresponding metadata and saved-login association,
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
