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

## Models

- `ProviderStatus` — identity, display name, state, detail string, and last-update time.
- `KimiCodeUsageResponse` — Kimi Code subscription usage payload.
- `KimiBalanceResponse` — Moonshot balance fallback payload.
- `CodexUsageResponse` — ChatGPT WHAM usage payload.
- `CodexAuth` — minimal `~/.codex/auth.json` shape.
- `ProviderCatalog` — supported provider list, executable names, and local credential paths used for install/login detection.

## UI

- `AIFleetMenuView` — minimal popover with Kimi and Codex rows, last update time, and Refresh / Quit buttons.

## Configuration

- Kimi Code credentials: `~/.kimi-code/credentials/kimi-code.json`.
- Kimi API key fallback: `~/Library/Application Support/AI Fleet/config.json` (`kimiApiKey`) or `KIMI_API_KEY` environment variable.
- Codex token: read automatically from `~/.codex/auth.json`.
- Claude login detection: local Claude credential files such as `~/.claude.json`.
- Qwen login detection: local Qwen credential files such as `~/.qwen/oauth_creds.json`.

## Extension points

- Add more lanes by extending `StatusService` and `AIFleetMenuView`.
- Make the refresh interval configurable.
- Surface errors inline or via notifications.
