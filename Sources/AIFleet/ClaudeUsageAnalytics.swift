import Foundation

/// Reads accounting metadata only; message content is neither decoded nor cached.
struct ClaudeUsageLogReader {
    static var projectsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    }

    static func isClaudeLog(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(projectsURL.standardizedFileURL.path + "/")
    }

    func logFileMetadata(root: URL = Self.projectsURL) -> [CodexLogFile] {
        // Includes nested subagent transcripts. Discovery deduplicates moved files by name.
        CodexUsageLogReader().codexLogFileMetadata(roots: [root])
    }

    func usageRecord(for file: CodexLogFile) -> CodexFileUsageRecord {
        CodexFileUsageRecord(
            path: file.url.path, modifiedAt: file.modifiedAt, size: file.size,
            dailyModels: CodexUsageLogReader().dailyModelUsage(entries: readEntries(from: file.url)),
            timeZoneIdentifier: TimeZone.autoupdatingCurrent.identifier
        )
    }

    func readEntries(from file: URL) -> [CodexUsageLogEntry] {
        guard let content = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        let formatter = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var entries: [String: CodexUsageLogEntry] = [:]
        for line in content.split(separator: "\n") {
            guard let event = try? decoder.decode(Event.self, from: Data(line.utf8)),
                  event.type == "assistant", let message = event.message,
                  let usage = message.usage, let model = message.model, model != "<synthetic>",
                  let id = message.id ?? event.uuid,
                  let timestamp = event.timestamp.flatMap({ fractional.date(from: $0) ?? formatter.date(from: $0) })
            else { continue }

            let cached = max(0, usage.cache_read_input_tokens ?? 0)
            let writes = max(0, usage.cache_creation_input_tokens ?? 0)
            let uncached = max(0, usage.input_tokens ?? 0)
            let output = max(0, usage.output_tokens ?? 0)
            let oneHour = min(writes, max(0, usage.cache_creation?.ephemeral_1h_input_tokens ?? 0))
            let rates = ClaudeAPIRates.rates(for: model)
            var totals = UsageTotals(
                inputTokens: uncached + cached + writes,
                cachedInputTokens: cached, cacheWriteInputTokens: writes,
                outputTokens: output,
                reasoningOutputTokens: min(output, max(0, usage.output_tokens_details?.thinking_tokens ?? 0)),
                estimatedCostUSD: 0
            )
            totals.costEstimateAvailable = rates != nil
            if let rates {
                totals.estimatedCostUSD = (
                    Double(uncached) * rates.input + Double(cached) * rates.cached +
                    Double(writes - oneHour) * rates.input * 1.25 +
                    Double(oneHour) * rates.input * 2 + Double(output) * rates.output
                ) / 1_000_000
            }
            // Claude writes one message for each content block with repeated usage.
            // Keep the most complete usage sample for the API message, once.
            let key = "\(event.requestId ?? "")|\(id)"
            if let previous = entries[key], previous.totals.totalTokens > totals.totalTokens { continue }
            entries[key] = CodexUsageLogEntry(timestamp: timestamp, model: model, totals: totals)
        }
        return entries.values.sorted { $0.timestamp < $1.timestamp }
    }

    private struct Event: Decodable {
        let type: String
        let timestamp: String?
        let uuid: String?
        let requestId: String?
        let message: Message?
    }

    private struct Message: Decodable {
        let id: String?
        let model: String?
        let usage: Usage?
    }

    private struct Usage: Decodable {
        let input_tokens: Int?
        let cache_read_input_tokens: Int?
        let cache_creation_input_tokens: Int?
        let output_tokens: Int?
        let cache_creation: CacheCreation?
        let output_tokens_details: OutputDetails?
    }

    private struct CacheCreation: Decodable { let ephemeral_1h_input_tokens: Int? }
    private struct OutputDetails: Decodable { let thinking_tokens: Int? }
}

enum ClaudeAPIRates {
    struct Rates {
        let input: Double
        let output: Double
        let cached: Double
    }

    /// Standard USD per million tokens; excludes tools, fast mode and platform premiums.
    /// Source: https://platform.claude.com/docs/en/about-claude/pricing
    static func rates(for model: String) -> Rates? {
        let model = model.lowercased()
        let families: [(String, Double, Double, Double)] = [
            ("claude-opus-5-5", 4, 20, 0.20),
            ("claude-sonnet-5-5", 2, 10, 0.10),
            ("claude-opus-4-5", 5, 25, 0.50),
            ("claude-opus-4-6", 5, 25, 0.50),
            ("claude-opus-4-7", 5, 25, 0.50),
            ("claude-opus-4-8", 5, 25, 0.50),
            ("claude-opus-5", 5, 25, 0.50),
            ("claude-opus-4-1", 15, 75, 1.50),
            ("claude-opus-4", 15, 75, 1.50),
            ("claude-sonnet-4-6", 3, 15, 0.30),
            ("claude-sonnet-4-5", 3, 15, 0.30),
            ("claude-sonnet-4", 3, 15, 0.30),
            ("claude-sonnet-5", 2, 10, 0.20),
            ("claude-haiku-4-5", 1, 5, 0.10),
            ("claude-3-5-haiku", 0.80, 4, 0.08),
            ("claude-3-7-sonnet", 3, 15, 0.30),
            ("claude-3-5-sonnet", 3, 15, 0.30),
            ("claude-3-opus", 15, 75, 1.50)
        ]
        guard let match = families.first(where: {
            model == $0.0 || (model.hasPrefix($0.0 + "-") && model.dropFirst($0.0.count + 1).count == 8 && model.suffix(8).allSatisfy(\.isNumber))
        }) else { return nil }
        return Rates(input: match.1, output: match.2, cached: match.3)
    }
}
