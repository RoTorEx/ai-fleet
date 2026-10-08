# Gemini CLI integration

Gemini uses the same global-login and account-badge rules as other providers.
Installation detection looks for `gemini`; global native data is `~/.gemini`.
The first Sign in starts its interactive CLI. An already configured login starts
`gemini --prompt-interactive '/auth login'`, opening its native authentication
dialog without a model prompt. The user chooses Sign in with Google and completes
the provider’s flow. Native managed settings are respected. Inherited directory,
API-key, ADC and auth-mode overrides are removed; corporate Google Cloud project
environment settings remain available to the native Terminal workflow.

## Credentials and identity

- `settings.json` → `security.auth.selectedType` distinguishes Google OAuth
  (`oauth-personal`) from API/Vertex. Selecting a method alone does not establish
  server access. Unsupported methods read `API/Vertex login · quota unsupported`
  with unknown auth. No guessed quota or tariff is shown.
- `oauth_creds.json` must contain a usable access token or a refresh token;
  arbitrary JSON is not login. Malformed/unreadable data is unknown. Expired
  access without refresh requires sign-in. A refresh token alone, including an
  expired access token with refresh available, is **unknown**, not signed in.
  Unconfirmed Google login reads `Sign in required`, stays gray, has no active
  arrow, and cannot count as an available provider. Confirmed missing/rejected
  login uses ×; unconfirmed login uses ?. Native renewal remains possible but
  does not prove access until the server identity check succeeds. AI Fleet never performs Google token refresh or rewrites
  these files. Encrypted OAuth/Keychain storage is outside this file reader;
  a cached active account without readable credentials remains unknown.
- `google_accounts.json` → `active` is a native display hint; `old` is ignored.
  OAuth userinfo verifies actual email before retrieving quota. If that request
  fails, the active cached email may label the error, but no quota is attributed.
  A successful response supplies actual email to the shared account matcher.
- OAuth tokens stay in memory and are never logged, copied, or stored in app
  preferences. Redirects are rejected, so bearer tokens cannot follow another
  host. Requests use Google OAuth userinfo and the CLI’s Code Assist backend.

## Quota contract

The observed Gemini CLI 0.46.0 contract uses
`https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist` to obtain project
and paid/current tier, then `retrieveUserQuota` with that project. These are the
CLI’s internal endpoints, not a promised stable public API. Only reads are made;
AI Fleet does not onboard users, accept terms, generate model content, enable
billing, or consume AI credits. A missing project prompts native project setup.
Personal Google subscriptions and corporate Code Assist/Workspace entitlement
are distinct; the app displays the tier returned by this backend, not a guessed
subscription from the email domain.

Each valid model bucket provides `remainingFraction` in [0,1] and optional
`resetTime`. Missing/invalid fractions are omitted instead of treated as 100%.
Duplicate model buckets use the smallest remaining percentage, matching the
CLI’s conservative model display. Zero quota remains zero with signed-in auth.
Model names occupy a separate line so they do not squeeze time-window labels;
long provider content uses the existing bounded menu scroll area. Missing reset
times remain unknown. Lowest and notifications use the current global account’s
valid model measurements under the existing rules.

Requests are coalesced and cached per hashed access credential for **300 seconds
(five minutes)**, including menu opens/manual refreshes. This application-defined
interval bounds read traffic for longer quota periods; it is not a claimed Google
limit. HTTP 429 pauses for at least that interval and a later Retry-After takes
precedence. This gate is in memory and resets on app restart. Failure produces
no measurements; previous measurements are not silently reused as current.
HTTP 401 requires sign-in. HTTP 403, 429, server/network errors retain signed-in
status only when OAuth userinfo has already confirmed the current identity in
that request. Failure or missing identity during userinfo remains unknown with
`Sign in required`; cached email cannot establish access. Quota-only failures
following successful userinfo retain confirmed auth with unavailable quota. Explicit API/Vertex quota monitoring
and encrypted storage are deferred.

## Sources and checks

- [Official installation](https://geminicli.com/docs/get-started/installation/)
- [Native authentication](https://geminicli.com/docs/get-started/authentication/)
- [Code Assist server source](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/code_assist/server.ts)
- [Quota types](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/code_assist/types.ts)

The installed 0.46.0 bundle was inspected for native auth-dialog dispatch,
credential/account paths, project/tier fields, and quota requests. GeminiQuotaTests
covers missing/malformed/expired credentials, old-account exclusion, unsupported
methods, model buckets including zero, identity/project/tier request flow, error
states, and credential-specific request gating. Regression tests cover expired
refreshable credentials and failed/empty userinfo without false active status. Corporate browser/SSO login and
live quota require user authentication and are not established by fixtures.
