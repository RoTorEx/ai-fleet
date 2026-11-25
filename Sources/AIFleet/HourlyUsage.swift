import Foundation

struct UsageHours {
    static let count = 72
    static let hour: TimeInterval = 3_600
    let start: Date
    let last: Date

    init(now: Date, calendar: Calendar = .autoupdatingCurrent) {
        last = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        start = last.addingTimeInterval(-Double(Self.count - 1) * Self.hour)
    }

    var starts: [Date] {
        (0..<Self.count).map { start.addingTimeInterval(Double($0) * Self.hour) }
    }

    func contains(_ date: Date) -> Bool { start <= date && date <= last }
}

struct HourlyModelUsage: Codable, Equatable {
    let hour: Date
    let model: String
    var tokens: UsageTotals

    private struct Key: Hashable {
        let hour: Date
        let model: String
    }

    static func aggregate(entries: [CodexUsageLogEntry], now: Date, calendar: Calendar) -> [Self] {
        let hours = UsageHours(now: now, calendar: calendar)
        return merge(entries.lazy.compactMap { entry in
            guard entry.timestamp >= hours.start, entry.timestamp <= now,
                  let hour = calendar.dateInterval(of: .hour, for: entry.timestamp)?.start else { return nil }
            return Self(hour: hour, model: entry.model, tokens: entry.totals)
        }, in: hours)
    }

    static func merge(_ values: some Sequence<Self>, in hours: UsageHours) -> [Self] {
        var totals: [Key: UsageTotals] = [:]
        for value in values where hours.contains(value.hour) {
            totals[Key(hour: value.hour, model: value.model), default: .zero].add(value.tokens)
        }
        return totals.map { Self(hour: $0.key.hour, model: $0.key.model, tokens: $0.value) }
            .sorted { $0.hour == $1.hour ? $0.model < $1.model : $0.hour < $1.hour }
    }
}

enum LocalTokenSeries: String, CaseIterable, Identifiable {
    case uncachedInput = "Uncached input"
    case cache = "Cache"
    case output = "Output"

    var id: Self { self }

    func count(in totals: UsageTotals) -> Int? {
        switch self {
        case .uncachedInput: return totals.billableInputTokens
        case .cache: return checkedStatisticsSum([totals.cachedInputTokens, totals.cacheWriteInputTokens])
        case .output: return totals.outputTokens
        }
    }
}

struct LocalTokenHistory {
    struct Hour: Identifiable {
        let start: Date
        let tokens: UsageTotals?
        var id: Date { start }
    }

    let models: [String]
    let hours: [Hour]
    let scannedAt: Date?

    init(snapshot: UsageAnalyticsSnapshot, provider: StatisticsProvider, model: String? = nil,
         now: Date, calendar: Calendar = .autoupdatingCurrent) {
        let history: CodexUsageAnalytics?
        switch provider {
        case .codex: history = snapshot.codex
        case .claude: history = snapshot.claude
        case .kimi: history = snapshot.kimiUsage
        case .qwen: history = snapshot.qwen
        }
        let window = UsageHours(now: now, calendar: calendar)
        let rows = snapshot.needsRebuild(timeZone: calendar.timeZone) ? []
            : (history?.hourlyModels ?? []).filter { window.contains($0.hour) }
        let availableModels = Set(rows.map(\.model)).sorted()
        models = availableModels
        let selectedModel = model.flatMap { availableModels.contains($0) ? $0 : nil }
        scannedAt = snapshot.refreshedAt
        var totals: [Date: UsageTotals] = [:]
        for row in rows where selectedModel == nil || row.model == selectedModel {
            totals[row.hour, default: .zero].add(row.tokens)
        }
        let earliestDay = history?.dailyModels.first?.day
        hours = window.starts.map { start in
            guard !rows.isEmpty, let scannedAt = snapshot.refreshedAt, start <= scannedAt,
                  earliestDay.map({ $0 <= start }) != false else {
                return Hour(start: start, tokens: nil)
            }
            let tokens = totals[start, default: .zero]
            return Hour(start: start, tokens: tokens.overflowDetected == true ? nil : tokens)
        }
    }
}
