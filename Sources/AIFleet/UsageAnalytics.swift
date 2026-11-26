import Foundation

struct UsageAnalyticsSnapshot: Codable, Equatable {
    static let currentRevision = 6

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
    var scannedThrough: Date? = nil
    var lastScan: UsageLogScanSummary? = nil
    var lastLoadDuration: TimeInterval?
    var hourlyHistoryDays: Int? = nil

    static let empty = UsageAnalyticsSnapshot(
        codex: .empty,
        kimi: .empty,
        rateRevision: CodexAPIRates.revision,
        timeZoneIdentifier: TimeZone.current.identifier,
        refreshedAt: nil,
        lastLoadDuration: nil
    )

    func needsRebuild(timeZone: TimeZone) -> Bool {
        statisticsRevision != Self.currentRevision || rateRevision != CodexAPIRates.revision
            || timeZoneIdentifier != timeZone.identifier
    }
}

enum UsageLogRefreshMode: String, Codable {
    case incremental
    case rebuild
}

struct UsageLogScanSummary: Codable, Equatable {
    let mode: UsageLogRefreshMode
    var reused = 0
    var resumed = 0
    var replayed = 0

    var files: Int { reused + resumed + replayed }
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
    var hourlyModels: [HourlyModelUsage] = []

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
        accountUsage: CodexAccountUsage? = nil,
        hourlyModels: [HourlyModelUsage] = []
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
        self.hourlyModels = hourlyModels
    }

    private enum CodingKeys: String, CodingKey {
        case total, today, sevenDays, thirtyDays, daily, models, dailyModels
        case eventCount, fileCount, source, accountUsage, hourlyModels
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
        hourlyModels = try container.decodeIfPresent([HourlyModelUsage].self, forKey: .hourlyModels) ?? []
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
    var identity: String? = nil
    var changeEpoch: Double? = nil
    var codexHeader: CodexJournalHeader? = nil
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
    var hourlyModels: [HourlyModelUsage]? = nil
    var hourlyHistoryDays: Int? = nil
    var identity: String? = nil
    var changeEpoch: Double? = nil
    var codexHeader: CodexJournalHeader? = nil
    var checkpoint: UsageJournalCheckpoint? = nil

    var eventCount: Int {
        dailyModels.reduce(0) { $0 + $1.events }
    }

    func matches(_ file: CodexLogFile, timeZone: TimeZone = .autoupdatingCurrent, revision: Int? = nil) -> Bool {
        (excluded != true && file.issue == nil)
            && (revision == nil || (parserRevision == revision && rateRevision == CodexAPIRates.revision && hourlyModels != nil))
            && timeZoneIdentifier == timeZone.identifier
            && matchesMetadata(file, allowRoundedDate: revision == nil)
    }

    func matchesMetadata(_ file: CodexLogFile, allowRoundedDate: Bool = false) -> Bool {
        guard size == file.size,
              identity.map({ file.identity == nil || file.identity == $0 }) != false,
              changeEpoch.map({ file.changeEpoch == nil || file.changeEpoch == $0 }) != false else { return false }
        if let modifiedAtEpoch { return modifiedAtEpoch == file.modifiedAt.timeIntervalSince1970 }
        return allowRoundedDate && abs(modifiedAt.timeIntervalSince(file.modifiedAt)) < 1
    }

    func coversHourlyHistory(since day: Date) -> Bool {
        hourlyHistoryDays == QuotaHistoryRange.retained.rawValue || dailyModels.allSatisfy { $0.day < day }
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

    private var activeRefresh: UsageLogRefreshMode?
    private var pendingRefresh: UsageLogRefreshMode?
    private var scheduleTimer: Timer?
    private var unsavedFileCache: [String: CodexFileUsageRecord]?
    private let cacheRoot: URL
    private let discoverFiles: @Sendable ([String: CodexFileUsageRecord]) -> [CodexLogFile]
    private var timeZoneObserver: NSObjectProtocol?

    init(cacheDirectory: URL? = nil, discoverFiles: (@Sendable () -> [CodexLogFile])? = nil, preferences: UserDefaults = .standard) {
        self.preferences = preferences
        if let stored = preferences.string(forKey: "analytics.selectedProviders") {
            selectedProviders = Set(stored.split(separator: ",").compactMap { StatisticsProvider(rawValue: String($0)) })
        }
        let root = cacheDirectory ?? Self.cacheDirectoryURL
        cacheRoot = root
        self.discoverFiles = { known in
            if let discoverFiles { return discoverFiles() }
            return CodexUsageLogReader().codexLogFileMetadata(known: known) + ClaudeUsageLogReader().logFileMetadata()
                + LocalUsageProvider.allCases.flatMap { $0.logFileMetadata() }
        }
        let cached = Self.loadCachedSnapshot(directory: root)
        snapshot = cached
        snapshot.unattributedAccountUsage = cached.unattributedAccountUsage ?? cached.codex.accountUsage
        snapshot.codex.accountUsage = nil
        if cached.needsRebuild(timeZone: .current) {
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
        updateKimi(kimi: kimi)
        refreshLocalHistory()
    }

    func refreshLocalHistory(_ mode: UsageLogRefreshMode = .incremental) {
        startRefresh(mode)
    }

    func updateKimi(kimi: ProviderStatus) {
        let kimiAnalytics = Self.kimiAnalytics(from: kimi.limitWindows)
        if snapshot.kimi != kimiAnalytics { snapshot = snapshot.withKimi(kimiAnalytics) }
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
                Task { @MainActor in
                    self?.startRefresh(.incremental, afterActive: true)
                    self?.rescheduleDailyRefresh()
                }
            }
        }
        if snapshot.needsRebuild(timeZone: .current)
            || snapshot.hourlyHistoryDays != QuotaHistoryRange.retained.rawValue {
            refreshLocalHistory()
        }
        rescheduleDailyRefresh(catchUp: true)
    }

    func rescheduleDailyRefresh(catchUp: Bool = false) {
        scheduleTimer?.invalidate()
        scheduleTimer = nil

        let settings = AppSettings.shared
        guard settings.analyticsAutoRefreshEnabled else { return }
        let now = Date()
        let calendar = Calendar.current
        let minutes = settings.analyticsRefreshMinutes
        let fireDate = nextDailyRefreshDate(after: now, minutesAfterMidnight: minutes, calendar: calendar)
        if catchUp, let yesterday = calendar.date(byAdding: .day, value: -1, to: now) {
            let lastScheduled = nextDailyRefreshDate(after: yesterday, minutesAfterMidnight: minutes, calendar: calendar)
            if lastScheduled <= now, snapshot.refreshedAt.map({ $0 < lastScheduled }) ?? true {
                refreshLocalHistory()
            }
        }
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

    private func startRefresh(_ mode: UsageLogRefreshMode, afterActive: Bool = false) {
        if let activeRefresh {
            if (afterActive || (mode == .rebuild && activeRefresh == .incremental)), pendingRefresh != .rebuild {
                pendingRefresh = mode
            }
            return
        }

        activeRefresh = mode
        isRefreshing = true
        let startedAt = Date()
        let calendar = Calendar.current
        let discover = discoverFiles
        let directory = cacheRoot
        let unsaved = unsavedFileCache
        progress = UsageAnalyticsLoadProgress(isLoading: true, processedFiles: 0, totalFiles: 0,
            startedAt: startedAt, lastDuration: snapshot.lastLoadDuration, lastCompletedAt: snapshot.refreshedAt,
            currentFileName: nil)

        Task {
            let scan = await Task.detached(priority: .background) { [weak self] in
                let previous = unsaved ?? Self.loadFileCache(directory: directory)
                return await Self.scanLogs(mode: mode, using: previous, startedAt: startedAt, calendar: calendar,
                    discover: discover) { processed, total, name in
                    await self?.reportProgress(processed: processed, total: total, name: name)
                }
            }.value

            guard calendar.timeZone.identifier == TimeZone.current.identifier else {
                pendingRefresh = pendingRefresh ?? mode
                finishRefresh()
                return
            }

            var next = scan.snapshot.withKimi(snapshot.kimi)
            next.unattributedAccountUsage = snapshot.unattributedAccountUsage
            next.legacyLocalHistory = snapshot.legacyLocalHistory
            let savedSnapshot = next
            let (savedFiles, savedTotals) = await Task.detached(priority: .background) {
                let savedFiles = (!scan.cacheChanged && unsaved == nil) || Self.saveFileCache(scan.cache, directory: directory)
                let savedTotals = Self.saveCachedSnapshot(savedSnapshot, directory: directory)
                return (savedFiles, savedTotals)
            }.value
            unsavedFileCache = savedFiles ? nil : scan.cache
            guard calendar.timeZone.identifier == TimeZone.current.identifier else {
                pendingRefresh = pendingRefresh ?? mode
                finishRefresh()
                return
            }

            var issues = next.sourceIssues ?? []
            if !savedFiles {
                issues.append(StatisticsSourceIssue(provider: nil, message: "Could not save incremental file cache."))
            }
            if !savedTotals {
                issues.append(StatisticsSourceIssue(provider: nil, message: "Could not save statistics snapshot; in-memory results only."))
            }
            next.sourceIssues = issues
            snapshot = next.withKimi(snapshot.kimi)
            let count = next.lastScan?.files ?? 0
            progress = UsageAnalyticsLoadProgress(isLoading: false, processedFiles: count, totalFiles: count,
                startedAt: nil, lastDuration: next.lastLoadDuration, lastCompletedAt: next.refreshedAt,
                currentFileName: nil)
            finishRefresh()
        }
    }

    private func reportProgress(processed: Int, total: Int, name: String?) {
        progress.processedFiles = processed
        progress.totalFiles = total
        progress.currentFileName = name
    }

    private func finishRefresh() {
        activeRefresh = nil
        if let next = pendingRefresh {
            pendingRefresh = nil
            startRefresh(next)
        } else {
            isRefreshing = false
        }
    }

    private struct LogScan {
        let snapshot: UsageAnalyticsSnapshot
        let cache: [String: CodexFileUsageRecord]
        let cacheChanged: Bool
    }

    nonisolated private static func scanLogs(
        mode: UsageLogRefreshMode, using previous: [String: CodexFileUsageRecord],
        startedAt: Date, calendar: Calendar, discover: ([String: CodexFileUsageRecord]) -> [CodexLogFile],
        progress: (Int, Int, String?) async -> Void
    ) async -> LogScan {
        let known = mode == .incremental ? previous : [:]
        let files = discover(known).sorted {
            $0.modifiedAt == $1.modifiedAt ? $0.url.path < $1.url.path : $0.modifiedAt > $1.modifiedAt
        }
        let firstDay = calendar.startOfDay(for: UsageHours(now: startedAt, calendar: calendar, range: .retained).start)
        let previousDay = calendar.date(byAdding: .day, value: -1, to: startedAt) ?? startedAt
        let checkpointCutoff = previousDay.addingTimeInterval(-10 * 60)
        let reader = CodexUsageLogReader(calendar: calendar)
        var remainingCheckpointEvents = 50_000
        var summary = UsageLogScanSummary(mode: mode)
        var next: [String: CodexFileUsageRecord] = [:]
        next.reserveCapacity(files.count)
        var providers: [String: StatisticsProvider] = [:]
        providers.reserveCapacity(files.count)
        await progress(0, files.count, nil)
        var lastProgress = ProcessInfo.processInfo.systemUptime

        for (index, file) in files.enumerated() {
            let provider = statisticsProvider(for: file.url.path)
            providers[file.url.path] = provider
            let cached = known[file.url.path]
            let keepCheckpoint = file.modifiedAt >= checkpointCutoff && remainingCheckpointEvents > 0
            var record: CodexFileUsageRecord
            if var reusable = cached, reusable.matches(file, timeZone: calendar.timeZone, revision: provider.parserRevision),
               reusable.coversHourlyHistory(since: firstDay) {
                reusable.identity = file.identity
                reusable.changeEpoch = file.changeEpoch
                reusable.codexHeader = file.codexHeader
                record = reusable
                summary.reused += 1
            } else {
                let checkpoint = cached.flatMap {
                    $0.parserRevision == provider.parserRevision && $0.rateRevision == CodexAPIRates.revision ? $0.checkpoint : nil
                }
                record = autoreleasepool {
                    let parsed = file.issue == nil
                        ? readLog(file.url, provider: provider, reader: reader, checkpoint: checkpoint, saveCheckpoint: keepCheckpoint)
                        : ParsedUsageJournal()
                    if parsed.resumed { summary.resumed += 1 } else { summary.replayed += 1 }
                    return reader.usageRecord(for: file, provider: provider, parsed: parsed)
                }
            }
            if keepCheckpoint, let checkpoint = record.checkpoint, checkpoint.state.eventCount <= remainingCheckpointEvents {
                remainingCheckpointEvents -= max(1, checkpoint.state.eventCount)
            } else {
                record.checkpoint = nil
            }
            next[file.url.path] = record
            let uptime = ProcessInfo.processInfo.systemUptime
            if uptime - lastProgress >= 0.25 {
                await progress(index + 1, files.count, file.url.lastPathComponent)
                lastProgress = uptime
            }
        }

        let active = next.values.filter { $0.excluded != true }.sorted { $0.path < $1.path }
        let byProvider = Dictionary(grouping: active) { providers[$0.path] ?? .codex }
        let codexRecords = byProvider[.codex] ?? []
        let claudeRecords = byProvider[.claude] ?? []
        var claude = reader.analytics(from: claudeRecords, fileCount: claudeRecords.count)
        claude.source = "~/.claude/projects"
        let completedAt = Date()
        var snapshot = UsageAnalyticsSnapshot(
            codex: reader.analytics(from: codexRecords, fileCount: codexRecords.count), kimi: .empty, claude: claude,
            kimiUsage: LocalUsageProvider.kimi.analytics(from: byProvider[.kimi] ?? []),
            qwen: LocalUsageProvider.qwen.analytics(from: byProvider[.qwen] ?? []),
            refreshedAt: completedAt, scannedThrough: startedAt, lastScan: summary,
            lastLoadDuration: completedAt.timeIntervalSince(startedAt))
        snapshot.statisticsRevision = UsageAnalyticsSnapshot.currentRevision
        snapshot.rateRevision = CodexAPIRates.revision
        snapshot.timeZoneIdentifier = calendar.timeZone.identifier
        snapshot.hourlyHistoryDays = QuotaHistoryRange.retained.rawValue
        snapshot.sourceIssues = next.values.compactMap { record in
            record.sourceIssue.map { StatisticsSourceIssue(provider: providers[record.path], message: $0) }
        } + previous.keys.filter { next[$0] == nil && !FileManager.default.fileExists(atPath: $0) }.map {
            StatisticsSourceIssue(provider: statisticsProvider(for: $0), message: "Missing source: " + $0)
        }

        // Retain aggregates for missing sources for recovery, but age out their
        // checkpoints and keep them out of the current totals.
        let recentHours = UsageHours(now: completedAt, calendar: calendar, range: .retained)
        let cache = previous.merging(next) { _, current in current }.mapValues { value in
            var record = value
            if next[value.path] == nil { record.checkpoint = nil }
            record.hourlyModels?.removeAll { !recentHours.contains($0.hour) }
            return record
        }
        return LogScan(snapshot: snapshot, cache: cache, cacheChanged: cache != previous)
    }

    nonisolated private static func readLog(_ file: URL, provider: StatisticsProvider, reader: CodexUsageLogReader,
                                           checkpoint: UsageJournalCheckpoint?, saveCheckpoint: Bool) -> ParsedUsageJournal {
        switch provider {
        case .codex: return reader.parseEntries(from: file, checkpoint: checkpoint, saveCheckpoint: saveCheckpoint)
        case .claude: return ClaudeUsageLogReader().parseEntries(from: file, checkpoint: checkpoint, saveCheckpoint: saveCheckpoint)
        case .kimi: return KimiUsageLogReader().parseEntries(from: file, checkpoint: checkpoint, saveCheckpoint: saveCheckpoint)
        case .qwen: return QwenUsageLogReader().parseEntries(from: file, checkpoint: checkpoint, saveCheckpoint: saveCheckpoint)
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

    nonisolated private static func saveCachedSnapshot(_ snapshot: UsageAnalyticsSnapshot, directory: URL) -> Bool {
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
            let data = try encoder.encode(snapshot)
            try data.write(to: cacheURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: cacheURL.path
            )
            return true
        } catch { return false }
    }

    nonisolated private static func loadFileCache(directory: URL) -> [String: CodexFileUsageRecord] {
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

    nonisolated private static func saveFileCache(_ cache: [String: CodexFileUsageRecord], directory: URL) -> Bool {
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
            ofItemAtPath: directory.appendingPathComponent("usage-analytics-files-cache.json").path
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

struct CodexUsageLogEntry: Codable, Equatable {
    private let timeIntervalSinceReferenceDate: TimeInterval
    let model: String
    let totals: UsageTotals

    var timestamp: Date { Date(timeIntervalSinceReferenceDate: timeIntervalSinceReferenceDate) }

    init(timestamp: Date, model: String, totals: UsageTotals) {
        timeIntervalSinceReferenceDate = timestamp.timeIntervalSinceReferenceDate
        self.model = model
        self.totals = totals
    }
}

struct CodexUsageLogReader {
    var calendar = Calendar.autoupdatingCurrent
    private let timestamps = UsageJournalTimestamps()

    func read() -> CodexUsageAnalytics {
        let files = codexLogFiles()
        var entries: [CodexUsageLogEntry] = []

        for file in files {
            entries.append(contentsOf: readEntries(from: file))
        }

        return analytics(from: entries, fileCount: files.count)
    }

    func analytics(from entries: [CodexUsageLogEntry], fileCount: Int) -> CodexUsageAnalytics {
        var result = analytics(from: dailyModelUsage(entries: entries), fileCount: fileCount)
        result.hourlyModels = HourlyModelUsage.aggregate(entries: entries, now: Date(), calendar: calendar)
        return result
    }

    func analytics(from records: [CodexFileUsageRecord], fileCount: Int) -> CodexUsageAnalytics {
        var result = analytics(from: mergeDailyModels(records.lazy.flatMap(\.dailyModels)), fileCount: fileCount)
        result.hourlyModels = HourlyModelUsage.merge(records.lazy.flatMap { $0.hourlyModels ?? [] },
                                                   in: UsageHours(now: Date(), calendar: calendar, range: .retained))
        return result
    }

    func usageRecord(for file: CodexLogFile, checkpoint: UsageJournalCheckpoint? = nil,
                     saveCheckpoint: Bool = false) -> CodexFileUsageRecord {
        usageRecord(for: file, provider: .codex, parsed: parseEntries(from: file.url,
            checkpoint: checkpoint, saveCheckpoint: saveCheckpoint))
    }

    func usageRecord(for file: CodexLogFile, provider: StatisticsProvider,
                     parsed: ParsedUsageJournal) -> CodexFileUsageRecord {
        CodexFileUsageRecord(path: file.url.path, modifiedAt: file.modifiedAt, size: file.size,
            dailyModels: dailyModelUsage(entries: parsed.entries), timeZoneIdentifier: calendar.timeZone.identifier,
            parserRevision: provider.parserRevision, rateRevision: CodexAPIRates.revision,
            sourceIssue: file.issue ?? parsed.issue, excluded: file.issue != nil || parsed.unreadable,
            modifiedAtEpoch: file.modifiedAt.timeIntervalSince1970,
            hourlyModels: HourlyModelUsage.aggregate(entries: parsed.entries, now: Date(), calendar: calendar),
            hourlyHistoryDays: QuotaHistoryRange.retained.rawValue, identity: file.identity,
            changeEpoch: file.changeEpoch, codexHeader: file.codexHeader, checkpoint: parsed.checkpoint)
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

    func codexLogFileMetadata(roots suppliedRoots: [URL]? = nil,
                              known: [String: CodexFileUsageRecord] = [:]) -> [CodexLogFile] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = suppliedRoots ?? [
            home.appendingPathComponent(".codex/sessions"),
            home.appendingPathComponent(".codex/archived_sessions")
        ]

        return canonicalUsageFiles(discoverUsageLogs(in: roots), codexCopies: true, known: known)
    }

    func readEntries(from file: URL) -> [CodexUsageLogEntry] { parseEntries(from: file).entries }

    func parseEntries(from file: URL, checkpoint: UsageJournalCheckpoint? = nil,
                      saveCheckpoint: Bool = false) -> ParsedUsageJournal {
        readUsageJournal(file, checkpoint: checkpoint, saveCheckpoint: saveCheckpoint) { state, line, _ in
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { state.partial = true; return }
            guard let payload = object["payload"] as? [String: Any] else { return }
            let type = object["type"] as? String
            if type == "turn_context" || type == "session_meta" {
                if let reported = payload["model"] as? String, !reported.isEmpty { state.model = reported }
                return
            }
            guard type == "event_msg", payload["type"] == nil || payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let usage = info["last_token_usage"] as? [String: Any],
                  let stamp = object["timestamp"] as? String, let timestamp = timestamps.date(from: stamp) else { return }
            // Codex can repeat a token_count snapshot without another request.
            if let cumulative = info["total_token_usage"] as? [String: Int], !cumulative.isEmpty {
                if let previousCumulative = state.previousCumulative,
                   cumulative.contains(where: { $0.value < (previousCumulative[$0.key] ?? 0) }) { state.seenCounters.removeAll() }
                let key = cumulative.keys.sorted().map { "\($0):\(cumulative[$0]!)" }.joined(separator: "|")
                guard state.seenCounters.insert(key).inserted else { return }
                state.previousCumulative = cumulative
            }
            let reported = (usage["model"] as? String) ?? (info["model"] as? String) ?? (payload["model"] as? String) ?? state.model
            let input = max(0, (usage["input_tokens"] as? Int) ?? 0)
            let details = usage["input_tokens_details"] as? [String: Any] ?? [:]
            let cached = min(input, max(0, (usage["cached_input_tokens"] as? Int) ?? (details["cached_tokens"] as? Int) ?? 0))
            let writes = min(input - cached, max(0, (usage["cache_write_input_tokens"] as? Int) ?? (details["cache_write_tokens"] as? Int) ?? 0))
            let output = max(0, (usage["output_tokens"] as? Int) ?? 0)
            let outputDetails = usage["output_tokens_details"] as? [String: Any] ?? [:]
            let reasoning = min(output, max(0, (usage["reasoning_output_tokens"] as? Int) ?? (outputDetails["reasoning_tokens"] as? Int) ?? 0))
            guard !input.addingReportingOverflow(output).overflow else { state.partial = true; return }
            let totals = usageTotals(model: reported, input: input, cached: cached, cacheWrite: writes,
                                     output: output, reasoning: reasoning)
            state.entries.append(CodexUsageLogEntry(timestamp: timestamp, model: reported, totals: totals))
        }
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

    private func mergeDailyModels(_ values: some Sequence<DailyModelUsage>) -> [DailyModelUsage] {
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
    static let revision = "2026-11-09-standard-v3"
    // USD per million, standard short-context comparison; not subscription charges.
    // https://developers.openai.com/api/docs/pricing (checked 2026-11-06)
    struct Rates { let input: Double; let cachedInput: Double; let cacheWrite: Double; let output: Double }
    static func rates(for model: String) -> Rates? {
        let entries: [String: Rates] = [
            "gpt-6-astra": Rates(input: 10, cachedInput: 1, cacheWrite: 12.5, output: 50),
            "gpt-6.1-sol": Rates(input: 2, cachedInput: 0.1, cacheWrite: 2.5, output: 10),
            "gpt-6.1-terra": Rates(input: 1, cachedInput: 0.05, cacheWrite: 1.25, output: 5),
            "gpt-6-luna": Rates(input: 0.1, cachedInput: 0.01, cacheWrite: 0.125, output: 0.5),
            // No published rate; estimated at GPT-6.1 Sol by the user's choice.
            "codex-auto-review": Rates(input: 2, cachedInput: 0.1, cacheWrite: 2.5, output: 10)
        ]
        return entries[model.lowercased()]
    }
}
