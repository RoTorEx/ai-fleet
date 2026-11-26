# Local provider statistics

The shared [local statistics contract](../docs/contracts/local-statistics.md) owns
provider selection, local/report scope, price coverage, cache revisions and
formatting. Its backend supports Codex, Claude, Kimi and Qwen; design and combined
user acceptance are separate. Only standard roots are in scope.

Statistics reads retained local accounting history independently of login and
quota monitoring. Chosen providers share input/cache/output blocks, model and daily
tables, periods, and Activity. Days use the computer's time zone, from local
midnight to the next local midnight, including daylight-saving transitions.
Token Spend places the four summary cards above the compact By provider,
Models and Days row and Activity. By provider shows recorded tokens, the
API estimate and each provider's share of the selection's token total. Quota
History uses the same provider chips. Opening Statistics and switching tabs,
periods or provider chips uses cached aggregates;
manual and scheduled refreshes scan metadata and parse only changed files.

## Sources and accounting

- Kimi Code 2.x: `~/.kimi-code/sessions/**/agents/**/wire.jsonl`.
  `context.append_loop_event` records with `event.type = step.end` and usage
  represent completed model requests. Record `time` is Unix milliseconds.
  Count each event UUID once within its file. Track `modelAlias` from
  `profile.bind` and `config.update` in journal order; missing aliases read
  `Unknown model`. Usage input equals `inputOther + inputCacheRead +
  inputCacheCreation`; output is `output`. Check the event type before decoding
  usage and its UUID. Tool results can omit that UUID. Ignore observable status snapshots,
  turn/subagent summaries and context messages to prevent double counting.
- Legacy Kimi CLI: `~/.kimi/sessions/**/wire.jsonl` (also accepted under the
  current session root). Read timestamped `StatusUpdate` envelopes with
  `token_usage`, using Unix seconds. Deduplicate by message ID or turn/step.
  Input includes `input_other`, `input_cache_read`, and `input_cache_creation`.
  Context-usage percentages alone are not token accounting. Parent-wrapped
  subagent events are ignored; independently persisted agent wires are read.
- Qwen Code: `~/.qwen/projects/*/chats/**/*.jsonl`. Read assistant records with
  UUID, ISO timestamp, model and `usageMetadata`. Count each UUID once within
  its file, retaining the most complete sample. `promptTokenCount` already
  includes `cachedContentTokenCount`. `candidatesTokenCount` is output;
  `thoughtsTokenCount` is a recorded subset and is never added to output.
  The CLI may estimate thoughts; AI Fleet does not infer additional reasoning.
  Records without input/output breakdowns are skipped rather than inventing one.

Full paths identify files: every Kimi agent has the same `wire.jsonl` filename.
Do not deduplicate these by basename. Overlapping discovery roots resolve to
one physical file. Provider histories are separated before aggregation; they
must never enter Codex totals. New optional snapshot fields preserve older
Codex/Claude snapshots and the separate Kimi quota snapshot. Snapshot updates
for account usage or quota state preserve all provider histories.

Malformed or partial records are skipped. Negative counts are clamped to zero;
cache and reasoning subsets cannot exceed their parent totals. No prompts,
message content, tool results or credentials enter the aggregate cache.
Options → Logs shows the last scan time and groups source diagnostics by
provider. Statistics shows the resulting usage and quota data.
Default local paths are supported; remote account history, custom CLI data
homes, Qwen legacy JSON snapshots and managed transcript formats are outside
this reader. Absence of usable records means no recorded local usage, not proof
of no account usage. Unknown model names remain visible without guessed rates.

## Costs and quotas

Kimi and Qwen token prices are unconfigured. The headline, model and daily cost
estimates show unavailable, never a fabricated charge or a claim of free usage.
Kimi quotas remain an independent account measurement. Their summary and detail
popover retain remaining percent, used/limit counts and reset times, independent
of local token periods. Empty quota state is unavailable. Qwen quota polling
remains unsupported; local history does not establish subscription availability.

## Quota history

Click the chart icon on a supported provider row to open the compact popover.
Click the icon again to close it. Selecting a different provider in the same
menu updates the open popover and moves its pointer to the selected button.
The popover appears after measuring its content and stays aligned to the menu
where the pointer fits. The quota overview, hourly quota and local
hourly tokens form one compact stack in the popover and at the top of Quota
History in Statistics. Provider reports follow the chart group. Claude, Codex
and Kimi share the layout. The Statistics account picker keeps the quota
readings and all three chart positions stable when quota data is missing.
Qwen shows unavailable quota states in those slots and opens only its local
token chart in the compact popover.
Reported quota windows show their current percentages together. The charts use
the account-wide weekly limit when present, followed by the longest account
window. Open in Statistics carries the provider, account and local model
and category selection and includes the provider in the visible filter. The plots use a shared axis gutter and fixed heights so changing the
window width keeps all three charts in view at the default Statistics size.
Label sizes stay constant. Both hourly plots share a 3-, 4-, or 7-day range.
The 3-day default preserves the initial view. The plot dimensions stay fixed
as the one-hour bins become denser. The six-hour grid follows local midnight,
with dates on a separate row and abbreviated labels when space is limited.
The charts use the current macOS light or dark appearance. The highest
tick names the plot ceiling. Hourly quota uses a 1.0% ceiling until a measured
bin exceeds it. An off-scale sustainable rate appears in the legend. Charts
keep the zero baseline and omit its label. Hover over the info icon next to a chart's title to see its legend
inside the plot. The menu popover points at the clicked chart button, resizes
to the content and scrolls when the charts exceed the display's available height.

Use the device calendar and current time zone for hourly bins and date labels.
Hover and reset readouts name that zone. The local token chart stacks uncached
input, cache reads and writes, and output in distinct colors. Hover shows each
exact count. Select one category to inspect it on a scale fitted to its own values.

The main menu reports remaining quota. The chart labels the used percentage,
calculated as 100 minus remaining. A current-only limit uses the reading from
the selected Providers row, marks stale readings and labels unavailable hourly
history. Kimi's 5h and monthly windows use this state. Weekly history and
forecasts require a verified weekly window with the corresponding inputs.

### Provider quota

Weekly history follows the provider's verified account identity and reported
window. A window is weekly when the provider reports a seven-day duration or
explicitly identifies a model-specific weekly cap. Model caps retain independent
observations and appear among the current readings. A shorter or undated model
quota cannot stand in for an account's weekly one.

- Reuse existing quota measurements with their original timestamps. Record
  provider, stable account, window, a digest of the verified identity, reset
  time and used percent. Deduplicate repeated timestamps. Keep saved
  observations across resets without an age limit in
  `~/Library/Application Support/AI Fleet/weekly-quota-history.json`.
  The overview opens on the latest cycle. Its arrows visit saved cycles for
  the same provider, account, and quota window. Historical views show the
  usage recorded in that cycle. The two hourly charts remain on the selected
  recent range. Provider replies supply the current measurement and quota
  history starts at the first saved observation.
- The provider's reset times delimit the cycles. Up to 60 seconds of reset-time
  rounding can identify the same cycle. A passed reset time never implies a
  fresh balance. A decrease within one cycle breaks the plotted series and
  restarts the forecast evidence after the correction.
- The daily budget steps up by one seventh of the weekly limit at the start
  of each 24-hour provider day. Earlier allowance carries forward. Headroom
  is that day's cumulative budget minus the observed usage, in percentage
  points. The blue steps show reported cumulative use. The gray steps show
  cumulative budget, with green fill for spare budget and red fill for
  over-budget use where there are observations.
- A current sample is at most 15 minutes old. That covers three normal Claude
  or saved Codex refresh intervals and fifteen regular polls. Longer gaps break
  the actual series and cannot establish an hourly distribution.
- Once one hour of the cycle has elapsed, the window projection uses the
  reported cumulative percent divided by elapsed cycle time. After a downward
  correction it waits for an hour of observations. The second projection uses
  two observations about 24 hours apart, with the earlier observation no more
  than 15 minutes before the target. Keep the weekly chart on a fixed percentage
  scale with the 100% limit at its top edge. A hover shows the observed use or
  each available forecast at that time, along with the budget. The gold
  forecast uses the cycle average and the coral forecast uses the last 24
  hours. Complementary dash patterns preserve both colors when the paths
  coincide. Each ends at reset or at the projected limit crossing, whichever
  comes first. The legend identifies the history needed for an unavailable
  forecast while the latest reading is fresh.
- An hourly bin requires sufficient observation coverage and a single cycle.
  A nonzero change spanning an hour boundary cannot identify the spend in
  either hour. A measured zero and an uncovered hour have distinct treatment.
  When observation starts mid-hour, any measured increase within that first
  hour appears as a partial bar. The current hour covers the elapsed observed
  portion. The mint bars show measured hourly changes. Show when observations
  started if the log covers only part of the selected range. The dashed amber
  guide is remaining quota divided by hours to reset. Old data can still be
  viewed, and the pace and forecast guides require a fresh measurement.

### Local tokens

The On this Mac section uses timestamps from the retained session records.
Its consecutive hour buckets include the current hour and retain
both occurrences of a repeated local hour at daylight-saving transitions.
Choose a provider and recorded model, with an input, cache and output breakdown.
No provider quota or account attribution is inferred from the local totals.
The cache aggregates up to seven days of hourly token events from local session
logs. The next scan rebuilds older three-day cache entries that can contribute
to that range. Unscanned hours stay distinct from scanned hours with zero
recorded tokens.

`QuotaHistoryTests` covers native cap and hourly mark geometry, separate
accounts and model windows, deduplication, freshness, projections, spikes,
gaps, corrections, resets and the repeated local hour.
`WeeklyQuotaPacingTests` covers selection, budget and reset states.

## Evidence and checks

The installed Kimi Code 2.1.1 package supplies the current journal contract:
`packages/agent-core-v2/src/agent/loop`, wire records and profile operations in
its bundled `dist/main.mjs`. Upstream references:

- [Kimi session storage](https://github.com/MoonshotAI/kimi-code/blob/main/docs/en/guides/sessions.md)
- [Legacy Kimi wire records](https://github.com/MoonshotAI/kimi-cli/blob/main/src/kimi_cli/wire/file.py)
- [Legacy Kimi usage fields](https://github.com/MoonshotAI/kimi-cli/blob/main/packages/kosong/src/kosong/chat_provider/__init__.py)
- [Qwen recording contract](https://github.com/QwenLM/qwen-code/blob/main/packages/core/src/services/chatRecordingService.ts)
- [Qwen storage paths](https://github.com/QwenLM/qwen-code/blob/main/packages/core/src/config/storage.ts)
- [Qwen usage conversion](https://github.com/QwenLM/qwen-code/blob/main/packages/core/src/core/openaiContentGenerator/converter.ts)

`ProviderUsageAnalyticsTests` protects request deduplication, cache/reasoning
subsets, model changes, local midnight, malformed records, nested discovery,
provider separation, aggregate-cache reuse and backward-compatible snapshots.
Run `make check` for these and existing provider checks. On a machine without
retained Kimi/Qwen logs, fixtures establish parser behavior; real usage totals
cannot be verified until a CLI has written accounting records.
