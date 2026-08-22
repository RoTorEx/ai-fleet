import Foundation

struct UsageAnalyticsSnapshot: Equatable {
    var codex: CodexUsageAnalytics
    var kimi: KimiQuotaAnalytics
    var refreshedAt: Date?

    static let empty = UsageAnalyticsSnapshot(
        codex: .empty,
        kimi: .empty,
        refreshedAt: nil
    )
}

struct CodexUsageAnalytics: Equatable {
    var total: UsageTotals
    var today: UsageTotals
    var sevenDays: UsageTotals
    var thirtyDays: UsageTotals
    var daily: [DailyUsage]
    var models: [ModelUsage]
    var eventCount: Int
    var fileCount: Int
    var source: String

    static let empty = CodexUsageAnalytics(
        total: .zero,
        today: .zero,
        sevenDays: .zero,
        thirtyDays: .zero,
        daily: [],
        models: [],
        eventCount: 0,
        fileCount: 0,
        source: "~/.codex/sessions"
    )
}

struct KimiQuotaAnalytics: Equatable {
    var windows: [KimiQuotaWindow]
    var source: String

    static let empty = KimiQuotaAnalytics(windows: [], source: "Kimi quota API")
}

struct KimiQuotaWindow: Identifiable, Equatable {
    let id: String
    let label: String
    let remainingPercent: Int
    let used: Int?
    let limit: Int?
    let resetAt: Date?
}

struct DailyUsage: Identifiable, Equatable {
    let day: Date
    var totals: UsageTotals

    var id: Date { day }
}

struct ModelUsage: Identifiable, Equatable {
    let model: String
    var totals: UsageTotals
    var events: Int

    var id: String { model }
}

struct UsageTotals: Equatable {
    var inputTokens: Int
    var cachedInputTokens: Int
    var cacheWriteInputTokens: Int
    var outputTokens: Int
    var reasoningOutputTokens: Int
    var estimatedCostUSD: Double

    static let zero = UsageTotals(
        inputTokens: 0,
        cachedInputTokens: 0,
        cacheWriteInputTokens: 0,
        outputTokens: 0,
        reasoningOutputTokens: 0,
        estimatedCostUSD: 0
    )

    var totalTokens: Int {
        inputTokens + outputTokens
    }

    var billableInputTokens: Int {
        max(0, inputTokens - cachedInputTokens - cacheWriteInputTokens)
    }

    mutating func add(_ other: UsageTotals) {
        inputTokens += other.inputTokens
        cachedInputTokens += other.cachedInputTokens
        cacheWriteInputTokens += other.cacheWriteInputTokens
        outputTokens += other.outputTokens
        reasoningOutputTokens += other.reasoningOutputTokens
        estimatedCostUSD += other.estimatedCostUSD
    }
}

@MainActor
final class UsageAnalyticsService: ObservableObject {
    static let shared = UsageAnalyticsService()

    @Published private(set) var snapshot = UsageAnalyticsSnapshot.empty
    @Published private(set) var isRefreshing = false

    private var task: Task<Void, Never>?

    private init() {}

    func refresh(kimi: ProviderStatus) {
        task?.cancel()
        isRefreshing = true

        let kimiAnalytics = Self.kimiAnalytics(from: kimi.limitWindows)
        snapshot = UsageAnalyticsSnapshot(
            codex: snapshot.codex,
            kimi: kimiAnalytics,
            refreshedAt: snapshot.refreshedAt
        )

        task = Task { [weak self] in
            let codex = await Task.detached(priority: .utility) {
                CodexUsageLogReader().read()
            }.value

            guard !Task.isCancelled else { return }
            self?.snapshot = UsageAnalyticsSnapshot(
                codex: codex,
                kimi: kimiAnalytics,
                refreshedAt: Date()
            )
            self?.isRefreshing = false
        }
    }

    private static func kimiAnalytics(from windows: [ProviderLimitWindow]) -> KimiQuotaAnalytics {
        KimiQuotaAnalytics(
            windows: windows.map { window in
                KimiQuotaWindow(
                    id: window.id,
                    label: window.label,
                    remainingPercent: window.remainingPercent,
                    used: window.usedCount,
                    limit: window.limitCount,
                    resetAt: window.resetAt
                )
            },
            source: "Kimi quota API"
        )
    }
}

private struct CodexUsageLogReader {
    private struct Entry {
        let timestamp: Date
        let model: String
        let totals: UsageTotals
    }

    private let calendar = Calendar.autoupdatingCurrent
    private let iso8601 = ISO8601DateFormatter()

    func read() -> CodexUsageAnalytics {
        let files = codexLogFiles()
        var entries: [Entry] = []

        for file in files {
            entries.append(contentsOf: readEntries(from: file))
        }

        let now = Date()
        let todayStart = calendar.startOfDay(for: now)
        let sevenDaysStart = calendar.date(byAdding: .day, value: -6, to: todayStart) ?? todayStart
        let thirtyDaysStart = calendar.date(byAdding: .day, value: -29, to: todayStart) ?? todayStart

        let total = totals(for: entries)
        let today = totals(for: entries.filter { $0.timestamp >= todayStart })
        let sevenDays = totals(for: entries.filter { $0.timestamp >= sevenDaysStart })
        let thirtyDays = totals(for: entries.filter { $0.timestamp >= thirtyDaysStart })

        return CodexUsageAnalytics(
            total: total,
            today: today,
            sevenDays: sevenDays,
            thirtyDays: thirtyDays,
            daily: dailyUsage(entries: entries, start: thirtyDaysStart, days: 30),
            models: modelUsage(entries: entries),
            eventCount: entries.count,
            fileCount: files.count,
            source: "~/.codex/sessions"
        )
    }

    private func codexLogFiles() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = [
            home.appendingPathComponent(".codex/sessions")
        ]

        var files: [URL] = []
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for item in enumerator {
                guard let url = item as? URL,
                      url.pathExtension == "jsonl",
                      (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                    continue
                }
                files.append(url)
            }
        }
        return files
    }

    private func readEntries(from file: URL) -> [Entry] {
        guard let content = try? String(contentsOf: file, encoding: .utf8) else {
            return []
        }

        var entries: [Entry] = []
        var sessionModel = "gpt-5.6-sol"

        for line in content.split(whereSeparator: \.isNewline) {
            let text = String(line)
            if let model = knownModel(in: text) {
                sessionModel = model
            }

            guard text.contains("\"last_token_usage\""),
                  let timestamp = timestamp(in: text),
                  let usageStart = text.range(of: "\"last_token_usage\"")?.lowerBound else {
                continue
            }

            let usageText = String(text[usageStart...])
            let input = intValue("input_tokens", in: usageText)
            let cached = intValue("cached_input_tokens", in: usageText)
            let cacheWrite = intValue("cache_write_input_tokens", in: usageText)
            let output = intValue("output_tokens", in: usageText)
            let reasoning = intValue("reasoning_output_tokens", in: usageText)
            let totals = usageTotals(
                model: sessionModel,
                input: input,
                cached: cached,
                cacheWrite: cacheWrite,
                output: output,
                reasoning: reasoning
            )

            entries.append(Entry(timestamp: timestamp, model: sessionModel, totals: totals))
        }

        return entries
    }

    private func timestamp(in text: String) -> Date? {
        guard let range = text.range(of: "\"timestamp\"") else { return nil }
        let rest = text[range.upperBound...]
        guard let firstQuote = rest.firstIndex(of: "\"") else { return nil }
        let afterFirstQuote = rest.index(after: firstQuote)
        guard let secondQuote = rest[afterFirstQuote...].firstIndex(of: "\"") else { return nil }
        return iso8601.date(from: String(rest[afterFirstQuote..<secondQuote]))
    }

    private func intValue(_ key: String, in text: String) -> Int {
        guard let keyRange = text.range(of: "\"\(key)\"") else {
            return 0
        }

        let afterKey = text[keyRange.upperBound...]
        guard let colon = afterKey.firstIndex(of: ":") else {
            return 0
        }

        var index = text.index(after: colon)
        while index < text.endIndex, text[index].isWhitespace {
            index = text.index(after: index)
        }

        let start = index
        while index < text.endIndex, text[index].isNumber {
            index = text.index(after: index)
        }

        guard start < index else { return 0 }
        return Int(text[start..<index]) ?? 0
    }

    private func knownModel(in text: String) -> String? {
        let knownModels = [
            "gpt-5.6-sol",
            "gpt-5.6-terra",
            "gpt-5.6-luna",
            "gpt-5.5-cyber",
            "gpt-5.5",
            "gpt-5.4-mini",
            "gpt-5.4",
            "gpt-5.3-codex",
            "gpt-5.2"
        ]
        let lowercased = text.lowercased()
        return knownModels.first { lowercased.contains($0) }
    }

    private func usageTotals(
        model: String,
        input: Int,
        cached: Int,
        cacheWrite: Int,
        output: Int,
        reasoning: Int
    ) -> UsageTotals {
        var totals = UsageTotals(
            inputTokens: input,
            cachedInputTokens: cached,
            cacheWriteInputTokens: cacheWrite,
            outputTokens: output,
            reasoningOutputTokens: reasoning,
            estimatedCostUSD: 0
        )
        let rates = CodexAPIRates.rates(for: model)
        totals.estimatedCostUSD =
            Double(totals.billableInputTokens) / 1_000_000 * rates.input +
            Double(cached) / 1_000_000 * rates.cachedInput +
            Double(cacheWrite) / 1_000_000 * rates.cacheWrite +
            Double(output) / 1_000_000 * rates.output
        return totals
    }

    private func totals(for entries: [Entry]) -> UsageTotals {
        entries.reduce(into: .zero) { partial, entry in
            partial.add(entry.totals)
        }
    }

    private func dailyUsage(entries: [Entry], start: Date, days: Int) -> [DailyUsage] {
        var buckets: [Date: UsageTotals] = [:]
        for offset in 0..<days {
            if let day = calendar.date(byAdding: .day, value: offset, to: start) {
                buckets[day] = .zero
            }
        }

        for entry in entries where entry.timestamp >= start {
            let day = calendar.startOfDay(for: entry.timestamp)
            buckets[day, default: .zero].add(entry.totals)
        }

        return buckets.keys.sorted().map { day in
            DailyUsage(day: day, totals: buckets[day] ?? .zero)
        }
    }

    private func modelUsage(entries: [Entry]) -> [ModelUsage] {
        var buckets: [String: ModelUsage] = [:]
        for entry in entries {
            if buckets[entry.model] == nil {
                buckets[entry.model] = ModelUsage(model: entry.model, totals: .zero, events: 0)
            }
            buckets[entry.model]?.totals.add(entry.totals)
            buckets[entry.model]?.events += 1
        }

        return buckets.values.sorted {
            if $0.totals.estimatedCostUSD != $1.totals.estimatedCostUSD {
                return $0.totals.estimatedCostUSD > $1.totals.estimatedCostUSD
            }
            return $0.totals.totalTokens > $1.totals.totalTokens
        }
    }
}

private enum CodexAPIRates {
    struct Rates {
        let input: Double
        let cachedInput: Double
        let cacheWrite: Double
        let output: Double
    }

    static func rates(for model: String) -> Rates {
        let normalized = model.lowercased()
        if normalized.contains("gpt-5.6-terra") {
            return Rates(input: 2.50, cachedInput: 0.25, cacheWrite: 3.125, output: 15.00)
        }
        if normalized.contains("gpt-5.6-luna") {
            return Rates(input: 1.00, cachedInput: 0.10, cacheWrite: 1.25, output: 6.00)
        }
        if normalized.contains("gpt-5.4-mini") {
            return Rates(input: 0.75, cachedInput: 0.075, cacheWrite: 0.9375, output: 4.50)
        }
        if normalized.contains("gpt-5.4") {
            return Rates(input: 2.50, cachedInput: 0.25, cacheWrite: 3.125, output: 15.00)
        }
        if normalized.contains("gpt-5.3") || normalized.contains("gpt-5.2") {
            return Rates(input: 1.75, cachedInput: 0.175, cacheWrite: 2.1875, output: 14.00)
        }
        return Rates(input: 5.00, cachedInput: 0.50, cacheWrite: 6.25, output: 30.00)
    }
}
