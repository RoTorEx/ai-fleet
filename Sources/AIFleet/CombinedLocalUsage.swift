import Foundation

/// A derived local view; provider caches and subscription-wide totals remain untouched.
func combinedLocalUsage(_ snapshot: UsageAnalyticsSnapshot, providers: Set<String>,
                        calendar: Calendar = .autoupdatingCurrent) -> CodexUsageAnalytics {
    let sources: [(String, String, CodexUsageAnalytics?)] = [
        ("codex", "Codex", snapshot.codex), ("claude", "Claude", snapshot.claude),
        ("kimi", "Kimi", snapshot.kimiUsage), ("qwen", "Qwen", snapshot.qwen)
    ]
    var result = CodexUsageAnalytics.empty
    var days: [Date: UsageTotals] = [:]
    var names: [String] = []
    for (id, name, optional) in sources where providers.contains(id) {
        names.append(name)
        guard let source = optional else { continue }
        // Empty unsupported-price datasets must not invalidate a populated provider's estimate.
        if source.total.totalTokens > 0 { result.total.add(source.total) }
        if source.today.totalTokens > 0 { result.today.add(source.today) }
        if source.sevenDays.totalTokens > 0 { result.sevenDays.add(source.sevenDays) }
        if source.thirtyDays.totalTokens > 0 { result.thirtyDays.add(source.thirtyDays) }
        result.fileCount += source.fileCount
        result.eventCount += source.eventCount
        for usage in source.daily {
            let day = calendar.startOfDay(for: usage.day)
            if days[day] == nil { days[day] = .zero }
            days[day]?.add(usage.totals)
        }
        result.models += source.models.map {
            ModelUsage(model: "\(name) · \($0.model)", totals: $0.totals, events: $0.events)
        }
        result.dailyModels += source.dailyModels.map {
            DailyModelUsage(day: calendar.startOfDay(for: $0.day), model: "\(name) · \($0.model)",
                            totals: $0.totals, events: $0.events)
        }
    }
    result.daily = days.map { DailyUsage(day: $0.key, totals: $0.value) }.sorted { $0.day < $1.day }
    result.models.sort { $0.totals.totalTokens > $1.totals.totalTokens }
    result.source = "Local logs on this Mac · " + names.joined(separator: ", ")
    result.accountUsage = nil
    return result
}
