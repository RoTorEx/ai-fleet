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
    var dailyModels: [DailyModelUsage]
    var eventCount: Int
    var fileCount: Int
    var source: String
    var accountUsage: CodexAccountUsage?

    static let empty = CodexUsageAnalytics(
        total: .zero,
        today: .zero,
        sevenDays: .zero,
        thirtyDays: .zero,
        daily: [],
        models: [],
        dailyModels: [],
        eventCount: 0,
        fileCount: 0,
        source: "~/.codex sessions + archive",
        accountUsage: nil
    )

    init(
        total: UsageTotals,
        today: UsageTotals,
        sevenDays: UsageTotals,
        thirtyDays: UsageTotals,
        daily: [DailyUsage],
        models: [ModelUsage],
        dailyModels: [DailyModelUsage],
        eventCount: Int,
        fileCount: Int,
        source: String,
        accountUsage: CodexAccountUsage? = nil
    ) {
        self.total = total
        self.today = today
        self.sevenDays = sevenDays
        self.thirtyDays = thirtyDays
        self.daily = daily
        self.models = models
        self.dailyModels = dailyModels
        self.eventCount = eventCount
        self.fileCount = fileCount
        self.source = source
        self.accountUsage = accountUsage
    }

    private enum CodingKeys: String, CodingKey {
        case total, today, sevenDays, thirtyDays, daily, models, dailyModels
        case eventCount, fileCount, source, accountUsage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        total = try container.decode(UsageTotals.self, forKey: .total)
        today = try container.decode(UsageTotals.self, forKey: .today)
        sevenDays = try container.decode(UsageTotals.self, forKey: .sevenDays)
        thirtyDays = try container.decode(UsageTotals.self, forKey: .thirtyDays)
        daily = try container.decode([DailyUsage].self, forKey: .daily)
        models = try container.decode([ModelUsage].self, forKey: .models)
        dailyModels = try container.decodeIfPresent([DailyModelUsage].self, forKey: .dailyModels) ?? []
        eventCount = try container.decode(Int.self, forKey: .eventCount)
        fileCount = try container.decode(Int.self, forKey: .fileCount)
        source = try container.decode(String.self, forKey: .source)
        accountUsage = try container.decodeIfPresent(CodexAccountUsage.self, forKey: .accountUsage)
    }
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

struct DailyModelUsage: Codable, Identifiable, Equatable {
    let day: Date
    let model: String
    var totals: UsageTotals
    var events: Int

    var id: String { "\(day.timeIntervalSince1970)-\(model)" }
}

struct CodexLogFile {
    let url: URL
    let modifiedAt: Date
    let size: Int
}

struct CodexFileUsageRecord: Codable, Equatable {
    let path: String
    let modifiedAt: Date
    let size: Int
    let dailyModels: [DailyModelUsage]

    var eventCount: Int {
        dailyModels.reduce(0) { $0 + $1.events }
    }

    func matches(_ file: CodexLogFile) -> Bool {
        size == file.size && abs(modifiedAt.timeIntervalSince(file.modifiedAt)) < 1
    }
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

    @Published private(set) var snapshot = UsageAnalyticsSnapshot.empty
    @Published private(set) var isRefreshing = false
    @Published private(set) var progress = UsageAnalyticsLoadProgress.idle

    private var task: Task<Void, Never>?
    private var accountTask: Task<Void, Never>?
    private var scheduleTimer: Timer?
    private var fileCache: [String: CodexFileUsageRecord]

    private init() {
        let cached = Self.loadCachedSnapshot()
        fileCache = Self.loadFileCache()
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

    func updateKimi(kimi: ProviderStatus) {
        let kimiAnalytics = Self.kimiAnalytics(from: kimi.limitWindows)
        snapshot = snapshot.withKimi(kimiAnalytics)
    }

    func refreshAccountUsageIfNeeded() {
        guard snapshot.codex.accountUsage == nil, accountTask == nil else { return }
        refreshAccountUsage()
    }

    func refreshAccountUsage() {
        accountTask?.cancel()
        accountTask = Task { [weak self] in
            let usage = await Task.detached(priority: .utility) {
                try? CodexAccountUsageReader().read()
            }.value
            guard let self, !Task.isCancelled else { return }
            if let usage {
                let nextSnapshot = self.snapshot.withAccountUsage(usage)
                self.snapshot = nextSnapshot
                Self.saveCachedSnapshot(nextSnapshot)
            }
            self.accountTask = nil
        }
    }

    func startDailyRefreshSchedule() {
        rescheduleDailyRefresh()
    }

    func rescheduleDailyRefresh() {
        scheduleTimer?.invalidate()
        scheduleTimer = nil

        let settings = AppSettings.shared
        guard settings.analyticsAutoRefreshEnabled else { return }
        let fireDate = nextDailyRefreshDate(
            after: Date(),
            minutesAfterMidnight: settings.analyticsRefreshMinutes
        )
        let timer = Timer(fire: fireDate, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refresh(kimi: StatusService.shared.kimi)
                self.rescheduleDailyRefresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        scheduleTimer = timer
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
        let existingFileCache = fileCache
        let existingAccountUsage = snapshot.codex.accountUsage
        snapshot = snapshot.withKimi(kimiAnalytics)

        task = Task { [self, startedAt, kimiAnalytics, existingAccountUsage] in
            async let accountUsageResult: CodexAccountUsage? = Task.detached(priority: .utility) {
                try? CodexAccountUsageReader().read()
            }.value
            let files = await Task.detached(priority: .background) {
                CodexUsageLogReader().codexLogFileMetadata()
            }.value
            guard !Task.isCancelled else { return }

            self.progress.totalFiles = files.count

            var nextFileCache: [String: CodexFileUsageRecord] = [:]
            for (index, file) in files.enumerated() {
                guard !Task.isCancelled else { return }
                self.progress.currentFileName = file.url.lastPathComponent

                if let cached = existingFileCache[file.url.path], cached.matches(file) {
                    nextFileCache[file.url.path] = cached
                } else {
                    let record = await Task.detached(priority: .background) {
                        CodexUsageLogReader().usageRecord(for: file)
                    }.value
                    nextFileCache[file.url.path] = record
                }
                self.progress.processedFiles = index + 1
                try? await Task.sleep(nanoseconds: 5_000_000)
            }

            let records = Array(nextFileCache.values)
            var codex = await Task.detached(priority: .background) {
                CodexUsageLogReader().analytics(from: records, fileCount: files.count)
            }.value
            codex.accountUsage = await accountUsageResult ?? existingAccountUsage

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
            self.fileCache = nextFileCache
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
            Self.saveFileCache(nextFileCache)
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

    private static var fileCacheURL: URL {
        cacheDirectoryURL.appendingPathComponent("usage-analytics-files-cache.json")
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

    private static func loadFileCache() -> [String: CodexFileUsageRecord] {
        do {
            let data = try Data(contentsOf: fileCacheURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([String: CodexFileUsageRecord].self, from: data)
        } catch {
            return [:]
        }
    }

    private static func saveFileCache(_ cache: [String: CodexFileUsageRecord]) {
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
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(cache)
            try data.write(to: fileCacheURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileCacheURL.path
            )
        } catch {
            // Best-effort optimization; the main snapshot remains authoritative.
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
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileCacheURL.path
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

    func withAccountUsage(_ accountUsage: CodexAccountUsage) -> UsageAnalyticsSnapshot {
        var nextCodex = codex
        nextCodex.accountUsage = accountUsage
        return UsageAnalyticsSnapshot(
            codex: nextCodex,
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

        return analytics(from: entries, fileCount: files.count)
    }

    func analytics(from entries: [CodexUsageLogEntry], fileCount: Int) -> CodexUsageAnalytics {
        analytics(from: dailyModelUsage(entries: entries), fileCount: fileCount)
    }

    func analytics(from records: [CodexFileUsageRecord], fileCount: Int) -> CodexUsageAnalytics {
        analytics(from: mergeDailyModels(records.flatMap(\.dailyModels)), fileCount: fileCount)
    }

    func usageRecord(for file: CodexLogFile) -> CodexFileUsageRecord {
        CodexFileUsageRecord(
            path: file.url.path,
            modifiedAt: file.modifiedAt,
            size: file.size,
            dailyModels: dailyModelUsage(entries: readEntries(from: file.url))
        )
    }

    private func analytics(from dailyModels: [DailyModelUsage], fileCount: Int) -> CodexUsageAnalytics {
        let now = Date()
        let todayStart = calendar.startOfDay(for: now)
        let sevenDaysStart = calendar.date(byAdding: .day, value: -6, to: todayStart) ?? todayStart
        let thirtyDaysStart = calendar.date(byAdding: .day, value: -29, to: todayStart) ?? todayStart

        let total = totals(for: dailyModels)
        let today = totals(for: dailyModels.filter { $0.day >= todayStart })
        let sevenDays = totals(for: dailyModels.filter { $0.day >= sevenDaysStart })
        let thirtyDays = totals(for: dailyModels.filter { $0.day >= thirtyDaysStart })

        return CodexUsageAnalytics(
            total: total,
            today: today,
            sevenDays: sevenDays,
            thirtyDays: thirtyDays,
            daily: dailyUsage(dailyModels: dailyModels, through: todayStart),
            models: modelUsage(dailyModels: dailyModels),
            dailyModels: dailyModels,
            eventCount: dailyModels.reduce(0) { $0 + $1.events },
            fileCount: fileCount,
            source: "~/.codex sessions + archive"
        )
    }

    func codexLogFiles() -> [URL] {
        codexLogFileMetadata().map(\.url)
    }

    func codexLogFileMetadata(roots suppliedRoots: [URL]? = nil) -> [CodexLogFile] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = suppliedRoots ?? [
            home.appendingPathComponent(".codex/sessions"),
            home.appendingPathComponent(".codex/archived_sessions")
        ]

        var filesByName: [String: CodexLogFile] = [:]
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for item in enumerator {
                guard let url = item as? URL, url.pathExtension == "jsonl",
                      let values = try? url.resourceValues(
                          forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
                      ),
                      values.isRegularFile == true else {
                    continue
                }
                let file = CodexLogFile(
                    url: url,
                    modifiedAt: values.contentModificationDate ?? .distantPast,
                    size: values.fileSize ?? 0
                )
                if filesByName[url.lastPathComponent] == nil {
                    filesByName[url.lastPathComponent] = file
                }
            }
        }
        return filesByName.values.sorted { $0.url.path < $1.url.path }
    }

    func readEntries(from file: URL) -> [CodexUsageLogEntry] {
        guard let content = try? String(contentsOf: file, encoding: .utf8) else {
            return []
        }

        var entries: [CodexUsageLogEntry] = []
        let modelHeader = String(content.prefix(100_000))
        let sessionModel = knownModel(in: modelHeader) ?? "gpt-5.6-sol"
        let usageMarker = "\"last_token_usage\""
        var cursor = content.startIndex

        while cursor < content.endIndex,
              let usageRange = content.range(of: usageMarker, range: cursor..<content.endIndex) {
            let lineStart = content[..<usageRange.lowerBound].lastIndex(of: "\n")
                .map { content.index(after: $0) } ?? content.startIndex
            let lineEnd = content[usageRange.upperBound...].firstIndex(of: "\n") ?? content.endIndex
            let text = String(content[lineStart..<lineEnd])
            cursor = lineEnd < content.endIndex ? content.index(after: lineEnd) : content.endIndex

            guard let timestamp = timestamp(in: text) else { continue }

            let usageText: String
            if let usageStart = text.range(of: "\"last_token_usage\"")?.lowerBound {
                usageText = String(text[usageStart...])
            } else {
                usageText = text
            }
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

            entries.append(CodexUsageLogEntry(timestamp: timestamp, model: sessionModel, totals: totals))
        }

        return entries
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

    private func totals(for dailyModels: [DailyModelUsage]) -> UsageTotals {
        dailyModels.reduce(into: .zero) { partial, usage in
            partial.add(usage.totals)
        }
    }

    private func dailyModelUsage(entries: [CodexUsageLogEntry]) -> [DailyModelUsage] {
        var buckets: [String: DailyModelUsage] = [:]
        for entry in entries {
            let day = calendar.startOfDay(for: entry.timestamp)
            let key = "\(day.timeIntervalSince1970)|\(entry.model)"
            if buckets[key] == nil {
                buckets[key] = DailyModelUsage(day: day, model: entry.model, totals: .zero, events: 0)
            }
            buckets[key]?.totals.add(entry.totals)
            buckets[key]?.events += 1
        }
        return buckets.values.sorted {
            $0.day == $1.day ? $0.model < $1.model : $0.day < $1.day
        }
    }

    private func mergeDailyModels(_ values: [DailyModelUsage]) -> [DailyModelUsage] {
        var buckets: [String: DailyModelUsage] = [:]
        for value in values {
            let day = calendar.startOfDay(for: value.day)
            let key = "\(day.timeIntervalSince1970)|\(value.model)"
            if buckets[key] == nil {
                buckets[key] = DailyModelUsage(day: day, model: value.model, totals: .zero, events: 0)
            }
            buckets[key]?.totals.add(value.totals)
            buckets[key]?.events += value.events
        }
        return buckets.values.sorted {
            $0.day == $1.day ? $0.model < $1.model : $0.day < $1.day
        }
    }

    private func dailyUsage(dailyModels: [DailyModelUsage], through end: Date) -> [DailyUsage] {
        guard let firstDay = dailyModels.map(\.day).min() else { return [] }
        var buckets: [Date: UsageTotals] = [:]
        let dayCount = max(1, (calendar.dateComponents([.day], from: firstDay, to: end).day ?? 0) + 1)
        for offset in 0..<dayCount {
            if let day = calendar.date(byAdding: .day, value: offset, to: firstDay) {
                buckets[day] = .zero
            }
        }

        for usage in dailyModels {
            let day = calendar.startOfDay(for: usage.day)
            buckets[day, default: .zero].add(usage.totals)
        }

        return buckets.keys.sorted().map { day in
            DailyUsage(day: day, totals: buckets[day] ?? .zero)
        }
    }

    private func modelUsage(dailyModels: [DailyModelUsage]) -> [ModelUsage] {
        var buckets: [String: ModelUsage] = [:]
        for usage in dailyModels {
            if buckets[usage.model] == nil {
                buckets[usage.model] = ModelUsage(model: usage.model, totals: .zero, events: 0)
            }
            buckets[usage.model]?.totals.add(usage.totals)
            buckets[usage.model]?.events += usage.events
        }

        return buckets.values.sorted {
            if $0.totals.estimatedCostUSD != $1.totals.estimatedCostUSD {
                return $0.totals.estimatedCostUSD > $1.totals.estimatedCostUSD
            }
            return $0.totals.totalTokens > $1.totals.totalTokens
        }
    }
}

func nextDailyRefreshDate(
    after date: Date,
    minutesAfterMidnight: Int,
    calendar: Calendar = .autoupdatingCurrent
) -> Date {
    let normalizedMinutes = max(0, min((24 * 60) - 1, minutesAfterMidnight))
    let startOfDay = calendar.startOfDay(for: date)
    let scheduledToday = calendar.date(
        byAdding: .minute,
        value: normalizedMinutes,
        to: startOfDay
    ) ?? date
    if scheduledToday > date {
        return scheduledToday
    }
    return calendar.date(byAdding: .day, value: 1, to: scheduledToday) ?? scheduledToday
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
