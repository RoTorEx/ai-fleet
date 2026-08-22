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
│  Claude/Qwen: local install + auth      │
│               detection                 │
└─────────────────────────────────────────┘
```

## Data flow

1. `AppDelegate` sets `NSApplication` activation policy to `.accessory` so no dock icon appears.
2. `StatusService.start()` begins refreshing provider state every 60 seconds.
3. `StatusBarController` owns the menu-bar icon and hosts `AIFleetMenuView` inside an `NSPopover`.
4. `GlobalHotKey` registers `⌘⇧I` to toggle the same popover as clicking the menu-bar icon.
5. Each provider returns a `ProviderStatus` with `ok`, `limited`, `offline`, `noKey`, or `notInstalled` state.
6. `AIFleetMenuView` observes `StatusService` and re-renders on every change.
7. `UsageAnalyticsService` reads local Codex JSONL usage metadata for token
   totals, model/day breakdowns, reasoning usage, and
   API-equivalent cost estimates. Opening Statistics reads only the aggregate
   snapshot. Manual or scheduled background refreshes reuse unchanged files
   from a per-file aggregate cache and parse changed files at background
   priority. Kimi statistics use quota windows from `StatusService`.
8. `UpdateService` resolves the latest GitHub Release for the current CPU,
   verifies the published checksum and application bundle, atomically replaces
   the installed app, and relaunches it.

## Models

- `ProviderStatus` — identity, display name, state, detail string, and last-update time.
- `KimiCodeUsageResponse` — Kimi Code subscription usage payload.
- `KimiBalanceResponse` — Moonshot balance fallback payload.
- `CodexUsageResponse` — ChatGPT WHAM usage payload.
- `CodexAuth` — minimal `~/.codex/auth.json` shape.
- `ProviderCatalog` — supported provider list, executable names, and local credential paths used for install/login detection.
- `UsageAnalyticsSnapshot` — cached Codex token analytics, Kimi quota analytics, last refresh time, and last load duration for the Statistics window.

## UI

- `AIFleetMenuView` — minimal popover with Kimi and Codex rows, last update time, and Refresh / Quit buttons.
- `StatisticsView` — centered, resizable provider analytics window with
  date-range filtering, vertically scrolling fixed-column tables, and adaptive
  panels. Zero-activity dates are omitted from the day table. Only
  accounting-specific terms carry hover explanations; token volume cycles
  through 15 approximate real-book comparisons after explaining the Input,
  Output, cache, returned-content, and reasoning boundaries. Each open resets
  the window to its compact size before centering it on the visible screen.

## Configuration

- Kimi Code credentials: `~/.kimi-code/credentials/kimi-code.json`.
- Kimi API key fallback: `~/Library/Application Support/AI Fleet/config.json` (`kimiApiKey`) or `KIMI_API_KEY` environment variable.
- Codex token: read automatically from `~/.codex/auth.json`.
- Codex local usage analytics: numeric token-usage metadata from active
  `~/.codex/sessions/**/*.jsonl` and `~/.codex/archived_sessions/*.jsonl` files.
- Statistics cache: `~/Library/Application Support/AI Fleet/usage-analytics-cache.json`.
- Incremental per-file statistics cache:
  `~/Library/Application Support/AI Fleet/usage-analytics-files-cache.json`.
- Statistics refresh: optional once-daily local schedule, enabled by default at
  12:00; manual refresh is always available.
- Claude login detection: local Claude credential files such as `~/.claude.json`.
- Qwen login detection: local Qwen credential files such as `~/.qwen/oauth_creds.json`.

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
