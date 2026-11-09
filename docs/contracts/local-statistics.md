# Local statistics contract

Stage 4 prepares data for future composition. LocalStatistics and StatisticsCost
are independent of SwiftUI. The compatibility selection and token formatting
helpers live in backend files; existing view layout and controls are retained.

## Scope and selection

The scope is standardLocalRoots on this Mac: native Codex sessions/archive,
Claude projects, current and legacy Kimi sessions and Qwen chats. Fleet-specific
private histories, arbitrary custom homes, remote machines and Gemini accounting
are intentionally excluded. No local account attribution is inferred from paths,
login selection or quota identities.

UsageAnalyticsService.selectedProviders persists independently in
analytics.selectedProviders. Missing preference means all four supported readers;
an empty preference means an intentionally empty selection. Queries accept an
explicit provider set or use this stored selection. Filters apply identically to
local summaries, provider-prefixed model keys, local day rows and report exports.
They do not change menu provider visibility or source caches.

Periods count local calendar days including today. Date boundaries and DST use
the supplied calendar. Snapshots record their timezone; a mismatch marks them
stale and the application lifecycle schedules background reconstruction on a
system-zone change. Opening views and changing filters do not scan files.

Remote lifetime totals, quota windows and provider day buckets never enter local
arithmetic, including All. providerReports exports existing identity-bound account
measurements separately with account ID, identity, fetch time and native usage/
quota scope. Legacy anonymous usage is retained as unattributedAccountUsage;
it is not assigned to the current login. Local scans initiate no remote reads.

## Accounting and prices

Total is Input + Output. Cache read/write counts are subsets of Input; reasoning
is a subset of Output. Each provider retains its native accounting parser and
request-deduplication rules. Structured Codex model precedence is usage model,
event model, current turn context, session metadata, then Unknown model. Prompt
mentions and an assumed default cannot establish a model.

Codex repeated cumulative states do not create requests; a decreasing cumulative
counter begins a new segment. Equal last-usage amounts with different cumulative
states remain distinct. Malformed lines retain usable records and report partial
coverage. Unsupported records do not become guessed usage.

StatisticsCost.fullEstimateUSD exists only for fully priced recorded tokens in a
nonempty, nonstale selection without selected source errors. knownEstimateUSD
retains the priced contribution. pricedTokens / recordedTokens measures price
coverage of recorded Input + Output, not completeness of the real account's
history. Empty volume has no coverage percentage. Unknown rates are unavailable,
not free. Overflow marks an incomplete result rather than wrapping or crashing.

One fixed standard-rate comparison catalog applies across the selected period;
this is neither historical invoicing nor subscription billing. The catalog
revision is 2026-11-09-standard-v3. Exact supported Codex names are GPT-6 Astra,
GPT-6.1 Sol, GPT-6.1 Terra and GPT-6 Luna. Other names remain unpriced rather than
inheriting a similar model. The one exception is the hidden Codex Auto Review
reviewer: it has no published rate and is estimated at GPT-6.1 Sol. Codex write estimates use the standard 30-minute
comparison rate; extended-retention, long-context, fast/batch and platform/tool
premiums are outside this comparison. Claude retains its explicit supported
families, including the per-request Haiku 5.5 price above 100,000 prompt tokens, and recorded 5-minute/1-hour write split. Unsupported legacy Claude
families removed from the verified catalog remain visible without an estimate.

Catalog sources checked 9 November 2026:

- [OpenAI API pricing](https://developers.openai.com/api/docs/pricing)
- [OpenAI prompt caching](https://developers.openai.com/api/docs/guides/prompt-caching)
- [Claude pricing and cache multipliers](https://platform.claude.com/docs/en/about-claude/pricing)

## Discovery, migration and failure

Independent basenames are preserved. Canonical/physical aliases count once.
Validated duplicate Codex session IDs collapse only for identical contents or a
proven byte-prefix continuation; divergent copies are flagged and excluded.
For equal copies the active location wins over archive, then lexical path order.

Parser revision 4, catalog revision and timezone are checked independently of
mtime/size. Missing revisions trigger background rebuild at application startup.
Legacy aggregates are retained separately with unverified prices and are not
silently advertised as corrected. Unavailable source file cache records remain
retained but are excluded from active totals. Partial/unreadable/ambiguous sources
are diagnostic states, not proof of zero account usage.

A cancelled scan cannot publish late progress or totals over a newer scan.
Local refresh merges current report/quota data rather than restoring old copies.
Atomic snapshot/cache writes retain protected permissions. Save failures are
reported as in-memory-only/cache errors, not claimed persisted success. Tests use
injected discovery and temporary cache directories, never real account requests.

## Formatting and book scale

Exact integer strings avoid Double conversion. K uses one decimal, M/B two;
rounding promotes units before producing 1000.0K or 1000.00M. Grouping uses spaces
and the decimal separator is a dot. These formatting policies do not change data.

TokenBookScale returns metric, book title, approximate words and copy count for
Total/Input/Output independently. The existing 15 books and approximate 0.75
English words per token remain unchanged. Zero volume has no book scale. The
future UI owns bold emphasis and hover composition. Repeated cached processing
must not be described as unique reading.

Combined live-data and visual acceptance remains after design. A passing fixture
suite does not establish complete real provider history or a subscription bill.
