import XCTest
@testable import AIFleet

final class CombinedLocalUsageTests: XCTestCase {
    private func usage(_ tokens: Int, day: Date, priced: Bool = true) -> CodexUsageAnalytics {
        var totals = UsageTotals.zero
        totals.inputTokens = tokens
        totals.estimatedCostUSD = Double(tokens)
        totals.costEstimateAvailable = priced
        return CodexUsageAnalytics(total: totals, today: totals, sevenDays: totals, thirtyDays: totals,
            daily: [DailyUsage(day: day, totals: totals)],
            models: [ModelUsage(model: "same-name", totals: totals, events: 1)],
            dailyModels: [DailyModelUsage(day: day, model: "same-name", totals: totals, events: 1)],
            eventCount: 1, fileCount: 1, source: "fixture")
    }

    func testFiltersAllDimensionsWithoutBorrowingAccountTotalsOrMergingModelIdentities() {
        let day = Calendar.current.startOfDay(for: Date())
        var snapshot = UsageAnalyticsSnapshot.empty
        snapshot.codex = usage(100, day: day)
        snapshot.codex.accountUsage = CodexAccountUsage(lifetimeTokens: 9_000_000_000, peakDailyTokens: nil,
            longestRunningTurnSeconds: nil, currentStreakDays: nil, longestStreakDays: nil, daily: [], fetchedAt: day)
        snapshot.claude = usage(60, day: day)
        let both = combinedLocalUsage(snapshot, providers: ["codex", "claude"])
        let selected = codexUsageSelection(from: both, start: nil, end: nil)
        XCTAssertEqual(selected.totalTokens, 160)
        XCTAssertFalse(selected.usesAccountUsage)
        XCTAssertEqual(selected.daily.map(\.tokens), [160])
        XCTAssertEqual(Set(selected.models.map(\.model)), ["Codex · same-name", "Claude · same-name"])
        XCTAssertEqual(selected.eventCount, 2)
        XCTAssertEqual(both.fileCount, 2)
        let one = combinedLocalUsage(snapshot, providers: ["claude"])
        XCTAssertEqual(one.total.totalTokens, 60)
        XCTAssertEqual(one.dailyModels.count, 1)
        XCTAssertEqual(one.fileCount, 1)
        XCTAssertEqual(combinedLocalUsage(snapshot, providers: []).total.totalTokens, 0)
        XCTAssertEqual(snapshot.codex.accountUsage?.lifetimeTokens, 9_000_000_000)
    }

    func testUnpricedUsageSuppressesCombinedEstimateButEmptyProvidersDoNot() {
        let day = Date()
        var snapshot = UsageAnalyticsSnapshot.empty
        snapshot.codex = usage(100, day: day)
        snapshot.kimiUsage = usage(50, day: day, priced: false)
        let combined = combinedLocalUsage(snapshot, providers: ["codex", "kimi"])
        XCTAssertFalse(combined.total.hasCostEstimate)
        XCTAssertFalse(combined.daily[0].totals.hasCostEstimate)
        XCTAssertTrue(combinedLocalUsage(snapshot, providers: ["codex", "qwen"]).total.hasCostEstimate)
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: day)!
        XCTAssertEqual(codexUsageSelection(from: combined, start: tomorrow, end: tomorrow).totalTokens, 0)
    }

    func testCompactAgentLocationsAndResetCountdownAndBillionsBoundary() {
        XCTAssertEqual(compactAgentLocation("/Users/test", home: "/Users/test"), "~")
        XCTAssertEqual(compactAgentLocation("/Users/test/demo", home: "/Users/test"), "~/demo")
        XCTAssertEqual(compactAgentLocation("/Users/test/work/corporate/Thira", home: "/Users/test"), "corporate/Thira")
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(ResetCountdownView.remaining(until: now.addingTimeInterval(90061), now: now), "1d 1h 1m 1s")
        XCTAssertEqual(ResetCountdownView.remaining(until: now.addingTimeInterval(3661), now: now), "1h 1m 1s")
        XCTAssertEqual(ResetCountdownView.remaining(until: now.addingTimeInterval(86400), now: now), "1d")
        XCTAssertEqual(ResetCountdownView.remaining(until: now.addingTimeInterval(3605), now: now), "1h 5s")
        XCTAssertEqual(ResetCountdownView.remaining(until: now.addingTimeInterval(60), now: now), "1m")
        XCTAssertEqual(ResetCountdownView.remaining(until: now.addingTimeInterval(1), now: now), "1s")
        XCTAssertEqual(ResetCountdownView.remaining(until: now.addingTimeInterval(-1), now: now), "Reset due")
        XCTAssertEqual(compactCount(999_999_999), "1.00B")
        XCTAssertEqual(millionsCount(1_448_290_000), "1.45B")
    }
}
