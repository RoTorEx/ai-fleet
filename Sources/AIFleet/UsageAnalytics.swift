import Foundation

struct UsageAnalyticsSnapshot: Codable, Equatable {
    var codex: CodexUsageAnalytics
    var kimi: KimiQuotaAnalytics
    var claude: CodexUsageAnalytics? = nil
    var kimiUsage: CodexUsageAnalytics? = nil
    var qwen: CodexUsageAnalytics? = nil
    var sourceIssues: [StatisticsSourceIssue]? = nil
    var statisticsRevision: Int? = nil
    var rateRevision: String? = nil
    var timeZoneIdentifier: String? = nil
    var unattributedAccountUsage: CodexAccountUsage? = nil
    var legacyLocalHistory: [String: CodexUsageAnalytics]? = nil
    var refreshedAt: Date?
    var lastLoadDuration: TimeInterval?

    static let empty = UsageAnalyticsSnapshot(
        codex: .empty,
        kimi: .empty,
        rateRevision: CodexAPIRates.revision,
        timeZoneIdentifier: TimeZone.current.identifier,
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
    var issue: String? = nil
}

struct CodexFileUsageRecord: Codable, Equatable {
    let path: String
    let modifiedAt: Date
    let size: Int
    let dailyModels: [DailyModelUsage]
    var timeZoneIdentifier: String? = nil
    var parserRevision: Int? = nil
    var rateRevision: String? = nil
    var sourceIssue: String? = nil
    var excluded: Bool? = nil
    var modifiedAtEpoch: Double? = nil

    var eventCount: Int {
        dailyModels.reduce(0) { $0 + $1.events }
    }

    func matches(_ file: CodexLogFile, timeZone: TimeZone = .autoupdatingCurrent, revision: Int? = nil) -> Bool {
        (sourceIssue == nil && file.issue == nil) && (revision == nil || (parserRevision == revision && rateRevision == CodexAPIRates.revision)) && timeZoneIdentifier == timeZone.identifier
            && size == file.size && (modifiedAtEpoch.map { $0 == file.modifiedAt.timeIntervalSince1970 }
                ?? (revision == nil && abs(modifiedAt.timeIntervalSince(file.modifiedAt)) < 1))
    }
}

struct UsageTotals: Codable, Equatable {
    var inputTokens: Int
    var cachedInputTokens: Int
    var cacheWriteInputTokens: Int
    var outputTokens: Int
    var reasoningOutputTokens: Int
    var estimatedCostUSD: Double
    var costEstimateAvailable: Bool? = nil
    var pricedTokens: Int? = nil
    var overflowDetected: Bool? = nil

    var hasCostEstimate: Bool { overflowDetected != true && (costEstimateAvailable ?? true) }

    static let zero = UsageTotals(
        inputTokens: 0,
        cachedInputTokens: 0,
        cacheWriteInputTokens: 0,
        outputTokens: 0,
        reasoningOutputTokens: 0,
        estimatedCostUSD: 0
    )

    var totalTokens: Int {
        let sum = inputTokens.addingReportingOverflow(outputTokens)
        return sum.overflow ? 0 : sum.partialValue
    }

    var billableInputTokens: Int {
        max(0, inputTokens - cachedInputTokens - cacheWriteInputTokens)
    }

    mutating func add(_ other: UsageTotals) {
        let lhs = [inputTokens, cachedInputTokens, cacheWriteInputTokens, outputTokens, reasoningOutputTokens, pricedTokens ?? (hasCostEstimate ? totalTokens : 0)]
        let rhs = [other.inputTokens, other.cachedInputTokens, other.cacheWriteInputTokens, other.outputTokens, other.reasoningOutputTokens, other.pricedTokens ?? (other.hasCostEstimate ? other.totalTokens : 0)]
        let sums = zip(lhs, rhs).map { $0.addingReportingOverflow($1) }
        guard !sums.contains(where: \.overflow), !sums[0].partialValue.addingReportingOverflow(sums[3].partialValue).overflow else {
            overflowDetected = true; costEstimateAvailable = false; return
        }
        inputTokens = sums[0].partialValue; cachedInputTokens = sums[1].partialValue
        cacheWriteInputTokens = sums[2].partialValue; outputTokens = sums[3].partialValue
        reasoningOutputTokens = sums[4].partialValue; pricedTokens = sums[5].partialValue
        overflowDetected = overflowDetected == true || other.overflowDetected == true
        costEstimateAvailable = overflowDetected != true && (totalTokens == 0 || pricedTokens == totalTokens)
        estimatedCostUSD += other.estimatedCostUSD
    }
}

@MainActor
final class UsageAnalyticsService: ObservableObject {
    static let shared = UsageAnalyticsService()

    @Published var selectedProviders = Set(StatisticsProvider.allCases) {
        didSet { preferences.set(selectedProviders.map(\.rawValue).sorted().joined(separator: ","), forKey: "analytics.selectedProviders") }
    }
    private let preferences: UserDefaults
    @Published private(set) var snapshot = UsageAnalyticsSnapshot.empty
    @Published private(set) var isRefreshing = false
    @Published private(set) var progress = UsageAnalyticsLoadProgress.idle

    private var task: Task<Void, Never>?
    private var scheduleTimer: Timer?
    private var fileCache: [String: CodexFileUsageRecord]
    private let cacheRoot: URL
    private let discoverFiles: @Sendable () -> [CodexLogFile]
    private var timeZoneObserver: NSObjectProtocol?

    init(cacheDirectory: URL? = nil, discoverFiles: (@Sendable () -> [CodexLogFile])? = nil, preferences: UserDefaults = .standard) {
        self.preferences = preferences
        if let stored = preferences.string(forKey: "analytics.selectedProviders") {
            selectedProviders = Set(stored.split(separator: ",").compactMap { StatisticsProvider(rawValue: String($0)) })
        }
        let root = cacheDirectory ?? Self.cacheDirectoryURL
        cacheRoot = root
        self.discoverFiles = discoverFiles ?? {
            CodexUsageLogReader().codexLogFileMetadata() + ClaudeUsageLogReader().logFileMetadata()
                + LocalUsageProvider.allCases.flatMap { $0.logFileMetadata() }
        }
        let cached = Self.loadCachedSnapshot(directory: root)
        fileCache = Self.loadFileCache(directory: root)
        snapshot = cached
        snapshot.unattributedAccountUsage = cached.unattributedAccountUsage ?? cached.codex.accountUsage
        snapshot.codex.accountUsage = nil
        if cached.statisticsRevision != 4 || cached.rateRevision != CodexAPIRates.revision || cached.timeZoneIdentifier != TimeZone.current.identifier {
            snapshot.legacyLocalHistory = cached.legacyLocalHistory ?? ["codex": cached.codex, "claude": cached.claude ?? .empty, "kimi": cached.kimiUsage ?? .empty, "qwen": cached.qwen ?? .empty]
            snapshot.codex = snapshot.codex.withUnverifiedPrices()
            snapshot.claude = snapshot.claude?.withUnverifiedPrices()
            snapshot.kimiUsage = snapshot.kimiUsage?.withUnverifiedPrices()
            snapshot.qwen = snapshot.qwen?.withUnverifiedPrices()
        }
        progress = UsageAnalyticsLoadProgress(
            isLoading: false,
            processedFiles: 0,
            totalFiles: cached.codex.fileCount + (cached.claude?.fileCount ?? 0) + (cached.kimiUsage?.fileCount ?? 0) + (cached.qwen?.fileCount ?? 0),
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

    func refreshAccountUsageIfNeeded() { refreshAccountUsage() }

    func refreshAccountUsage() {
        // Reports are measured by the identity-bound account service, not an anonymous default CLI.
        guard selectedProviders.contains(.codex), SwitchCoordinator.shared.active.isEmpty else { return }
        CodexMonitoringStore.shared.refresh()
    }

    func startDailyRefreshSchedule() {
        if timeZoneObserver == nil {
            timeZoneObserver = NotificationCenter.default.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: nil) { [weak self] _ in
                Task { @MainActor in self?.startRefresh(kimi: StatusService.shared.kimi, restartExisting: true, preserveQuota: true) }
            }
        }
        if snapshot.statisticsRevision != 4 || snapshot.rateRevision != CodexAPIRates.revision || snapshot.timeZoneIdentifier != TimeZone.current.identifier { startRefresh(kimi: StatusService.shared.kimi, restartExisting: false, preserveQuota: true) }
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

    private func startRefresh(kimi: ProviderStatus, restartExisting: Bool, preserveQuota: Bool = false) {
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

        let kimiAnalytics = preserveQuota ? snapshot.kimi : Self.kimiAnalytics(from: kimi.limitWindows)
        let existingFileCache = fileCache
        snapshot = snapshot.withKimi(kimiAnalytics)

        task = Task { [self, startedAt, kimiAnalytics] in
            let discover = self.discoverFiles
            let scanTimeZone = TimeZone.current.identifier
            let files = await Task.detached(priority: .background) { discover() }.value
            guard !Task.isCancelled else { return }

            self.progress.totalFiles = files.count

            var nextFileCache: [String: CodexFileUsageRecord] = [:]
            for (index, file) in files.enumerated() {
                guard !Task.isCancelled else { return }
                self.progress.currentFileName = file.url.lastPathComponent

                if let cached = existingFileCache[file.url.path], cached.matches(file, revision: 4) {
                    nextFileCache[file.url.path] = cached
                } else {
                    let record = await Task.detached(priority: .background) {
                        if let provider = LocalUsageProvider.allCases.first(where: { $0.contains(file.url) }) {
                            return provider.usageRecord(for: file)
                        }
                        if ClaudeUsageLogReader.isClaudeLog(file.url) {
                            return ClaudeUsageLogReader().usageRecord(for: file)
                        }
                        return CodexUsageLogReader().usageRecord(for: file)
                    }.value
                    nextFileCache[file.url.path] = record
                }
                guard !Task.isCancelled else { return }
                self.progress.processedFiles = index + 1
                try? await Task.sleep(nanoseconds: 5_000_000)
            }

            let records = Array(nextFileCache.values).filter { $0.excluded != true }
            var codex = await Task.detached(priority: .background) {
                let codexRecords = records.filter {
                    let url = URL(fileURLWithPath: $0.path)
                    return !ClaudeUsageLogReader.isClaudeLog(url) && !LocalUsageProvider.allCases.contains { $0.contains(url) }
                }
                return CodexUsageLogReader().analytics(from: codexRecords, fileCount: codexRecords.count)
            }.value
            codex.accountUsage = nil
            let claude = await Task.detached(priority: .background) {
                let claudeRecords = records.filter { ClaudeUsageLogReader.isClaudeLog(URL(fileURLWithPath: $0.path)) }
                var result = CodexUsageLogReader().analytics(from: claudeRecords, fileCount: claudeRecords.count)
                result.source = "~/.claude/projects"
                return result
            }.value

            let providerUsage = await Task.detached(priority: .background) {
                Dictionary(uniqueKeysWithValues: LocalUsageProvider.allCases.map { provider in
                    let matching = records.filter { provider.contains(URL(fileURLWithPath: $0.path)) }
                    return (provider, provider.analytics(from: matching))
                })
            }.value

            guard !Task.isCancelled else { return }
            guard TimeZone.current.identifier == scanTimeZone else {
                self.snapshot.sourceIssues = [StatisticsSourceIssue(provider: nil, message: "Time zone changed during scan; refresh to rebuild local days.")]
                self.progress.isLoading = false
                self.isRefreshing = false
                return
            }
            let duration = Date().timeIntervalSince(startedAt)
            let completedAt = Date()
            var nextSnapshot = UsageAnalyticsSnapshot(
                codex: codex,
                kimi: kimiAnalytics,
                claude: claude,
                kimiUsage: providerUsage[.kimi],
                qwen: providerUsage[.qwen],
                refreshedAt: completedAt,
                lastLoadDuration: duration
            )
            nextSnapshot.statisticsRevision = 4
            nextSnapshot.rateRevision = CodexAPIRates.revision
            nextSnapshot.timeZoneIdentifier = scanTimeZone
            nextSnapshot.unattributedAccountUsage = self.snapshot.unattributedAccountUsage
            nextSnapshot.legacyLocalHistory = self.snapshot.legacyLocalHistory
            nextSnapshot.sourceIssues = nextFileCache.values.compactMap { record in
                record.sourceIssue.map { StatisticsSourceIssue(provider: statisticsProvider(for: record.path), message: $0) }
            } + existingFileCache.keys.filter { nextFileCache[$0] == nil && !FileManager.default.fileExists(atPath: $0) }.map { StatisticsSourceIssue(provider: statisticsProvider(for: $0), message: "Missing source: " + $0) }
            self.snapshot = nextSnapshot
            // Missing records remain available for migration/recovery but not active totals.
            self.fileCache = existingFileCache.merging(nextFileCache) { _, current in current }
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
            if !Self.saveFileCache(self.fileCache, directory: cacheRoot) {
                self.snapshot.sourceIssues = (self.snapshot.sourceIssues ?? []) + [StatisticsSourceIssue(provider: nil, message: "Could not save incremental file cache.")]
            }
            if !Self.saveCachedSnapshot(nextSnapshot, directory: cacheRoot) {
                self.snapshot.sourceIssues = (self.snapshot.sourceIssues ?? []) + [StatisticsSourceIssue(provider: nil, message: "Could not save statistics snapshot; in-memory results only.")]
            }
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

    private static func loadCachedSnapshot(directory: URL) -> UsageAnalyticsSnapshot {
        let cacheURL = directory.appendingPathComponent("usage-analytics-cache.json")
        do {
            let data = try Data(contentsOf: cacheURL)
            protectCacheFile(directory: directory)

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(UsageAnalyticsSnapshot.self, from: data)
        } catch {
            return .empty
        }
    }

    private static func saveCachedSnapshot(_ snapshot: UsageAnalyticsSnapshot, directory: URL) -> Bool {
        let cacheDirectoryURL = directory
        let cacheURL = directory.appendingPathComponent("usage-analytics-cache.json")
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
            return true
        } catch { return false }
    }

    private static func loadFileCache(directory: URL) -> [String: CodexFileUsageRecord] {
        let fileCacheURL = directory.appendingPathComponent("usage-analytics-files-cache.json")
        do {
            let data = try Data(contentsOf: fileCacheURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([String: CodexFileUsageRecord].self, from: data)
        } catch {
            return [:]
        }
    }

    private static func saveFileCache(_ cache: [String: CodexFileUsageRecord], directory: URL) -> Bool {
        let cacheDirectoryURL = directory
        let fileCacheURL = directory.appendingPathComponent("usage-analytics-files-cache.json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
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
            return true
        } catch { return false }
    }

    private static func protectCacheFile(directory: URL) {
        let cacheDirectoryURL = directory
        let cacheURL = directory.appendingPathComponent("usage-analytics-cache.json")
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
        var next = self
        next.kimi = kimi
        return next
    }

    func withAccountUsage(_ accountUsage: CodexAccountUsage) -> UsageAnalyticsSnapshot {
        var next = self
        next.codex.accountUsage = accountUsage
        return next
    }
}

struct CodexUsageLogEntry {
    let timestamp: Date
    let model: String
    let totals: UsageTotals
}

struct CodexUsageLogReader {
    static let parserRevision = 4
    var calendar = Calendar.autoupdatingCurrent
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
        let parsed = parseEntries(from: file.url)
        return CodexFileUsageRecord(path: file.url.path, modifiedAt: file.modifiedAt, size: file.size,
            dailyModels: dailyModelUsage(entries: parsed.entries), timeZoneIdentifier: calendar.timeZone.identifier,
            parserRevision: Self.parserRevision, rateRevision: CodexAPIRates.revision,
            sourceIssue: file.issue ?? parsed.issue, excluded: file.issue != nil || parsed.unreadable, modifiedAtEpoch: file.modifiedAt.timeIntervalSince1970)
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
        codexLogFileMetadata().filter { $0.issue == nil }.map(\.url)
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
                if FileManager.default.fileExists(atPath: root.path) {
                    filesByName[root.path] = CodexLogFile(url: root, modifiedAt: .distantPast, size: 0, issue: "Unreadable history root: " + root.path)
                }
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
                if filesByName[url.resolvingSymlinksInPath().path] == nil {
                    filesByName[url.resolvingSymlinksInPath().path] = file
                }
            }
        }
        return canonicalUsageFiles(Array(filesByName.values))
    }

    func readEntries(from file: URL) -> [CodexUsageLogEntry] { parseEntries(from: file).entries }

    private func parseEntries(from file: URL) -> (entries: [CodexUsageLogEntry], issue: String?, unreadable: Bool) {
        guard let content = try? String(contentsOf: file, encoding: .utf8) else { return ([], "Unreadable source: " + file.path, true) }
        var malformed = false
        var entries: [CodexUsageLogEntry] = []
        var model = "Unknown model"
        var seenCounters = Set<String>()
        var previousCumulative: [String: Int]?
        for line in content.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { malformed = true; continue }
            guard let payload = object["payload"] as? [String: Any] else { continue }
            let type = object["type"] as? String
            if type == "turn_context" || type == "session_meta" {
                if let reported = payload["model"] as? String, !reported.isEmpty { model = reported }
                continue
            }
            guard type == "event_msg", payload["type"] == nil || payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let usage = info["last_token_usage"] as? [String: Any],
                  let stamp = object["timestamp"] as? String, let timestamp = timestamp(from: stamp) else { continue }
            // Codex can repeat a token_count snapshot without another request.
            if let cumulative = info["total_token_usage"] as? [String: Int], !cumulative.isEmpty {
                if let previousCumulative, cumulative.contains(where: { $0.value < (previousCumulative[$0.key] ?? 0) }) { seenCounters.removeAll() }
                let key = cumulative.keys.sorted().map { "\($0):\(cumulative[$0]!)" }.joined(separator: "|")
                guard seenCounters.insert(key).inserted else { continue }
                previousCumulative = cumulative
            }
            let reported = (usage["model"] as? String) ?? (info["model"] as? String) ?? (payload["model"] as? String) ?? model
            let input = max(0, (usage["input_tokens"] as? Int) ?? 0)
            let details = usage["input_tokens_details"] as? [String: Any] ?? [:]
            let cached = min(input, max(0, (usage["cached_input_tokens"] as? Int) ?? (details["cached_tokens"] as? Int) ?? 0))
            let writes = min(input - cached, max(0, (usage["cache_write_input_tokens"] as? Int) ?? (details["cache_write_tokens"] as? Int) ?? 0))
            let output = max(0, (usage["output_tokens"] as? Int) ?? 0)
            let outputDetails = usage["output_tokens_details"] as? [String: Any] ?? [:]
            let reasoning = min(output, max(0, (usage["reasoning_output_tokens"] as? Int) ?? (outputDetails["reasoning_tokens"] as? Int) ?? 0))
            guard !input.addingReportingOverflow(output).overflow else { malformed = true; continue }
            let totals = usageTotals(model: reported, input: input, cached: cached, cacheWrite: writes,
                                     output: output, reasoning: reasoning)
            entries.append(CodexUsageLogEntry(timestamp: timestamp, model: reported, totals: totals))
        }
        return (entries, malformed ? "Partial accounting source: " + file.path : nil, false)
    }

    private func timestamp(from value: String) -> Date? {
        iso8601WithFractionalSeconds.date(from: value) ?? iso8601.date(from: value)
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
        guard let rates = CodexAPIRates.rates(for: model) else {
            totals.costEstimateAvailable = false
            return totals
        }
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

    func dailyModelUsage(entries: [CodexUsageLogEntry]) -> [DailyModelUsage] {
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

enum CodexAPIRates {
    static let revision = "2026-11-06-standard-v1"
    // USD per million, standard short-context comparison; not subscription charges.
    // https://developers.openai.com/api/docs/pricing (checked 2026-11-06)
    struct Rates { let input: Double; let cachedInput: Double; let cacheWrite: Double; let output: Double }
    static func rates(for model: String) -> Rates? {
        let entries: [String: Rates] = [
            "gpt-6-astra": Rates(input: 10, cachedInput: 1, cacheWrite: 12.5, output: 50),
            "gpt-6.1-sol": Rates(input: 2, cachedInput: 0.1, cacheWrite: 2.5, output: 10),
            "gpt-6.1-terra": Rates(input: 1, cachedInput: 0.05, cacheWrite: 1.25, output: 5),
            "gpt-6-luna": Rates(input: 0.1, cachedInput: 0.01, cacheWrite: 0.125, output: 0.5)
        ]
        return entries[model.lowercased()]
    }
}
