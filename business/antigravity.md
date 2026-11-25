# Antigravity CLI integration

Antigravity CLI replaced Gemini CLI, which Google retired for individual
accounts in June 2026. Fleet treats it as its own provider, `antigravity`, next
to the legacy Gemini provider: the two have separate sign-ins, separate storage
and separate quota. Installation detection looks for `agy` or `antigravity`;
the Homebrew cask `antigravity-cli` installs `agy`, a wrapper around a binary
named `antigravity`. Its data lives in `~/.gemini/antigravity-cli`.

Session discovery, activity and alerts belong to [Agents](agents.md). This
module owns sign-in state and quota.

## Sign-in and identity

- Antigravity keeps its Google sign-in in the login Keychain: service `gemini`,
  account `antigravity`. go-keyring writes it as `go-keyring-base64:` followed
  by Base64 of a JSON record with `token.access_token`, `token.refresh_token`,
  `token.expiry` and `id_token_email`. Fleet reads it through
  `/usr/bin/security`, the way it reads Claude's Keychain login. The item was
  written through that tool, so reading it raises no Keychain prompt.
- The access token lives for one hour and only the CLI renews it. Fleet never
  refreshes Google tokens and never writes the Keychain item. An expired token
  with a refresh token is **unknown**: the row is gray, reads `Open agy to
  renew sign-in`, and does not count as available. Starting `agy` renews the
  token, and the next refresh shows quota again. This is the main limit of the
  integration: with `agy` closed for over an hour, quota is not shown.
- No item (exit code 44) is signed out. Malformed data is unknown.
- `id_token_email` is a local display hint. Google OAuth userinfo verifies the
  actual email before quota is attributed, as for Gemini.
- Tokens stay in memory and are never logged or stored in preferences.
  Redirects are rejected, so a bearer token cannot follow another host.
- **Sign in with Google** starts `agy acp` and asks for its advertised
  `oauth-personal` method. The CLI owns the browser flow and writes the native
  Keychain item. Fleet waits up to **600 seconds**, the same browser window as
  Codex, then stops its own authentication process. Cancel closes that process.
  Fleet verifies the resulting Google email before presenting sign-in as
  complete. Older CLIs can sign in interactively with `agy`.
- The Keychain item belongs to the CLI. Local sign-out stays in the CLI.
- There is no verified home selector, so Antigravity has one native login, no
  private profiles and no Switch.

## Quota contract

Antigravity CLI 1.5.15 calls `https://daily-cloudcode-pa.googleapis.com` and
Fleet uses the same host. These are the CLI's internal endpoints, not a stable
public API, and only reads are made:

1. `v1internal:loadCodeAssist` gives the plan (`paidTier` or `currentTier`) and
   the project. Both are labels; a failure other than 401 or 429 does not stop
   the quota read.
2. `v1internal:fetchAvailableModels`, with the project when known, returns a map
   of model id to details. Each model carries `displayName`, `disabled` and
   `quotaInfo` with `remainingFraction` in [0,1] and `resetTime`.

The response shape comes from the API descriptors embedded in the 1.5.15 binary
(`FetchAvailableModelsResponse`, `ModelDetails`, `QuotaInfo`) and from the
endpoints its log shows it calling. The tested personal Google login passed
identity verification and returned HTTP 403 for the quota request. The native
CLI listed models and completed a headless prompt for that login. Successful
quota responses have fixture coverage.

Rules:

- A model without `quotaInfo`, or with a fraction outside [0,1], is omitted
  instead of shown as 100%. A disabled model is omitted.
- The response is proto3 JSON, which leaves out a zero. A `quotaInfo` with a
  reset time and no fraction is therefore a spent quota, 0%. A `quotaInfo` with
  neither is no measurement.
- Thinking levels of one model, `Gemini 3.8 Flash (High)`, `(Medium)` and
  `(Low)`, draw on one quota. When they report the same percent and reset time
  they are one line named without the parenthetical; when they differ, each
  keeps its line.
- Model names take their own line above the bar, as for Gemini. Lowest and
  notifications use the lowest model.

Requests share Gemini's gate: coalesced and cached per hashed access token for
**300 seconds**, in memory, reset on app restart. HTTP 429 pauses for at least
that interval and a later Retry-After takes precedence. HTTP 401 requires
sign-in. HTTP 403, 429 and server or network errors keep signed-in status only
when userinfo already confirmed the identity in that request. A failure never
produces measurements.

## Checks

AntigravityQuotaTests covers the ACP sign-in exchange and the Keychain record (live, expired, empty,
malformed, plain JSON), the renew hint, model decoding (joined thinking levels,
zero by omitted fraction, skipped models), the request flow with and without a
plan, a rejected token, and the provider's place in the catalog, the Processes
tab and sign-out.
