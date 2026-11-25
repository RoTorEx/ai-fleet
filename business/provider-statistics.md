# Local provider statistics

The shared [local statistics contract](../docs/contracts/local-statistics.md) owns
provider selection, local/report scope, price coverage, cache revisions and
formatting. Its backend supports Codex, Claude, Kimi and Qwen; design and combined
user acceptance are separate. Only standard roots are in scope.

Statistics reads retained local accounting history independently of login and
quota monitoring. Chosen providers share input/cache/output blocks, model and daily
tables, periods, and Activity. Days use the computer's time zone, from local
midnight to the next local midnight, including daylight-saving transitions.
Statistics shows all chosen providers on one screen. Opening it and switching
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

Open the full charts with the chart button in Statistics or the chart icon on a
supported provider row. The icon previews the charts on hover and keeps them
open on click. The pointer can cross into the popover. Open in Statistics
carries the provider, account, data source and model selection into the same
chart view.

### Provider quota

Weekly history follows the provider's verified account identity and reported
window. A window is weekly when the provider reports a seven-day duration or
explicitly identifies a model-specific weekly cap. The latter has its own
selection and observations. A shorter or undated model quota cannot stand in
for a weekly one.

- Reuse existing quota measurements with their original timestamps. Record
  provider, stable account, window, a digest of the verified identity, reset
  time and used percent. Deduplicate repeated timestamps and keep the latest
  seven days of observations. Seven days covers the active cycle and the
  72-hour histogram across a reset.
- The provider's reset times delimit the cycles. Up to 60 seconds of reset-time
  rounding can identify the same cycle. A passed reset time never implies a
  fresh balance. A decrease within one cycle breaks the plotted series and
  restarts the forecast evidence after the correction.
- The daily budget steps up by one seventh of the weekly limit at the start
  of each 24-hour provider day. Earlier allowance carries forward. Headroom
  is that day's cumulative budget minus the observed usage, in percentage
  points. The shaded region shows headroom or overspend.
- A current sample is at most 15 minutes old. That covers three normal Claude
  or saved Codex refresh intervals and fifteen regular polls. Longer gaps break
  the actual series and cannot establish an hourly distribution.
- After at least one hour of observations in the current cycle, the window
  projection uses cumulative percent divided by elapsed cycle time. The
  second projection uses two observations about 24 hours apart, with the
  earlier observation no more than 15 minutes before the target. Both extend
  to the same reset and show when a projection crosses 100%.
- An hourly bin requires sufficient observation coverage and a single cycle.
  A nonzero change spanning an hour boundary cannot identify the spend in
  either hour. A measured zero and an uncovered hour have distinct treatment.
  The current hour covers the elapsed observed portion. The guide is remaining
  percentage divided by hours left. Old data can still be viewed, and the
  pace and forecast guides require a fresh measurement.

### Local tokens

The separate On this Mac mode uses timestamps from the retained session
records. Its 72 consecutive hour buckets include the current hour and retain
both occurrences of a repeated local hour at daylight-saving transitions.
Choose a provider and recorded model, with an input, cache and output breakdown.
No provider quota or account attribution is inferred from the local totals.
Expired buckets are pruned during the next scan. Unscanned hours are marked
separately from a scanned hour with zero recorded tokens.

`QuotaHistoryTests` covers separate accounts and model windows, deduplication,
freshness, both projections, hourly spikes and gaps, corrections, resets and
the repeated local hour. `WeeklyQuotaPacingTests` covers selection, budget and
reset states.

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
