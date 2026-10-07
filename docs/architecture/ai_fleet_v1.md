# AI Fleet v1 Architecture

## Overview

AI Fleet is a tiny native macOS menu-bar application built with SwiftUI. It shows the current status and remaining limit for installed AI coding-provider lanes — Codex, Kimi, Claude, and Qwen — and refreshes once per minute.

## Components

```
┌─────────────────────────────────────────┐
│        NSStatusItem + NSPopover         │
│ (StatusBarController + Menu SwiftUI)    │
└─────────────────┬───────────────────────┘
│  @EnvironmentObject
▼
┌─────────────────────────────────────────┐
│           StatusService                 │
│   (@Published ProviderStatus × 4)       │
└─────────────────┬───────────────────────┘
│  URLSession polling
▼
┌─────────────────────────────────────────┐
│  Kimi: api.kimi.com/coding/v1/usages    │
│        or api.moonshot.ai/v1/users/me/  │
│        /balance                         │
│  Codex: chatgpt.com/backend-api/wham/   │
│         /usage                          │
│  Codex stats: ~/.codex/sessions JSONL   │
│  Claude: api.anthropic.com/api/oauth/   │
│          usage                          │
│  Qwen: local install + auth detection   │
└─────────────────────────────────────────┘
```

## Data flow

1. `AppDelegate` sets `NSApplication` activation policy to `.accessory` so no dock icon appears.
2. `StatusService.start()` begins refreshing provider state every 60 seconds.
3. `StatusBarController` owns the menu-bar icon and hosts `AIFleetMenuView` inside an `NSPopover`.
4. `GlobalHotKey` registers `⌘⇧I` to toggle the same popover as clicking the menu-bar icon.
5. Each provider returns a `ProviderStatus` with `ok`, `limited`, `offline`, `noKey`, or `notInstalled` state.
6. `AIFleetMenuView` observes `StatusService` and re-renders on every change.
7. `UsageAnalyticsService` asks `codex app-server` for account-wide lifetime and
   daily usage, and reads local Codex JSONL metadata for input/output/cache,
   model, reasoning, event, file, and API-equivalent rate details. Account cost
   estimates extrapolate that blended local rate across account tokens. Opening
   Statistics may perform the lightweight account request but does not scan
   session logs. Manual or scheduled refreshes reuse unchanged files from a
   per-file aggregate cache and parse changed files at background priority.
   Kimi statistics use quota windows from `StatusService`.
8. `UpdateService` resolves the latest GitHub Release for the current CPU,
   verifies the published checksum and application bundle, atomically replaces
   the installed app, and relaunches it.

## Models

- `ProviderStatus` — subscription row ID, provider ID, display name, state,
  quota windows, optional account metadata, and an account notification scope.
- `AccountStore` — provider-independent accounts with stable badges, provider
  associations, and preserved legacy connection paths/selections. Global
  associations have unique row IDs without credential directories. Native
  credentials remain with the provider CLI.
- `ClaudeQuotaPoller` — actor that coalesces in-flight usage requests, caches
  successful quota measurements, and persists per-identity retry cooldowns.
  `ProviderStatus.quotaNotice` distinguishes last-known/paused quota from login
  or connectivity failures; stale measurements are excluded from notifications
  and the compact menu's Lowest selection.
- `KimiCodeUsageResponse` — Kimi Code subscription usage payload.
- `KimiBalanceResponse` — Moonshot balance fallback payload.
- `CodexUsageResponse` — ChatGPT WHAM usage payload.
- `CodexAuth` — minimal `~/.codex/auth.json` shape.
- `ProviderCatalog` — supported provider list, executable names, and local credential paths used for install/login detection.
- `UsageAnalyticsSnapshot` — cached Codex account usage, local token analytics,
  Kimi quota analytics, refresh times, and local scan duration.

`ProviderStatus` carries independent authentication and quota states alongside
its existing transport/threshold state. Native login confirmation survives usage
endpoint failure; explicit credential rejection requires sign-in. All profile,
connection, account, and notice transformations preserve the independent fields.
`hasCurrentQuota` gates Lowest and notifications, excluding unknown, unsupported,
stale, unauthenticated, and unavailable measurements. StatusService checks one canonical global connection per provider, then matches
the reported email through AccountStore. Its globalAccountIDs maps observed
identity to badges; legacy manual selections do not control the current login.
Inactive associations receive no quota or reported identity. Ambiguous labels
receive no current row; the provider summary retains the actual native status.

## UI

- `AIFleetMenuView` — one row per connected account/provider pair, grouped by
  provider. Each small parenthesized badge follows the provider name; there is
  no circle or separate account-name line. Selected rows use
  status colors and the legend’s → marker. Selection, Lowest, and authentication
  markers use aligned left columns; quotas align with the provider name. Only
  the ellipsis menu occupies the right edge. Inactive rows and quota windows are
  gray. Unavailable connections retain × plus their reason. Ellipsis actions
  contain only global native Sign in; no isolated launch or manual Use action.
  Badge hover shows only email and plan immediately, using a noninteractive
  inline overlay above neighbouring rows rather than delayed native help. Health/Lowest summarize native global connections.
  Long connection lists use a bounded scroll area. The legend separates Auth,
  Selection, Quota, and quota colors; no automatic fallback is advertised.
- `SettingsNavigation` — shared, transient tab/add-provider navigation, including
  requests delivered while the existing Settings window is already open.
- `AccountsSettingsView` — account editor in the existing Settings window's
  Accounts tab. Its inline email/provider form adds and signs in; cancellation
  does not create metadata. New associations do not create credential folders. It
  renames labels, removes metadata, opens native CLI sign-in, and owns global
  provider visibility controls. The editor picker never changes the working
  account; every Sign in action uses a canonical native-default connection.
  Folder imports and isolated launches are deferred; legacy files are preserved.
  General has no provider/account controls. There is no
  account-management window. Settings has a bounded 500 × 640 point layout with
  scrolling so SwiftUI fitting-size changes cannot collapse it to a narrow strip.
- `StatisticsView` — centered, resizable provider analytics window with
  date-range filtering, account/local source labels, vertically scrolling
  fixed-column tables, an aligned three-column summary grid, and a final
  horizontally scrolling GitHub-style daily heatmap grouped into spaced month
  grids with centered labels and explicit hover popovers. Zero-activity dates
  are omitted from the day table. Only
  accounting-specific terms carry hover explanations; token volume cycles
  through 15 approximate real-book comparisons after explaining the Input,
  Output, cache, returned-content, and reasoning boundaries. Total, Input, and
  Output calculate their comparisons independently and place them in a separate
  paragraph. Estimate sits above Sources in the first summary column while Total
  spans the two columns above Input and Output. Explicit three-column geometry
  keeps both rows equal in height; period controls live beneath refresh status.
  Each open
  resets the window to its compact size before centering
  it on the visible screen.

## Configuration

- Kimi Code credentials: `~/.kimi-code/credentials/kimi-code.json`.
- Kimi API key fallback: `~/Library/Application Support/AI Fleet/config.json` (`kimiApiKey`) or `KIMI_API_KEY` environment variable.
- Codex token: read automatically from `~/.codex/auth.json`.
- Codex local usage analytics: numeric token-usage metadata from active
  `~/.codex/sessions/**/*.jsonl` and `~/.codex/archived_sessions/*.jsonl` files.
- Codex account usage: lifetime and daily token activity from the official
  `account/usage/read` Codex app-server method for the signed-in ChatGPT account.
- Statistics cache: `~/Library/Application Support/AI Fleet/usage-analytics-cache.json`.
- Incremental per-file statistics cache:
  `~/Library/Application Support/AI Fleet/usage-analytics-files-cache.json`.
- Statistics refresh: optional once-daily local schedule, enabled by default at
  12:00; manual refresh is always available.
- Claude login detection: `claude auth status` JSON plus its exit code, executed
  off the UI thread with a 10-second timeout. The CLI resolves the active auth
  source (including macOS Keychain); `.claude.json` is not login evidence.
- Qwen login detection: parsed OAuth token fields in local credential files
  such as `~/.qwen/oauth_creds.json`. Expired access needs a refresh token;
  these credentials are not validated with the server.
- Claude quota retrieval: `GET https://api.anthropic.com/api/oauth/usage` with the
  existing CLI profile's OAuth token and `anthropic-beta: oauth-2025-04-20`.
  `ClaudeQuota.swift` reads the active profile's `.credentials.json`, falling
  back to the selected profile's scoped Keychain service through
  `/usr/bin/security`. It never refreshes or writes Claude credentials. Only the
  main 5h/7d subscription windows are displayed; redirects are rejected.
  Source reference: https://github.com/steipete/CodexBar/blob/main/docs/claude.md.
- Qwen quota retrieval is unsupported. Login and quota errors remain separate
  in both the menu and Settings; opening either surface requests a fresh check.
- Claude profile and launch boundaries:
  [business/accounts.md](../../business/accounts.md).

## Delivery and updates

- Annotated `vMAJOR.MINOR.PATCH` tags trigger native Apple Silicon and Intel
  builds in GitHub Actions.
- Release ZIPs and their SHA-256 files are attached to GitHub Releases.
- In-app updates accept only HTTPS assets from `RoTorEx/ai-fleet`, require the
  expected architecture-specific filenames, verify SHA-256, bundle identifier,
  release version, and code signature, then replace the running app.
- The updater never removes macOS quarantine attributes. Developer ID signing
  and notarization remain required for frictionless public distribution.

## Extension points

- Add more lanes by extending `StatusService` and `AIFleetMenuView`.
- Make the refresh interval configurable.
- Surface errors inline or via notifications.
