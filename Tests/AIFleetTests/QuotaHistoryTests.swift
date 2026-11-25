import XCTest
@testable import AIFleet

final class QuotaHistoryTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private let hour = UsageHours.hour

    func testScopeAndTimestampKeepAccountsAndModelCapsIndependent() throws {
        let first = report("a", at: base, reset: base.addingTimeInterval(48 * hour), used: 20, modelUsed: 11)
        let second = report("b", at: base, reset: base.addingTimeInterval(48 * hour), used: 67)
        var history = WeeklyQuotaHistory()
        history.observe([first, second, first], now: base)
        let account = WeeklyQuotaHistoryKey(report: first, window: first.weeklyWindows[0])
        let model = WeeklyQuotaHistoryKey(report: first, window: first.weeklyWindows[1])
        let other = WeeklyQuotaHistoryKey(report: second, window: second.weeklyWindows[0])
        XCTAssertEqual(history.records[account]?.map(\.used), [20])
        XCTAssertEqual(history.records[model]?.map(\.used), [11])
        XCTAssertEqual(history.records[other]?.map(\.used), [67])

        let following = base.addingTimeInterval(600)
        let stale = report("a", at: following, reset: first.limits[0].resetAt!, used: 77, state: .stale)
        let late = report("a", at: base.addingTimeInterval(-60), reset: first.limits[0].resetAt!, used: 19)
        let correction = report("a", at: base, reset: first.limits[0].resetAt!, used: 22)
        history.observe([stale, late, correction], now: following)
        XCTAssertEqual(history.records[account]?.map(\.used), [22])
        let encoded = try JSONEncoder().encode(history)
        XCTAssertEqual(try JSONDecoder().decode(WeeklyQuotaHistory.self, from: encoded), history)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains(first.identity.email))
    }

    func testWindowAndDayForecastsAreDistinctAndNeedFreshHistory() throws {
        let reset = base.addingTimeInterval(76 * hour)
        let previous = base.addingTimeInterval(-24 * hour)
        let first = report("a", at: previous, reset: reset, used: 30)
        let current = report("a", at: base, reset: reset, used: 43)
        var history = WeeklyQuotaHistory()
        let initial = WeeklyQuotaChart(report: current, window: current.limits[0], history: history, now: base)
        XCTAssertTrue(initial.forecasts.isEmpty)
        XCTAssertEqual(try XCTUnwrap(initial.pace.dailyBudgetPercent), 4.0 / 7 * 100, accuracy: 1e-8)
        history.observe([first], now: previous)
        history.observe([current], now: base)

        let chart = WeeklyQuotaChart(report: current, window: current.limits[0], history: history, now: base)
        XCTAssertEqual(chart.forecasts.map(\.period), [.window, .day])
        XCTAssertEqual(try XCTUnwrap(chart.forecasts.first?.atReset), 43.0 * 168 / 92, accuracy: 1e-8)
        XCTAssertEqual(try XCTUnwrap(chart.forecasts.last?.atReset), 43 + 13.0 / 24 * 76, accuracy: 1e-8)
        XCTAssertEqual(try XCTUnwrap(chart.sustainablePerHour), 57.0 / 76, accuracy: 1e-8)
        let stale = WeeklyQuotaChart(report: current, window: current.limits[0], history: history, now: base.addingTimeInterval(hour))
        XCTAssertEqual(stale.pace.state, .stale)
        XCTAssertTrue(stale.forecasts.isEmpty)
        XCTAssertNil(stale.sustainablePerHour)

        let rising = report("a", at: base, reset: reset, used: 70)
        let high = WeeklyQuotaChart(report: rising, window: rising.limits[0], history: history, now: base)
        for forecast in high.forecasts {
            XCTAssertGreaterThan(forecast.atReset, 100)
            XCTAssertLessThan(try XCTUnwrap(forecast.exhaustion), reset)
        }
    }

    func testHourlySpikeGapsCorrectionAndReset() {
        let oldReset = base.addingTimeInterval(3.5 * hour)
        let newReset = oldReset.addingTimeInterval(WeeklyQuotaPace.weekSeconds)
        var history = WeeklyQuotaHistory()
        func record(_ minute: Int, used: Int, reset: Date) {
            let time = base.addingTimeInterval(Double(minute * 60))
            history.observe([report("a", at: time, reset: reset, used: used)], now: time)
        }
        let firstHour = [20, 21, 21, 27, 27, 27, 27]
        for (index, used) in firstHour.enumerated() { record(index * 10, used: used, reset: oldReset) }
        record(120, used: 28, reset: oldReset)
        for minute in stride(from: 130, through: 200, by: 10) { record(minute, used: 22, reset: oldReset) }
        for minute in stride(from: 210, through: 300, by: 10) {
            record(minute, used: minute >= 260 ? 4 : 0, reset: newReset)
        }
        let now = base.addingTimeInterval(5 * hour)
        let current = report("a", at: now, reset: newReset, used: 4)
        let result = WeeklyQuotaChart(report: current, window: current.limits[0], history: history, now: now)
        let bins = Dictionary(uniqueKeysWithValues: result.hours.map { ($0.start, $0.percentagePoints) })
        XCTAssertEqual(result.hours.count, 72)
        XCTAssertEqual(bins[base] ?? nil, 7)
        for missing in 1...3 { XCTAssertNil(bins[base.addingTimeInterval(Double(missing) * hour)] ?? nil) }
        XCTAssertEqual(bins[base.addingTimeInterval(4 * hour)] ?? nil, 4)
        XCTAssertEqual(result.cycleStart, oldReset)
        XCTAssertTrue(result.segments.flatMap { $0 }.allSatisfy { $0.reset == newReset })
    }

    func testLocalModelsUseEventHoursIncludingRepeatedLocalHour() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Warsaw"))
        let formatter = ISO8601DateFormatter()
        let first = try XCTUnwrap(formatter.date(from: "2026-10-25T00:20:00Z"))
        let second = first.addingTimeInterval(hour)
        let now = second.addingTimeInterval(1800)
        func entry(_ time: Date, model: String, count: Int) -> CodexUsageLogEntry {
            CodexUsageLogEntry(timestamp: time, model: model, totals: UsageTotals(inputTokens: count,
                cachedInputTokens: count / 2, cacheWriteInputTokens: 0, outputTokens: 5,
                reasoningOutputTokens: 0, estimatedCostUSD: 0))
        }
        let rows = HourlyModelUsage.aggregate(entries: [
            entry(first, model: "Astra", count: 20), entry(second, model: "Astra", count: 40),
            entry(second, model: "Sol", count: 120), entry(now.addingTimeInterval(1), model: "Future", count: 900)
        ], now: now, calendar: calendar)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[1].hour.timeIntervalSince(rows[0].hour), hour)
        XCTAssertEqual(calendar.component(.hour, from: rows[0].hour), calendar.component(.hour, from: rows[1].hour))
        var snapshot = UsageAnalyticsSnapshot.empty
        snapshot.statisticsRevision = UsageAnalyticsSnapshot.currentRevision
        snapshot.timeZoneIdentifier = calendar.timeZone.identifier
        snapshot.refreshedAt = now
        snapshot.codex.hourlyModels = rows
        snapshot.claude = .empty
        let codex = LocalTokenHistory(snapshot: snapshot, provider: .codex, model: "Astra", now: now, calendar: calendar)
        XCTAssertEqual(codex.models, ["Astra", "Sol"])
        XCTAssertEqual(codex.hours.suffix(2).map { $0.tokens?.totalTokens }, [25, 45])
        let claude = LocalTokenHistory(snapshot: snapshot, provider: .claude, now: now, calendar: calendar)
        XCTAssertTrue(claude.hours.allSatisfy { $0.tokens == nil })
    }

    private func report(_ id: String, at date: Date, reset: Date, used: Int, modelUsed: Int? = nil,
                        state: ProviderStatus.QuotaState = .available) -> StatisticsProviderReport {
        var windows = [ProviderLimitWindow(id: "weekly", label: "7d", remainingPercent: 100 - used, resetAt: reset)]
        if let modelUsed {
            windows.append(ProviderLimitWindow(id: "fable", label: "7d (Fable)", remainingPercent: 100 - modelUsed,
                                               resetAt: reset, weeklyModel: "Fable"))
        }
        return StatisticsProviderReport(provider: "claude", accountID: id,
            identity: ConnectionIdentity(email: "\(id)@example.test", organizationID: "org"),
            fetchedAt: date, accountUsage: nil, limits: windows, quotaAuthentication: .signedIn, quotaState: state)
    }
}
