# Kimi and Qwen Statistics

Statistics reads retained local accounting history independently of login and
quota monitoring. Each provider has input/cache/output cards, model and daily
tables, periods, and Activity. Days use the computer's time zone, from local
midnight to the next local midnight, including daylight-saving transitions.
Opening Statistics and switching periods or tabs uses cached aggregates;
manual and scheduled refreshes scan metadata and parse only changed files.

## Sources and accounting

- Kimi Code 2.x: `~/.kimi-code/sessions/**/agents/**/wire.jsonl`.
  `context.append_loop_event` records with `event.type = step.end` and usage
  represent completed model requests. Record `time` is Unix milliseconds.
  Count each event UUID once within its file. Track `modelAlias` from
  `profile.bind` and `config.update` in journal order; missing aliases read
  `Unknown model`. Usage input equals `inputOther + inputCacheRead +
  inputCacheCreation`; output is `output`. Ignore observable status snapshots,
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
