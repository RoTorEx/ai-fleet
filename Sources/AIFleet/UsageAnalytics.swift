import Foundation

struct UsageAnalyticsSnapshot: Codable, Equatable {
    var codex: CodexUsageAnalytics
    var kimi: KimiQuotaAnalytics
    var refreshedAt: Date?
    var lastLoadDuration: TimeInterval?

    static let empty = UsageAnalyticsSnapshot(
        codex: .empty,
        kimi: .empty,
        refreshedAt: nil,
        lastLoadDuration: nil
    )
}

struct UsageAnalyticsLoadProgress: Equatable {
    var isLoading: Bool
    var processedFiles: Int
    var totalFiles: Int
    var startedAt: Date?
    var lastDuration: TimeInterval?
    var lastCompletedAt: Date?
    var currentFileName: String?

    static let idle = UsageAnalyticsLoadProgress(
        isLoading: false,
        processedFiles: 0,
        totalFiles: 0,
        startedAt: nil,
        lastDuration: nil,
        lastCompletedAt: nil,
        currentFileName: nil
    )

    var fractionCompleted: Double? {
        guard totalFiles > 0 else { return nil }
        return min(1, max(0, Double(processedFiles) / Double(totalFiles)))
    }
}

struct CodexUsageAnalytics: Codable, Equatable {
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

struct KimiQuotaAnalytics: Codable, Equatable {
    var windows: [KimiQuotaWindow]
    var source: String

    static let empty = KimiQuotaAnalytics(windows: [], source: "Kimi quota API")
}

struct KimiQuotaWindow: Codable, Identifiable, Equatable {
    let id: String
    let label: String
    let remainingPercent: Int
    let used: Int?
    let limit: Int?
    let resetAt: Date?
}

struct DailyUsage: Codable, Identifiable, Equatable {
    let day: Date
    var totals: UsageTotals

    var id: Date { day }
}

struct ModelUsage: Codable, Identifiable, Equatable {
    let model: String
    var totals: UsageTotals
    var events: Int

    var id: String { model }
}

struct UsageTotals: Codable, Equatable {
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
    private static let staleRefreshInterval: TimeInterval = 10 * 60

    @Published private(set) var snapshot = UsageAnalyticsSnapshot.empty
    @Published private(set) var isRefreshing = false
    @Published private(set) var progress = UsageAnalyticsLoadProgress.idle

    private var task: Task<Void, Never>?

    private init() {
        let cached = Self.loadCachedSnapshot()
        snapshot = cached
        progress = UsageAnalyticsLoadProgress(
            isLoading: false,
            processedFiles: 0,
            totalFiles: cached.codex.fileCount,
            startedAt: nil,
            lastDuration: cached.lastLoadDuration,
            lastCompletedAt: cached.refreshedAt,
            currentFileName: nil
        )
    }

    func refresh(kimi: ProviderStatus) {
        startRefresh(kimi: kimi, restartExisting: true)
    }

    func refreshIfNeeded(kimi: ProviderStatus) {
        let kimiAnalytics = Self.kimiAnalytics(from: kimi.limitWindows)
        snapshot = snapshot.withKimi(kimiAnalytics)

        guard !isRefreshing else {
            return
        }
        if let refreshedAt = snapshot.refreshedAt,
           Date().timeIntervalSince(refreshedAt) < Self.staleRefreshInterval {
            return
        }

        startRefresh(kimi: kimi, restartExisting: false)
    }

    private func startRefresh(kimi: ProviderStatus, restartExisting: Bool) {
        if isRefreshing {
            guard restartExisting else { return }
            task?.cancel()
        }

        isRefreshing = true
        let startedAt = Date()
        progress = UsageAnalyticsLoadProgress(
            isLoading: true,
            processedFiles: 0,
            totalFiles: 0,
            startedAt: startedAt,
            lastDuration: snapshot.lastLoadDuration ?? progress.lastDuration,
            lastCompletedAt: snapshot.refreshedAt ?? progress.lastCompletedAt,
            currentFileName: nil
        )

        let kimiAnalytics = Self.kimiAnalytics(from: kimi.limitWindows)
        snapshot = snapshot.withKimi(kimiAnalytics)

        task = Task { [self, startedAt, kimiAnalytics] in
            let files = await Task.detached(priority: .utility) {
                CodexUsageLogReader().codexLogFiles()
            }.value
            guard !Task.isCancelled else { return }

            self.progress.totalFiles = files.count

            var entries: [CodexUsageLogEntry] = []
            for (index, file) in files.enumerated() {
                guard !Task.isCancelled else { return }
                self.progress.currentFileName = file.lastPathComponent

                let fileEntries = await Task.detached(priority: .utility) {
                    CodexUsageLogReader().readEntries(from: file)
                }.value
                entries.append(contentsOf: fileEntries)
                self.progress.processedFiles = index + 1
            }

            let codex = await Task.detached(priority: .utility) {
                CodexUsageLogReader().analytics(from: entries, fileCount: files.count)
            }.value

            guard !Task.isCancelled else { return }
            let duration = Date().timeIntervalSince(startedAt)
            let completedAt = Date()
            let nextSnapshot = UsageAnalyticsSnapshot(
                codex: codex,
                kimi: kimiAnalytics,
                refreshedAt: completedAt,
                lastLoadDuration: duration
            )
            self.snapshot = nextSnapshot
            self.progress = UsageAnalyticsLoadProgress(
                isLoading: false,
                processedFiles: files.count,
                totalFiles: files.count,
                startedAt: nil,
                lastDuration: duration,
                lastCompletedAt: completedAt,
                currentFileName: nil
            )
            self.isRefreshing = false
            Self.saveCachedSnapshot(nextSnapshot)
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

    private static var cacheURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("AI Fleet", isDirectory: true)
            .appendingPathComponent("usage-analytics-cache.json")
    }

    private static var cacheDirectoryURL: URL {
        cacheURL.deletingLastPathComponent()
    }

    private static func loadCachedSnapshot() -> UsageAnalyticsSnapshot {
        do {
            let data = try Data(contentsOf: cacheURL)
            protectCacheFile()

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(UsageAnalyticsSnapshot.self, from: data)
        } catch {
            return .empty
        }
    }

    private static func saveCachedSnapshot(_ snapshot: UsageAnalyticsSnapshot) {
        do {
            try FileManager.default.createDirectory(
                at: cacheDirectoryURL,
                withIntermediateDirectories: true
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: cacheDirectoryURL.path
            )

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            try data.write(to: cacheURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: cacheURL.path
            )
        } catch {
            // Statistics cache is best-effort; the next refresh can rebuild it.
        }
    }

    private static func protectCacheFile() {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: cacheDirectoryURL.path
        )
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: cacheURL.path
        )
    }
}

private extension UsageAnalyticsSnapshot {
    func withKimi(_ kimi: KimiQuotaAnalytics) -> UsageAnalyticsSnapshot {
        UsageAnalyticsSnapshot(
            codex: codex,
            kimi: kimi,
            refreshedAt: refreshedAt,
            lastLoadDuration: lastLoadDuration
        )
    }
}

struct CodexUsageLogEntry {
    let timestamp: Date
    let model: String
    let totals: UsageTotals
}

struct CodexUsageLogReader {
    private let calendar = Calendar.autoupdatingCurrent
    private let iso8601 = ISO8601DateFormatter()
    private let iso8601WithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    func read() -> CodexUsageAnalytics {
        let files = codexLogFiles()
        var entries: [CodexUsageLogEntry] = []

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

    func analytics(from entries: [CodexUsageLogEntry], fileCount: Int) -> CodexUsageAnalytics {
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
            fileCount: fileCount,
            source: "~/.codex/sessions"
        )
    }

    func codexLogFiles() -> [URL] {
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

    func readEntries(from file: URL) -> [CodexUsageLogEntry] {
        guard let content = try? String(contentsOf: file, encoding: .utf8) else {
            return []
        }

        var entries: [CodexUsageLogEntry] = []
        var sessionModel = "gpt-5.6-sol"

        for line in content.split(whereSeparator: \.isNewline) {
            let text = String(line)
            if let model = knownModel(in: text) {
                sessionModel = model
            }

            guard text.contains("\"last_token_usage\""),
                  let timestamp = timestamp(in: text) else {
                continue
            }

            let usageObject = tokenUsageObject(in: text)
            let usageText: String
            if let usageStart = text.range(of: "\"last_token_usage\"")?.lowerBound {
                usageText = String(text[usageStart...])
            } else {
                usageText = text
            }
            let input = usageObject.map { intValue("input_tokens", in: $0) }
                ?? intValue("input_tokens", in: usageText)
            let cached = usageObject.map { intValue("cached_input_tokens", in: $0) }
                ?? intValue("cached_input_tokens", in: usageText)
            let cacheWrite = usageObject.map { intValue("cache_write_input_tokens", in: $0) }
                ?? intValue("cache_write_input_tokens", in: usageText)
            let output = usageObject.map { intValue("output_tokens", in: $0) }
                ?? intValue("output_tokens", in: usageText)
            let reasoning = usageObject.map { intValue("reasoning_output_tokens", in: $0) }
                ?? intValue("reasoning_output_tokens", in: usageText)
            let totals = usageTotals(
                model: sessionModel,
                input: input,
                cached: cached,
                cacheWrite: cacheWrite,
                output: output,
                reasoning: reasoning
            )

            entries.append(CodexUsageLogEntry(timestamp: timestamp, model: sessionModel, totals: totals))
        }

        return entries
    }

    private func tokenUsageObject(in text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        if let payload = object["payload"] as? [String: Any],
           let info = payload["info"] as? [String: Any],
           let usage = info["last_token_usage"] as? [String: Any] {
            return usage
        }

        if let usage = object["last_token_usage"] as? [String: Any] {
            return usage
        }

        return nil
    }

    private func timestamp(in text: String) -> Date? {
        guard let range = text.range(of: "\"timestamp\"") else { return nil }
        let rest = text[range.upperBound...]
        guard let firstQuote = rest.firstIndex(of: "\"") else { return nil }
        let afterFirstQuote = rest.index(after: firstQuote)
        guard let secondQuote = rest[afterFirstQuote...].firstIndex(of: "\"") else { return nil }
        return timestamp(from: String(rest[afterFirstQuote..<secondQuote]))
    }

    private func timestamp(from value: String) -> Date? {
        iso8601WithFractionalSeconds.date(from: value) ?? iso8601.date(from: value)
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

    private func intValue(_ key: String, in object: [String: Any]) -> Int {
        guard let value = object[key] else {
            return 0
        }

        if let int = value as? Int {
            return int
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String {
            return Int(string) ?? 0
        }
        return 0
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

    private func totals(for entries: [CodexUsageLogEntry]) -> UsageTotals {
        entries.reduce(into: .zero) { partial, entry in
            partial.add(entry.totals)
        }
    }

    private func dailyUsage(entries: [CodexUsageLogEntry], start: Date, days: Int) -> [DailyUsage] {
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

    private func modelUsage(entries: [CodexUsageLogEntry]) -> [ModelUsage] {
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
