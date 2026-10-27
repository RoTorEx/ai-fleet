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
        var files: [String: CodexLogFile] = [:]
        for root in suppliedRoots ?? roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator {
                guard url.pathExtension == "jsonl",
                      self == .kimi ? url.lastPathComponent == "wire.jsonl" : url.pathComponents.contains("chats"),
                      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]),
                      values.isRegularFile == true else { continue }
                // Every Kimi agent uses the same filename; identity is the full path.
                let path = url.resolvingSymlinksInPath().path
                files[path] = CodexLogFile(url: url, modifiedAt: values.contentModificationDate ?? .distantPast, size: values.fileSize ?? 0)
            }
        }
        return files.values.sorted { $0.url.path < $1.url.path }
    }

    func usageRecord(for file: CodexLogFile) -> CodexFileUsageRecord {
        let entries = self == .kimi ? KimiUsageLogReader().readEntries(from: file.url) : QwenUsageLogReader().readEntries(from: file.url)
        let reader = CodexUsageLogReader()
        return CodexFileUsageRecord(
            path: file.url.path, modifiedAt: file.modifiedAt, size: file.size,
            dailyModels: reader.dailyModelUsage(entries: entries), timeZoneIdentifier: reader.calendar.timeZone.identifier
        )
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
    func readEntries(from file: URL) -> [CodexUsageLogEntry] {
        guard let content = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        var entries: [String: CodexUsageLogEntry] = [:]
        for line in content.split(separator: "\n") {
            guard let record = try? decoder.decode(Record.self, from: Data(line.utf8)),
                  record.type == "assistant", let usage = record.usageMetadata,
                  let input = usage.promptTokenCount, let output = usage.candidatesTokenCount,
                  let timestamp = usageDate(record.timestamp) else { continue }
            let totals = unpricedTotals(
                input: input, cached: usage.cachedContentTokenCount ?? 0, writes: 0,
                output: output, reasoning: usage.thoughtsTokenCount ?? 0
            )
            let key = record.uuid
            if let previous = entries[key], previous.totals.totalTokens > totals.totalTokens { continue }
            entries[key] = CodexUsageLogEntry(timestamp: timestamp, model: record.model ?? "Unknown model", totals: totals)
        }
        return entries.values.sorted { $0.timestamp < $1.timestamp }
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
    func readEntries(from file: URL) -> [CodexUsageLogEntry] {
        guard let content = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        var model = "Unknown model"
        var step = ""
        var turn = 0
        var entries: [String: CodexUsageLogEntry] = [:]
        for (index, line) in content.split(separator: "\n").enumerated() {
            guard let record = try? decoder.decode(Record.self, from: Data(line.utf8)) else { continue }
            if record.type == "profile.bind" || record.type == "config.update" {
                if let alias = record.modelAlias { model = alias }
            }
            if record.message?.type == "TurnBegin" { turn += 1 }
            if record.message?.type == "StepBegin" { step = String(record.message?.payload.n ?? index) }
            // Kimi Code 2.x persists each completed request in its context journal.
            // Observable status/turn totals repeat those tokens and are not counted.
            if record.type == "context.append_loop_event", let event = record.event,
               event.type == "step.end", let usage = event.usage, let time = record.time {
                let totals = unpricedTotals(
                    input: max(0, usage.inputOther) + max(0, usage.inputCacheRead ?? 0) + max(0, usage.inputCacheCreation ?? 0),
                    cached: usage.inputCacheRead ?? 0, writes: usage.inputCacheCreation ?? 0, output: usage.output
                )
                entries[event.uuid] = CodexUsageLogEntry(timestamp: Date(timeIntervalSince1970: time / 1000), model: model, totals: totals)
            } else if record.message?.type == "StatusUpdate", let payload = record.message?.payload,
                      let usage = payload.token_usage, let time = record.timestamp {
                // Legacy Python CLI records per-step usage in StatusUpdate envelopes.
                let totals = unpricedTotals(
                    input: max(0, usage.input_other) + max(0, usage.input_cache_read ?? 0) + max(0, usage.input_cache_creation ?? 0),
                    cached: usage.input_cache_read ?? 0, writes: usage.input_cache_creation ?? 0, output: usage.output
                )
                let key = payload.message_id ?? "\(turn)|\(step.isEmpty ? String(index) : step)"
                entries[key] = CodexUsageLogEntry(timestamp: Date(timeIntervalSince1970: time), model: model, totals: totals)
            }
        }
        return entries.values.sorted { $0.timestamp < $1.timestamp }
    }

    private struct Record: Decodable {
        let type: String?
        let time: Double?
        let timestamp: Double?
        let modelAlias: String?
        let event: Step?
        let message: Envelope?
    }
    private struct Step: Decodable {
        let type: String
        let uuid: String
        let usage: Usage?
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

private func usageDate(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
}

private func unpricedTotals(input: Int, cached: Int, writes: Int, output: Int, reasoning: Int = 0) -> UsageTotals {
    var totals = UsageTotals(
        inputTokens: max(0, input), cachedInputTokens: min(max(0, input), max(0, cached)),
        cacheWriteInputTokens: min(max(0, input - max(0, cached)), max(0, writes)),
        outputTokens: max(0, output), reasoningOutputTokens: min(max(0, output), max(0, reasoning)), estimatedCostUSD: 0
    )
    totals.costEstimateAvailable = false
    return totals
}
