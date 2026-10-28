# AI Fleet Product Rules

AI Fleet is a native macOS menu-bar companion for monitoring remaining AI coding
provider quotas and reviewing Codex, Claude Code, Kimi and Qwen usage. It is informational: it does
not proxy prompts, bill users, or claim that API-equivalent estimates are actual
subscription charges.

## Actors and flows

- The developer switches Usage/Agents with Command-A in the open menu, reviews
  local live Codex/Claude sessions and jumps to an exact iTerm2 pane without
  closing the overview. [Agents](business/agents.md) owns this integration.

- A local developer reads quota state from the menu and receives threshold
  notifications for individual provider windows such as `5h` and `7d`.
- The developer opens Statistics to explore cached Codex, Claude Code, Kimi and Qwen usage by period without
  triggering expensive work.
- The developer may refresh statistics manually or let the app perform one
  low-priority refresh per day at a configured local time.

## Invariants

- Greek letters identify real accounts. One account can own several providers,
  with at most one connection per provider. Provider rows and account statistics
  use the same `Provider (badge)` identity. Internal credential homes and the
  standard CLI login are not separate visible accounts. Connect provider chooses
  an existing or new account before login; hidden providers retain stored data.
- Each Codex account can keep an independent saved browser login. Its quota and
  tokens remain available when another account signs in, without changing the
  authorization of running terminals. Expected email must match before quota is
  attributed. A matching standard CLI login may supply read-only data until an
  independent login is attached. No shared local history or model cost is assigned
  across accounts. [Saved Codex login](business/codex-profiles.md) owns storage.
- Provider installation, login, and quota support are separate states. Claude
  login comes from the CLI's structured `auth status` result, never from
  `.claude.json` settings. Qwen requires OAuth token fields, not merely a
  nonempty file; expired access without a refresh token requires sign-in.
  Qwen's local check does not validate credentials with the server. Confirmed
  missing login reads `Sign in required` in both Settings and the menu; failed
  or unrecognized local checks read `Auth status unknown`. Qwen quota retrieval
  is not implemented and reads `Signed in · quota unsupported` when login is
  configured. Claude subscription quotas reuse that CLI profile's OAuth token
  from its credentials file or its profile-specific Claude Code Keychain item.
  Tokens stay in memory and are never logged; credentials are removed only by an explicit local Sign out action, and
  requests go only to Anthropic's usage endpoint without following redirects.
  The main `five_hour` and `seven_day` windows display remaining percentages
  and reset times using the existing quota and notification rules. Missing or
  invalid measurements never become 100% remaining. API-key login or unavailable
  OAuth credentials reads `Signed in · quota unavailable`; quota/network errors
  stay distinct from missing login. Model-specific and paid extra usage are
  outside this integration.
- Gemini uses native file-backed Google OAuth and the CLI’s Code Assist model
  quota endpoint. Its email/plan and quota belong to the global login; API/Vertex
  and encrypted OAuth monitoring are unsupported. A refresh token or cached
  email cannot establish signed-in status: expired/unconfirmed credentials read
  Sign in required with ?, a gray row, no active arrow and no availability count.
  Only successful server identity verification confirms auth; explicit credential
  rejection uses ×. Token renewal stays with the native CLI. [Gemini](business/gemini.md) owns its auth, endpoint, model-bucket,
  request-gating and error rules.
- Opening the menu or Settings refreshes provider status so a login completed
  outside AI Fleet is picked up without waiting for the next periodic poll.
- Accounts are provider-independent labelled identities with stable α, β, γ
  badges. Each provider uses one standard global native CLI login. The row’s
  ellipsis menu exposes Sign in and, on the active signed-in row, Sign out. Codex Sign out uses native `codex logout`; other providers clear monitored native credentials locally. Changes to shared CLI authorization block while Codex processes run; per-account login uses independent storage and preserves those sessions. Sign in changes the global login through
  the provider’s native browser/SSO flow. No isolated session launch or manual
  working-account selection is exposed. Native email determines the current
  badge; duplicate email labels remain ambiguous. Current authenticated rows
  show → and normal colors; other associations are gray and have no quota.
  Small parenthesized badges follow the provider name; tightly grouped markers
  remain on the left and only … on the right. Hover immediately shows only
  email and plan in an inline overlay. Authentication and quota remain
  independent; the Color/Auth/Selection/Quota legend stays visible and ↓ marks
  lowest positive current global quota. Management stays in Settings → Accounts,
  with inline additions, label editing, global sign-in, and menu visibility;
  General contains only application-wide settings. Existing isolated files and
  metadata are preserved without polling or launching them. Selective login is
  deferred. See [Accounts](business/accounts.md) for matching and storage rules.

- Quota notifications name the provider, crossed threshold, and exact window;
  no redundant remaining value follows the threshold. When the provider supplies
  a reset timestamp, a second line shows both the compact time remaining and the
  exact local reset time, so the alert is glanceable without losing precision.
  Each threshold fires once per quota window, rearms when that window resets above
  it, and threshold-setting changes clear every provider/window notification marker.
- Codex quota status shows only the account's main `rate_limit` primary and
  secondary windows. Model-specific `additional_rate_limits`, including Spark,
  are intentionally ignored; they must never stand in for a missing main 5h
  window. If Codex returns the main 5h window again, the existing primary/secondary
  parsing displays it automatically.
- Statistics date-range changes operate on cached daily/model aggregates and do
  not reread session logs.
- Kimi and Qwen have separate Statistics tabs with local token/cache accounting,
  model/day tables, periods, and Activity grouped in the computer's time zone.
  Kimi keeps its separate account quota windows and their usage/reset details.
  No Qwen quota integration or provider API prices are implied. Missing prices
  show no cost estimate, and empty history is explicitly labelled.
  [Provider statistics](business/provider-statistics.md) owns formats, accounting
  boundaries, and verification.
- Claude has a separate Statistics tab with the same periods, token/cache cards,
  model/day tables, and Activity heatmap as Codex. All Claude metrics are local
  to `~/.claude/projects/**/*.jsonl`, including nested subagent transcripts;
  they are not subscription-wide history and are independent of current login.
  Input includes uncached input, cache reads and cache creation; Output includes
  reported thinking as a subset, never an extra charge. Unreported thinking is
  not inferred. Repeated content-block records with the same request/message ID
  count once per file, keeping the most complete usage sample. Missing/malformed
  records and synthetic messages are skipped. Refresh scans all four providers at
  background priority, reuses unchanged per-file aggregates, and preserves old
  Codex-only snapshots. Opening or switching tabs never scans logs.
- Claude API-equivalent estimates use standard USD-per-million-token rates from
  [Anthropic pricing](https://platform.claude.com/docs/en/about-claude/pricing),
  encoded in `ClaudeAPIRates`. Supported families match exact model names or
  dated variants; future unknown versions never inherit older prices. Cache
  reads have their own rate; writes cost 1.25 × input for 5m and 2 × input for
  1h, defaulting to 5m when duration metadata is absent. These are standard-rate
  comparisons, not bills: tool charges, fast-mode, long-context and platform
  premiums are excluded. An unknown price suppresses the affected model/day
  estimate and the selected total estimate while retaining token counts.
  `ClaudeUsageAnalyticsTests` protects cache accounting, repeated records,
  unknown prices, nested discovery, period selection, and snapshot compatibility.
- Statistics opens on the all-time range. Only the all-time Codex Total and
  its extrapolated API-equivalent Estimate use account-wide usage, preserving
  that headline after deleting local sessions or moving to another Mac.
  Days, Activity, and date-filtered totals/estimates use local session event
  timestamps grouped from local midnight to the next local midnight in the
  computer's current time zone, including daylight-saving transitions. Provider
  day buckets have no event timestamps and cannot establish that boundary;
  delayed or missing account days must never hide recorded local activity.
  These date-based views cover only history retained on this Mac. Input, Output,
  cache, reasoning, Models, Events, and Files also remain local. `Account` and
  `Local` labels identify the actual source. Refresh rereads changed files;
  per-file aggregates from another or unknown time zone are rebuilt from logs.
- Period controls remain unboxed and accounting values are grouped by meaning.
  The lower Statistics region has two arrow-controlled pages: `Models + Days`
  and `Activity`. There is no surrounding vertical scroll view, so the compact
  model/day lists scroll only themselves and cannot chain into the page. The day
  table omits zero-activity dates. Activity's GitHub-style day squares may scroll
  horizontally for long histories and expose exact date, token activity, and
  the API-equivalent daily estimate when available. Each month is a distinct
  mini-grid with a standard abbreviated label centered over that month's cells
  and visible inter-month spacing, so labels never wrap into vertical letters.
  Before the first anniversary, the grid extends with empty future days through
  the end of the first year measured from the first recorded vibecoding day.
  After that anniversary it extends through the end of the current month, opens
  with that month at the right, and keeps older history available by scrolling
  left. Cell sizing fits one vibecoding year in the default window, while the
  Activity panel uses only its content height instead of filling empty space.
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
- Statistics number formatting is locale-stable across tokens, estimates,
  source counts, progress, heatmap details, and book comparisons: spaces group
  thousands and a dot separates the integer part from fractional digits. The
  Total uses billions with two decimal places; Input and Output use millions
  with two decimal places. Heatmap hover values also use millions with two
  decimal places.
- Statistics resets to its compact `900 × 650 pt` size, centers, and fully
  constrains itself to the visible screen on every open instead of retaining an
  oversized off-center frame. Opening Statistics also closes the menu popover
  so it cannot cover the analytics window.
- API-equivalent cost is always an estimate, never a subscription bill. With
  account usage available, it equals the all-time account token total ×
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
  three-column grid. Estimate occupies the first column and Total spans the two
  columns above Input and Output; Sources sits beneath Estimate. All second-row
  content aligns to the top, both rows use equal card heights, and column widths
  are calculated explicitly instead of relying on SwiftUI spanning-cell layout.
  The second row reserves enough bottom space for Input's three accounting rows,
  so its final Cache writes line never touches or crosses the card boundary.
- The compact period selector sits at the upper right directly below account
  and local refresh timestamps in its own trailing row, leaving the content grid
  unobstructed and keeping its label and segments aligned as one compact unit.
  Summary and detail panels remain within the default window size.
- All windows follow the current macOS light or dark appearance.
- The compact menu presents the application version as the final `Version`
  key/value row in its top summary; it has no separate version footer.
- Remaining-quota color states in the compact menu are red at `10%` or below,
  orange from `11%` through `25%` inclusive, and normal at `26%` or above.
  The boundaries make the warning band more visible before an account becomes
  critically low; they apply consistently to both provider rows and individual
  quota windows.

## Decision-bearing defaults

- Provider status polling remains every `60 seconds` for timely quota state.
  Claude quota requests within a running app are spaced at least
  `300 seconds` (five minutes),
  including manual refresh/opening views. This app-defined interval bounds
  request volume for long 5h/7d windows; it is not a claimed Anthropic limit.
  A HTTP 429 response pauses quota updates without changing confirmed login.
  Retries double from `300 seconds` up to `3600 seconds` (one hour), and a later
  server `Retry-After` deadline takes precedence. A missing/zero/invalid header
  never causes immediate repeated requests. Cooldown survives app restart;
  simultaneous refreshes join one request. Last successful quota stays visible
  with its measurement time and retry time, but stale quota cannot generate
  threshold alerts or become the Lowest recommendation. With no measurement,
  the app shows signed-in/waiting instead of inventing remaining quota.
  Successful updates clear the retry state. Tests in `ClaudeQuotaPollerTests`
  protect request counts, cancellation, restart, recovery, and account isolation.
- Claude's local auth check runs off the UI thread and times out after
  `10 seconds`, terminating the owned CLI process so a hung check cannot stall
  subsequent provider refreshes. This bound is shorter than the polling period;
  timeout is an unknown auth state, not proof that sign-in is missing.
- Automatic Codex, Claude, Kimi and Qwen analytics refresh is enabled by default once per local day at
  `12:00`. The user can disable it or choose any minute of the day in Settings.
  A daily cadence limits disk and CPU use while keeping historical reporting
  useful; manual refresh covers urgent cases.
- Background analytics parses only changed JSONL files and runs at background
  task priority. The first scan may still read all files; later scans reuse the
  protected per-file cache.

## Code map

- Quota and notifications: `Sources/AIFleet/StatusService.swift`
- Claude subscription usage: `Sources/AIFleet/ClaudeQuota.swift`
- Gemini model quota and native OAuth: `Sources/AIFleet/GeminiQuota.swift`
- Local login detection: `Sources/AIFleet/LocalProviderAuth.swift`
- Shared accounts, provider connections, and launch: `Sources/AIFleet/Accounts.swift`
- Claude configuration/Keychain selectors: `Sources/AIFleet/ClaudeProfiles.swift`
- Account management inside Settings: `Sources/AIFleet/UI/AccountsSettingsView.swift`
- Refresh preferences: `Sources/AIFleet/AppSettings.swift`
- Claude local accounting and API rates: `Sources/AIFleet/ClaudeUsageAnalytics.swift`
- Kimi and Qwen local accounting: `Sources/AIFleet/ProviderUsageAnalytics.swift`
- Analytics and caches: `Sources/AIFleet/UsageAnalytics.swift`
- User interfaces: `Sources/AIFleet/UI/*`
