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
- Statistics opens on the all-time range. Account-wide Total, Days, and Activity
  come from Codex account usage so they survive deleting local sessions or
  moving to another Mac. Input, Output, cache, reasoning, Models, Events, and
  Files remain local because the account endpoint does not expose those
  breakdowns. API-equivalent Estimate applies the blended cost per token found
  in local sessions to the account token total for the selected period. Native
  `Account` and `Local` labels make the boundary visible wherever the two scopes
  meet.
- Period controls remain unboxed, accounting values are grouped by meaning, and
  model/day tables scroll only vertically without horizontal overflow. The day
  table omits zero-activity dates. The page may scroll vertically to reach the
  final Activity block; its GitHub-style day squares may scroll horizontally for
  long histories and expose exact date/token activity on hover. Each month is a
  distinct mini-grid with a standard abbreviated label and visible inter-month
  spacing, so labels never wrap into vertical letters.
- Token help cycles on each hover through `15` explicitly approximate
  English-word-count comparisons: The Little Prince, The Hobbit, the complete
  The Lord of the Rings and Harry Potter cycles, plus ten well-known fantasy or
  science-fiction novels: Dune, 1984, Brave New World, A Game of Thrones, The
  Name of the Wind, American Gods, The Hitchhiker's Guide to the Galaxy,
  Ender's Game, Neuromancer, The Martian, and Fahrenheit 451. The comparison
  internally uses `0.75 English words per token`, but the user-facing copy starts
  directly with the natural book equivalence instead of defining a token as a
  fraction of a word. It states each title's rounded word-count basis and warns
  that cached context repeats make this processed volume rather than unique
  reading. Total, Input, and Output each receive their own rotating comparison,
  calculated from that metric's value and separated from its definition by a
  paragraph break. Book-copy counts are rounded to whole copies; values below
  half a copy read as `less than one copy` instead of showing a decimal.
- Statistics resets to its compact `900 × 650 pt` size, centers, and fully
  constrains itself to the visible screen on every open instead of retaining an
  oversized off-center frame. Opening Statistics also closes the menu popover
  so it cannot cover the analytics window.
- API-equivalent cost is always an estimate, never a subscription bill. With
  account usage available, it equals account tokens for the selected period ×
  the blended API-equivalent cost per token observed in local session logs.
  This extrapolation is necessary because Codex exposes the account token total
  but not its model/input/output mix. Offline fallback cost remains the direct
  sum derived from local per-model token rates.
- Local Total tokens means `Input + Output`, not merely user-typed text. The
  account-wide Total follows the aggregate activity definition reported by
  Codex and is not presented as the sum of the narrower local cards. Input covers
  everything the model reads, including user messages, instructions, prior
  conversation, files, tool results, and cached context. Output covers returned
  replies/actions plus reported internal reasoning; reasoning is a subset of
  Output and may not be visible to the user. Each metric's help states its own
  boundary in a short first paragraph before a separate book-scale paragraph.
- Cached input, cache writes, output, and reasoning remain separate accounting
  concepts. Reasoning is a subset reported with output usage.
- Statistics groups each headline with its own accounting details in one aligned
  three-column grid. Total occupies column one and Sources spans columns two and
  three; Input, Output, and Estimate form the second row on the same column
  boundaries. All second-row content aligns to the top.
- All windows follow the current macOS light or dark appearance.
- The compact menu presents the application version as the final `Version`
  key/value row in its top summary; it has no separate version footer.

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
