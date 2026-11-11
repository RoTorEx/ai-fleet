# AI Fleet Product Rules

AI Fleet is a native macOS menu-bar companion for monitoring remaining AI coding
provider quotas and reviewing Codex, Claude Code, Kimi and Qwen usage. It is informational: it does
not proxy prompts, bill users, or claim that API-equivalent estimates are actual
subscription charges.

## Actors and flows

- The developer sees live local Codex/Claude sessions in the Agents block under
  the providers of the main menu, reviews them and jumps to an exact iTerm2 pane without
  closing the overview. [Agents](business/agents.md) owns this integration.

- A local developer reads quota state from the menu and receives threshold
  notifications for individual provider windows such as `5h` and `7d`.
- The developer opens Statistics to explore cached Codex, Claude Code, Kimi and Qwen usage by period without
  triggering expensive work.
- The developer may refresh statistics manually or let the app perform one
  low-priority refresh per day at a configured local time.

## Invariants

- Enabled-provider visibility, saved-connection measurement counts, typed quota
  failures and reset states follow the [menu monitoring contract](docs/contracts/menu-monitoring.md).
  The first ten stable account badges are α β γ δ ε ζ η θ ι κ; local token
  history is never split by those badges.

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
  OAuth credentials show the reason limits cannot be loaded; quota/network errors
  stay distinct from missing login. Model-specific and paid extra usage are
  outside this integration.
- Gemini uses native file-backed Google OAuth and the CLI’s Code Assist model
  quota endpoint. Its email/plan and quota belong to the measured login home; API/Vertex
  and encrypted OAuth monitoring are unsupported. A refresh token or cached
  email cannot establish signed-in status: expired/unconfirmed credentials read
  Sign in required with ?, a gray row and no availability count. A selected
  next-launch default remains separate from authentication state.
  Only successful server identity verification confirms auth; explicit credential
  rejection uses ×. Token renewal stays with the native CLI. [Gemini](business/gemini.md) owns its auth, endpoint, model-bucket,
  request-gating and error rules.
- Opening the menu or Settings refreshes provider status so a login completed
  outside AI Fleet is picked up without waiting for the next periodic poll.
- Accounts are provider-independent labelled identities with stable α, β, γ
  badges. Menu rows sort by tool name, then strictly by Greek badge within each tool.
  Switch always selects the account for the next launch of that provider.
  The → marker identifies the default account for the next provider command after
  terminal integration, or the standard credential account before setup. Selection changes the launch preference; next-launch-only mode retains running
  sessions. Codex and Claude additionally support explicit stopping policies
  described in [Switch recovery](business/switch-recovery.md).
  Shared credential replacement remains a guarded internal recovery path. Fleet
  never creates terminals or agent sessions. Independent saved Codex logins retain their
  own quota and normal colors. Signing into one does not switch running sessions
  or change their shared CLI authorization. Claude, Kimi, Qwen and Gemini use account-specific launch profiles under the
  [universal Switch contract](business/provider-switching.md); native browser login
  remains separate. Shared Codex credential replacement stays blocked while Codex runs. Explicit,
  confirmed Stop/Force Quit controls are available in the Processes tab,
  independently of account selection.
  Management stays in Settings → Accounts: draggable account blocks in Greek-letter
  order with their providers, Add Account, and confirmed removal. Small parenthesized
  badges follow the provider name; clicking the name opens email, plan and
  account actions below it; hovering highlights it. One leading mark per row:
  ↓ current account with the lowest positive quota among current accounts,
  → other signed-in current accounts, none on other saved logins, ×/? unavailable.
  Switch is hidden for an already current signed-in account in both menu and Settings.
  Legacy isolated files and metadata remain preserved. See
  [Accounts](business/accounts.md) for matching, ordering and storage rules.

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
- Statistics is one screen for all providers. Provider chips (All, Codex,
  Claude, Kimi, Qwen; Option-click shows one) choose what the totals, By provider
  bars, models, days and Activity include; the choice persists and never hides a
  provider from the menu. Kimi and Qwen contribute local token/cache accounting.
  Kimi's account quota windows appear under Provider reports.
  No Qwen quota integration or provider API prices are implied. Missing prices
  show no cost estimate, and empty history is explicitly labelled.
  [Provider statistics](business/provider-statistics.md) owns formats, accounting
  boundaries, and verification.
- Claude statistics use the same periods, token/cache cards, model/day rows and
  Activity as the other providers. All Claude metrics are local
  to `~/.claude/projects/**/*.jsonl`, including nested subagent transcripts;
  they are not subscription-wide history and are independent of current login.
  Input includes uncached input, cache reads and cache creation; Output includes
  reported thinking as a subset, never an extra charge. Unreported thinking is
  not inferred. Repeated content-block records with the same request/message ID
  count once per file, keeping the most complete usage sample. Missing/malformed
  records and synthetic messages are skipped. Refresh scans all four providers at
  background priority, reuses unchanged per-file aggregates, and preserves old
  Codex-only snapshots. Opening Statistics or changing chips never scans logs.
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
- Statistics opens on the all-time range. The all-time Codex Total and
  its API-equivalent Estimate use local retained usage. Identity-bound account
  reports remain separate and never enter local accounting.
  Days, Activity, and date-filtered totals/estimates use local session event
  timestamps grouped from local midnight to the next local midnight in the
  computer's current time zone, including daylight-saving transitions. Provider
  day buckets have no event timestamps and cannot establish that boundary;
  delayed or missing account days must never hide recorded local activity.
  These date-based views cover only history retained on this Mac. Input, Output,
  cache, reasoning, Models, Events, and Files also remain local. `Account` and
  `Local` labels identify the actual source. Refresh rereads changed files;
  per-file aggregates from another or unknown time zone are rebuilt from logs.
- The screen scrolls as a whole and uses the menu's block style. Top row:
  provider chips on the left, 7d/30d/90d/All chips, last scan time and Refresh on
  the right. Then four summary blocks (Total tokens with events and active days;
  Input with uncached/cached/cache writes; Output with reasoning; API estimate
  with price coverage), By provider bars, Models and Days side by side (each
  scrolls itself), Activity, and Provider reports. A partially priced total or
  day shows its known part as `≥ $…`. The day table omits zero-activity dates.
  Activity's day squares may scroll horizontally for long histories and expose
  exact date, tokens, and the known daily estimate. Each month is a distinct
  mini-grid with its label centered over its cells. Before the first anniversary,
  the grid extends with empty future days through the end of the first year
  measured from the first recorded vibecoding day; after it, through the end of
  the current month, opening with that month at the right.
  Provider reports (Codex accounts, Kimi quota windows) are identity-bound and
  never enter the local totals above.
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
  Token values use K with one decimal place or M/B with two decimal
  places, promoting the unit after rounding. Exact detail values retain
  integer precision.
- Statistics resets to its compact `900 × 650 pt` size, centers, and fully
  constrains itself to the visible screen on every open instead of retaining an
  oversized off-center frame. Opening Statistics also closes the menu popover
  so it cannot cover the analytics window.
- API-equivalent estimates use one verified standard-rate catalog over local
  recorded tokens. Unknown prices suppress the full estimate; the known amount
  and recorded-token price coverage remain separate. Remote tokens are never
  extrapolated with local rates. The [statistics contract](docs/contracts/local-statistics.md)
  owns source, migration, completeness and formatting rules.
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
- All windows follow the current macOS light or dark appearance.
- The menu header is one line: a status dot with Active/Paused and ⓘ, then
  Refresh (⌘R) and Options. Below it the tabs Providers, Agents and Processes;
  the Providers tab carries `measured/saved` (for example `1/6`: saved accounts
  with a current limit out of all saved accounts of enabled providers) and the
  Agents tab its session count.
  Sign-in progress and errors add one detail line below it; a manual refresh spins the
  Refresh icon (the 60-second quota poll stays quiet) instead of replacing the status. Options is a native menu:
  Statistics, Settings…, Quit. The menu grows to 80% of the screen's visible
  height, after which only the active tab scrolls (header, tabs and footer never scroll). The menu has no Update command. The footer shows
  `Last refresh` on the left and the version on the right. The legend is not
  permanent: hovering the status indicator shows it as a card over the menu,
  grouping Monitoring, Quota, Access, Marks and Keys under aligned titles.
- The menu is a borderless panel below the menu-bar icon: no arrow, no open or
  close animation, 12 pt corners and the native menu glass on macOS 26+ (menu
  blur with a hairline outline on older systems), matching native menu-bar
  menus. Clicking the icon again closes it. The panel owns the surface; menu content does
  not draw a second background or rounded panel. Outside clicks close it by
  default; General can turn that off so it stays open until Esc, the icon or the
  shortcut. Esc always closes it. Quota availability counts current measurements independently of
  login. Account notes and errors live in the status card's Status section; missing
  limits use ? and gray even when a CLI login is configured. See Accounts for the full contract.
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
- Next-launch provider selection and isolation: `Sources/AIFleet/ProviderTerminalLaunch.swift`
  and [Provider switching](business/provider-switching.md)
- Claude configuration/Keychain selectors: `Sources/AIFleet/ClaudeProfiles.swift`
- Account management inside Settings: `Sources/AIFleet/UI/AccountsSettingsView.swift`
- Refresh preferences: `Sources/AIFleet/AppSettings.swift`
- Claude local accounting and API rates: `Sources/AIFleet/ClaudeUsageAnalytics.swift`
- Kimi and Qwen local accounting: `Sources/AIFleet/ProviderUsageAnalytics.swift`
- Analytics and caches: `Sources/AIFleet/UsageAnalytics.swift`
- User interfaces: `Sources/AIFleet/UI/*`

Warnings and errors replace the menu header's ⓘ with an orange or red
exclamation mark in a circle. The menu-bar Fleet icon also shows a static,
color-matched exclamation mark, including while the menu is closed. Both use
the same current status notes, with errors taking precedence over warnings;
info-only notes do not request attention. Details remain in the existing status
card, with no additional error banner. Resolved process blocking clears after
an authoritative process recheck, without selecting an account automatically.
