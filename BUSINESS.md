# AI Fleet Product Rules

AI Fleet is a native macOS menu-bar companion for monitoring remaining AI coding
provider quotas and reviewing local Codex usage. It is informational: it does
not proxy prompts, bill users, or claim that API-equivalent estimates are actual
subscription charges.

## Actors and flows

- A local developer reads quota state from the menu and receives threshold
  notifications for individual provider windows such as `5h` and `7d`.
- The developer opens Statistics to explore cached Codex usage by period without
  triggering expensive work.
- The developer may refresh statistics manually or let the app perform one
  low-priority refresh per day at a configured local time.

## Invariants

- Quota notifications name the provider, crossed threshold, and exact window;
  no redundant remaining value follows the threshold.
- Statistics date-range changes operate on cached daily/model aggregates and do
  not reread session logs.
- Statistics opens on the all-time range so Activity exposes the full cached
  history; shorter ranges are explicit user filters.
- API-equivalent cost is derived from model token rates and is always labeled as
  an estimate, never as a subscription bill.
- Cached input, cache writes, output, and reasoning remain separate accounting
  concepts. Reasoning is a subset reported with output usage.
- All windows follow the current macOS light or dark appearance.

## Decision-bearing defaults

- Provider status polling remains every `60 seconds` for timely quota state.
- Automatic Codex analytics refresh is enabled by default once per local day at
  `12:00`. The user can disable it or choose any minute of the day in Settings.
  A daily cadence limits disk and CPU use while keeping historical reporting
  useful; manual refresh covers urgent cases.
- Background analytics parses only changed JSONL files and runs at background
  task priority. The first scan may still read all files; later scans reuse the
  protected per-file cache.

## Code map

- Quota and notifications: `Sources/AIFleet/StatusService.swift`
- Refresh preferences: `Sources/AIFleet/AppSettings.swift`
- Analytics and caches: `Sources/AIFleet/UsageAnalytics.swift`
- User interfaces: `Sources/AIFleet/UI/*`
