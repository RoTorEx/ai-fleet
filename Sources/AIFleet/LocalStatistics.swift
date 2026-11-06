import Foundation

struct StatisticsSourceIssue: Codable, Equatable {
    let provider: StatisticsProvider?
    let message: String
}

enum StatisticsProvider: String, CaseIterable, Codable { case codex, claude, kimi, qwen }

struct StatisticsCost: Equatable {
    let fullEstimateUSD: Double?
    let knownEstimateUSD: Double
    let pricedTokens: Int
    let recordedTokens: Int
    var coverage: Double? { recordedTokens > 0 ? Double(pricedTokens) / Double(recordedTokens) : nil }
}

/// Standard local roots only. Account reports and quota snapshots never enter this result.
struct LocalStatistics: Equatable {
    let scope = "standardLocalRoots"
    let providers: Set<StatisticsProvider>
    let start: Date?
    let end: Date
    let dailyModels: [DailyModelUsage]
    let totals: UsageTotals
    let cost: StatisticsCost
    let sourceIssues: [String]
    let stale: Bool
    var emptySelection: Bool { providers.isEmpty }

    var models: [ModelUsage] {
        var result: [String: ModelUsage] = [:]
        for row in dailyModels {
            if result[row.model] == nil { result[row.model] = ModelUsage(model: row.model, totals: .zero, events: 0) }
            result[row.model]?.totals.add(row.totals); result[row.model]?.events += row.events
        }
        return result.values.sorted { $0.model < $1.model }
    }
    var daily: [DailyUsage] {
        var result: [Date: UsageTotals] = [:]
        for row in dailyModels { result[row.day, default: .zero].add(row.totals) }
        return result.keys.sorted().map { DailyUsage(day: $0, totals: result[$0]!) }
    }

    init(snapshot: UsageAnalyticsSnapshot, providers: Set<StatisticsProvider> = Set(StatisticsProvider.allCases),
         days: Int? = nil, now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) {
        self.providers = providers
        let endDay = calendar.startOfDay(for: now)
        let startDay = days.flatMap { calendar.date(byAdding: .day, value: -(max(1, $0) - 1), to: endDay) }
        end = endDay; start = startDay
        let sources: [(StatisticsProvider, CodexUsageAnalytics?)] = [(.codex, snapshot.codex), (.claude, snapshot.claude), (.kimi, snapshot.kimiUsage), (.qwen, snapshot.qwen)]
        let legacy = snapshot.statisticsRevision != 4 || snapshot.rateRevision != CodexAPIRates.revision || snapshot.timeZoneIdentifier != calendar.timeZone.identifier
        var rows: [DailyModelUsage] = []
        for (provider, source) in sources where providers.contains(provider) {
            for row in selectedLocalRows(source ?? .empty, start: startDay, end: endDay, calendar: calendar) {
                let day = calendar.startOfDay(for: row.day)
                guard day <= endDay, startDay.map({ day >= $0 }) ?? true else { continue }
                var totals = row.totals
                if legacy { totals.estimatedCostUSD = 0; totals.costEstimateAvailable = false; totals.pricedTokens = 0 }
                rows.append(DailyModelUsage(day: day, model: provider.rawValue + " · " + row.model, totals: totals, events: row.events))
            }
        }
        dailyModels = rows.sorted { $0.day == $1.day ? $0.model < $1.model : $0.day < $1.day }
        var selected = rows.reduce(into: UsageTotals.zero) { $0.add($1.totals) }
        stale = legacy
        if stale { selected.estimatedCostUSD = 0; selected.costEstimateAvailable = false; selected.pricedTokens = 0 }
        totals = selected
        let issues = (snapshot.sourceIssues ?? []).filter { $0.provider.map(providers.contains) ?? true }.map(\.message) + (stale ? ["Parser/catalog/time-zone rebuild pending"] : []) + (totals.overflowDetected == true ? ["Accounting sum overflow; result is incomplete"] : [])
        let priced = totals.pricedTokens ?? (totals.hasCostEstimate ? totals.totalTokens : 0)
        cost = StatisticsCost(fullEstimateUSD: issues.isEmpty && totals.totalTokens > 0 && priced == totals.totalTokens ? totals.estimatedCostUSD : nil,
                              knownEstimateUSD: totals.estimatedCostUSD, pricedTokens: priced, recordedTokens: totals.totalTokens)
        sourceIssues = issues
    }
}

extension UsageAnalyticsService {
    func localStatistics(providers: Set<StatisticsProvider>? = nil, days: Int? = nil,
                         now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> LocalStatistics {
        LocalStatistics(snapshot: snapshot, providers: providers ?? selectedProviders, days: days, now: now, calendar: calendar)
    }
}

struct CodexUsageSelection: Equatable {
    let totals: UsageTotals
    let totalTokens: Int
    let estimatedCostUSD: Double
    let daily: [CodexSelectedDay]
    let models: [ModelUsage]
    let eventCount: Int
    let usesAccountUsage: Bool
}

struct CodexSelectedDay: Identifiable, Equatable {
    let day: Date
    let tokens: Int
    let estimatedCostUSD: Double?

    var id: Date { day }
}

func codexUsageSelection(
    from codex: CodexUsageAnalytics,
    start: Date?,
    end: Date?,
    calendar: Calendar = .autoupdatingCurrent
) -> CodexUsageSelection {
    let startDay = start.map { calendar.startOfDay(for: $0) }
    let endDay = end.map { calendar.startOfDay(for: $0) }
    let includes: (Date) -> Bool = { date in
        let day = calendar.startOfDay(for: date)
        return (startDay == nil || day >= startDay!) && (endDay == nil || day <= endDay!)
    }

    let localDaily = codex.daily.filter { includes($0.day) }
    let selectedDailyModels = selectedLocalRows(codex, start: start, end: end, calendar: calendar)
    let totals = localDaily.reduce(into: UsageTotals.zero) { $0.add($1.totals) }
    var modelBuckets: [String: ModelUsage] = [:]
    for usage in selectedDailyModels {
        if modelBuckets[usage.model] == nil {
            modelBuckets[usage.model] = ModelUsage(model: usage.model, totals: .zero, events: 0)
        }
        modelBuckets[usage.model]?.totals.add(usage.totals)
        modelBuckets[usage.model]?.events += usage.events
    }
    let models = modelBuckets.values.sorted {
        if $0.totals.estimatedCostUSD != $1.totals.estimatedCostUSD { return $0.totals.estimatedCostUSD > $1.totals.estimatedCostUSD }
        return $0.totals.totalTokens > $1.totals.totalTokens
    }
    let isAllTime = startDay == nil && endDay == nil
    let selectedTotals = isAllTime && localDaily.isEmpty ? codex.total : totals
    // Account day buckets have no event timestamps to regroup at local midnight.
    // Keep date-based views on the same local accounting source as their details.
    let displayDaily = localDaily.map {
        CodexSelectedDay(day: $0.day, tokens: $0.totals.totalTokens, estimatedCostUSD: $0.totals.hasCostEstimate ? $0.totals.estimatedCostUSD : nil)
    }
    return CodexUsageSelection(
        totals: selectedTotals,
        totalTokens: selectedTotals.totalTokens,
        estimatedCostUSD: selectedTotals.estimatedCostUSD,
        daily: displayDaily,
        models: selectedDailyModels.isEmpty && isAllTime ? codex.models : models,
        eventCount: selectedDailyModels.isEmpty && isAllTime ? codex.eventCount : selectedDailyModels.reduce(0) { $0 + $1.events },
        usesAccountUsage: false
    )
}


func selectedLocalRows(_ source: CodexUsageAnalytics, start: Date?, end: Date?, calendar: Calendar) -> [DailyModelUsage] {
    let from = start.map { calendar.startOfDay(for: $0) }, to = end.map { calendar.startOfDay(for: $0) }
    return source.dailyModels.filter {
        let day = calendar.startOfDay(for: $0.day)
        return (from.map { day >= $0 } ?? true) && (to.map { day <= $0 } ?? true)
    }
}
