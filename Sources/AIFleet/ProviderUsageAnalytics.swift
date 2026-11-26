import Foundation

enum LocalUsageProvider: String, CaseIterable {
    case kimi, qwen

    var source: String {
        self == .kimi ? "~/.kimi-code/sessions + ~/.kimi/sessions" : "~/.qwen/projects/*/chats"
    }

    var roots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .kimi: return [home.appendingPathComponent(".kimi-code/sessions"), home.appendingPathComponent(".kimi/sessions")]
        case .qwen: return [home.appendingPathComponent(".qwen/projects")]
        }
    }

    func contains(_ url: URL) -> Bool {
        roots.contains { url.standardizedFileURL.path.hasPrefix($0.standardizedFileURL.path + "/") }
    }

    func logFileMetadata(roots suppliedRoots: [URL]? = nil) -> [CodexLogFile] {
        let files = discoverUsageLogs(in: suppliedRoots ?? roots) { url in
            self == .kimi ? url.lastPathComponent == "wire.jsonl" : url.pathComponents.contains("chats")
        }
        return canonicalUsageFiles(files, codexCopies: false)
    }

    func usageRecord(for file: CodexLogFile, checkpoint: UsageJournalCheckpoint? = nil,
                     saveCheckpoint: Bool = false) -> CodexFileUsageRecord {
        let provider: StatisticsProvider = self == .kimi ? .kimi : .qwen
        let parsed = self == .kimi
            ? KimiUsageLogReader().parseEntries(from: file.url, checkpoint: checkpoint, saveCheckpoint: saveCheckpoint)
            : QwenUsageLogReader().parseEntries(from: file.url, checkpoint: checkpoint, saveCheckpoint: saveCheckpoint)
        return CodexUsageLogReader().usageRecord(for: file, provider: provider, parsed: parsed)
    }

    func analytics(from records: [CodexFileUsageRecord]) -> CodexUsageAnalytics {
        var result = CodexUsageLogReader().analytics(from: records, fileCount: records.count)
        result.source = source
        // A missing price is unavailable, including before the first recorded request.
        result.total.costEstimateAvailable = false
        return result
    }
}

/// Reads only accounting fields. Prompts and tool results are never retained.
struct QwenUsageLogReader {
    func readEntries(from file: URL) -> [CodexUsageLogEntry] { parseEntries(from: file).entries }
    func parseEntries(from file: URL, checkpoint: UsageJournalCheckpoint? = nil,
                      saveCheckpoint: Bool = false) -> ParsedUsageJournal {
        let decoder = JSONDecoder()
        let timestamps = UsageJournalTimestamps()
        return readUsageJournal(file, checkpoint: checkpoint, saveCheckpoint: saveCheckpoint) { state, line, _ in
            guard let record = try? decoder.decode(Record.self, from: line) else {
                state.partial = state.partial || malformedAccountingLine(line, kinds: ["assistant"]); return
            }
            guard record.type == "assistant", let usage = record.usageMetadata,
                  let input = usage.promptTokenCount, let output = usage.candidatesTokenCount,
                  let timestamp = timestamps.date(from: record.timestamp) else { return }
            let totals = unpricedTotals(
                input: input, cached: usage.cachedContentTokenCount ?? 0, writes: 0,
                output: output, reasoning: usage.thoughtsTokenCount ?? 0
            )
            let key = record.uuid
            if let previous = state.keyedEntries[key], previous.totals.totalTokens > totals.totalTokens { return }
            state.keyedEntries[key] = CodexUsageLogEntry(timestamp: timestamp, model: record.model ?? "Unknown model", totals: totals)
        }
    }

    private struct Record: Decodable {
        let type: String
        let uuid: String
        let timestamp: String
        let model: String?
        let usageMetadata: Usage?
    }
    private struct Usage: Decodable {
        let promptTokenCount: Int?
        let candidatesTokenCount: Int?
        let cachedContentTokenCount: Int?
        let thoughtsTokenCount: Int?
    }
}

struct KimiUsageLogReader {
    func readEntries(from file: URL) -> [CodexUsageLogEntry] { parseEntries(from: file).entries }
    func parseEntries(from file: URL, checkpoint: UsageJournalCheckpoint? = nil,
                      saveCheckpoint: Bool = false) -> ParsedUsageJournal {
        let decoder = JSONDecoder()
        return readUsageJournal(file, checkpoint: checkpoint, saveCheckpoint: saveCheckpoint) { state, line, index in
            guard let record = try? decoder.decode(Record.self, from: line) else {
                state.partial = state.partial || malformedAccountingLine(line, kinds: ["context.append_loop_event", "StatusUpdate"]); return
            }
            if record.type == "profile.bind" || record.type == "config.update" {
                if let alias = record.modelAlias { state.model = alias }
            }
            if record.message?.type == "TurnBegin" { state.legacyTurn += 1 }
            if record.message?.type == "StepBegin" { state.legacyStep = String(record.message?.payload.n ?? index) }
            // Kimi Code 2.x persists each completed request in its context journal.
            // Observable status/turn totals repeat those tokens and are not counted.
            if record.type == "context.append_loop_event", case let .accounting(uuid, usage)? = record.event {
                guard let time = record.time else {
                    state.partial = true
                    return
                }
                let combined = checkedStatisticsSum([usage.inputOther, usage.inputCacheRead ?? 0, usage.inputCacheCreation ?? 0])
                var totals = unpricedTotals(
                    input: combined ?? 0,
                    cached: usage.inputCacheRead ?? 0, writes: usage.inputCacheCreation ?? 0, output: usage.output
                )
                if combined == nil { totals.overflowDetected = true }
                state.keyedEntries[uuid] = CodexUsageLogEntry(timestamp: Date(timeIntervalSince1970: time / 1000),
                                                             model: state.model, totals: totals)
            } else if record.message?.type == "StatusUpdate", let payload = record.message?.payload,
                      let usage = payload.token_usage, let time = record.timestamp {
                // Legacy Python CLI records per-step usage in StatusUpdate envelopes.
                let combined = checkedStatisticsSum([usage.input_other, usage.input_cache_read ?? 0, usage.input_cache_creation ?? 0])
                var totals = unpricedTotals(
                    input: combined ?? 0,
                    cached: usage.input_cache_read ?? 0, writes: usage.input_cache_creation ?? 0, output: usage.output
                )
                if combined == nil { totals.overflowDetected = true }
                let step = state.legacyStep.isEmpty ? String(index) : state.legacyStep
                let key = payload.message_id ?? "\(state.legacyTurn)|\(step)"
                state.keyedEntries[key] = CodexUsageLogEntry(timestamp: Date(timeIntervalSince1970: time),
                                                            model: state.model, totals: totals)
            }
        }
    }

    private struct Record: Decodable {
        let type: String?
        let time: Double?
        let timestamp: Double?
        let modelAlias: String?
        let event: Step?
        let message: Envelope?
    }
    private enum Step: Decodable {
        case accounting(uuid: String, usage: Usage)
        case ignored

        private enum CodingKeys: String, CodingKey { case type, uuid, usage }

        init(from decoder: Decoder) throws {
            let event = try decoder.container(keyedBy: CodingKeys.self)
            // Tool results can have a tool-call ID and no event UUID.
            guard try event.decode(String.self, forKey: .type) == "step.end",
                  let usage = try event.decodeIfPresent(Usage.self, forKey: .usage) else {
                self = .ignored
                return
            }
            self = .accounting(uuid: try event.decode(String.self, forKey: .uuid), usage: usage)
        }
    }
    private struct Usage: Decodable {
        let inputOther: Int
        let output: Int
        let inputCacheRead: Int?
        let inputCacheCreation: Int?
    }
    private struct Envelope: Decodable {
        let type: String
        let payload: Payload
    }
    private struct Payload: Decodable {
        let n: Int?
        let message_id: String?
        let token_usage: LegacyUsage?
    }
    private struct LegacyUsage: Decodable {
        let input_other: Int
        let output: Int
        let input_cache_read: Int?
        let input_cache_creation: Int?
    }
}

private func unpricedTotals(input: Int, cached: Int, writes: Int, output: Int, reasoning: Int = 0) -> UsageTotals {
    var totals = UsageTotals(
        inputTokens: max(0, input), cachedInputTokens: min(max(0, input), max(0, cached)),
        cacheWriteInputTokens: min(max(0, input - max(0, cached)), max(0, writes)),
        outputTokens: max(0, output), reasoningOutputTokens: min(max(0, output), max(0, reasoning)), estimatedCostUSD: 0
    )
    totals.costEstimateAvailable = false
    totals.overflowDetected = max(0, input).addingReportingOverflow(max(0, output)).overflow
    return totals
}
