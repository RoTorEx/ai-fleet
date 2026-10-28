# Independent Codex monitoring accounts

## Outcome and boundaries

Users can keep multiple Codex accounts signed in and compare their remaining
subscription quota and account-reported token usage without changing credentials
used by running CLI/IDE/desktop sessions. These profiles are for monitoring;
launching sessions under a selected profile is a separate, deferred capability.
The existing native login remains readable and protected by its running-process
preflight. Profiles do not route prompts or pool subscription allowances.

Settings → Accounts → Codex accounts creates a labelled profile with Add & sign
in. The existing + form also creates an independent profile when Codex is chosen.
Each profile completes its own native browser login and displays the email and
plan actually reported by that login, independently of its label. A label never
forces an email or establishes authentication. The native global login controls
are explicitly named Change native login. Old generic account labels and
associations remain stored; inactive Codex associations are not repeated as
misleading unsigned-in global rows in the compact menu.

The Usage menu shows Native Codex plus monitoring rows with current quota for
each profile. Manage opens the Accounts settings tab. Statistics → Codex →
Accounts compares the native account and all profiles, with the existing 7d,
30d, 90d and All controls. Settings owns profile login, logout, cancellation
and forgetting metadata. Empty, checking, expired, failed and missing-data states
remain visible. Existing provider enable/disable controls apply to menu visibility.

## Credential isolation and lifecycle

`codex.monitoringProfiles` in UserDefaults stores only UUIDs and labels. Credentials
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
a localhost callback port. Profiles are monitor-only and their directories are
not exposed as session-launch targets, so global Codex processes do not block
their authentication. The native home's conservative process guard remains.
Manually launching external consumers against these private profile homes is
outside the supported workflow; external auth changes are not controlled by Fleet.

Cancel and app termination stop only the authentication child owned by Fleet.
Login and logout retain the native integration's 600-second browser and 30-second
logout deadlines. Native logout acts only on that profile's credential store;
other profiles, the standard ~/.codex home, and session history are preserved.
After any auth outcome, old measurements are discarded and native state is
reconciled; cancellation is not a rollback of a login that already completed.
Forget profile removes monitoring metadata, leaving its credential directory and
any history intact. Sign out first when credentials should also be removed.

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
Profile measurements do not participate in native Lowest or threshold alerts.

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
