import CoreGraphics
import XCTest
@testable import AIFleet

final class QuotaHistoryTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private let hour = UsageHours.hour

    @MainActor
    func testKimiReportsItsOwnLimitsInTheSameChartWithoutInventingHistory() throws {
        let connection = ProviderConnection(id: "kimi-fixture", providerID: "kimi")
        let account = FleetAccount(id: "account", badgeIndex: 0, name: "Fixture", email: "fixture@example.test",
                                   connections: [connection])
        let session = ProviderLimitWindow(id: "rolling-0-5h", label: "5h", remainingPercent: 100,
                                          resetAt: base.addingTimeInterval(3 * hour))
        let month = ProviderLimitWindow(id: "monthly", label: "1m", remainingPercent: 26,
                                        resetAt: base.addingTimeInterval(10 * 24 * hour))
        let status = ProviderStatus(id: "kimi", name: "Kimi", state: .ok, detail: "Current", lastUpdated: base,
                                    remainingPercent: 26, limitWindows: [session, month])
        let row = MenuAccountConnection(account: account, connection: connection, status: status, isSelected: true)
        let target = try XCTUnwrap(QuotaHistoryTarget(row: row, codex: CodexMonitoringStore.shared))
        XCTAssertNil(target.report)
        XCTAssertEqual(target.quotaWindows, [session, month])
        XCTAssertEqual(target.primaryQuotaWindow, month)

        let data = target.quotaFigure(history: WeeklyQuotaHistory(), now: base)
        guard case .currentQuota(let reading) = data else { return XCTFail("Expected the observed monthly reading") }
        XCTAssertEqual(reading.usedPercent, 74)
        XCTAssertFalse(reading.isStale)
        let drawing = QuotaHistoryDrawing(data: data)
        XCTAssertTrue(drawing.accessibilityDetails(for: .overview, selectedTime: nil).contains("Monthly quota · 74.0% used"))
        XCTAssertTrue(drawing.accessibilityDetails(for: .hourly, selectedTime: nil).contains("Hourly history unavailable"))
        XCTAssertNil(drawing.hour(at: CGPoint(x: 200, y: 46), in: CGSize(width: 480, height: QuotaHistoryPanel.hourly.height)))
    }

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

    func testRetainsNinetyDaysOfObservationsAcrossWeeklyResets() throws {
        let day = 24 * hour
        let daysAgo = [91, 90, 30, 8, 0]
        let reports = daysAgo.map { days in
            let time = base.addingTimeInterval(-Double(days) * day)
            return report("a", at: time, reset: time.addingTimeInterval(2 * day), used: 20)
        }
        let expiredAccount = report("b", at: base.addingTimeInterval(-91 * day),
                                    reset: base.addingTimeInterval(-89 * day), used: 50)
        var history = WeeklyQuotaHistory()
        history.observe([expiredAccount], now: try XCTUnwrap(expiredAccount.fetchedAt))
        for sample in reports {
            history.observe([sample], now: try XCTUnwrap(sample.fetchedAt))
        }

        let latest = try XCTUnwrap(reports.last)
        let window = try XCTUnwrap(latest.weeklyWindows.first)
        let key = WeeklyQuotaHistoryKey(report: latest, window: window)
        let retainedTimes = daysAgo.dropFirst().map { base.addingTimeInterval(-Double($0) * day) }
        XCTAssertEqual(history.records[key]?.map(\.time), retainedTimes)
        XCTAssertEqual(history.records.count, 1)

        let chart = WeeklyQuotaChart(report: latest, window: window, history: history, now: base)
        XCTAssertEqual(chart.segments.flatMap { $0 }.map(\.time), [base])
        XCTAssertEqual(chart.hours.count, 72)
    }

    func testWindowAndDayForecastsAreDistinctAndNeedFreshHistory() throws {
        let reset = base.addingTimeInterval(76 * hour)
        let previous = base.addingTimeInterval(-24 * hour)
        let first = report("a", at: previous, reset: reset, used: 30)
        let current = report("a", at: base, reset: reset, used: 43)
        var history = WeeklyQuotaHistory()
        let initial = WeeklyQuotaChart(report: current, window: current.limits[0], history: history, now: base)
        XCTAssertEqual(initial.forecasts.map(\.period), [.window])
        XCTAssertEqual(try XCTUnwrap(initial.forecasts.first?.atReset), 43.0 * 168 / 92, accuracy: 1e-8)
        XCTAssertEqual(try XCTUnwrap(initial.pace.dailyBudgetPercent), 4.0 / 7 * 100, accuracy: 1e-8)
        let justReset = report("a", at: base, reset: base.addingTimeInterval(167.5 * hour), used: 1)
        XCTAssertTrue(WeeklyQuotaChart(report: justReset, window: justReset.limits[0], history: history, now: base).forecasts.isEmpty)
        history.observe([first], now: previous)
        history.observe([current], now: base)

        let chart = WeeklyQuotaChart(report: current, window: current.limits[0], history: history, now: base)
        XCTAssertEqual(chart.forecasts.map(\.period), [.window, .day])
        XCTAssertEqual(try XCTUnwrap(chart.forecasts.first?.atReset), 43.0 * 168 / 92, accuracy: 1e-8)
        XCTAssertEqual(try XCTUnwrap(chart.forecasts.last?.atReset), 43 + 13.0 / 24 * 76, accuracy: 1e-8)
        XCTAssertEqual(chart.forecasts.map { $0.plotEndpoint(reset: reset).time }, [reset, reset])
        XCTAssertEqual(try XCTUnwrap(chart.sustainablePerHour), 57.0 / 76, accuracy: 1e-8)
        let stale = WeeklyQuotaChart(report: current, window: current.limits[0], history: history, now: base.addingTimeInterval(hour))
        XCTAssertEqual(stale.pace.state, .stale)
        XCTAssertTrue(stale.forecasts.isEmpty)
        XCTAssertNil(stale.sustainablePerHour)

        let rising = report("a", at: base, reset: reset, used: 70)
        let high = WeeklyQuotaChart(report: rising, window: rising.limits[0], history: history, now: base)
        for forecast in high.forecasts {
            XCTAssertGreaterThan(forecast.atReset, 100)
            let crossing = try XCTUnwrap(forecast.exhaustion)
            XCTAssertLessThan(crossing, reset)
            XCTAssertEqual(forecast.plotEndpoint(reset: reset).time, crossing)
            XCTAssertEqual(forecast.plotEndpoint(reset: reset).used, 100)
        }
        let corrected = report("a", at: base, reset: reset, used: 28)
        XCTAssertTrue(WeeklyQuotaChart(report: corrected, window: corrected.limits[0], history: history, now: base).forecasts.isEmpty)
    }

    func testTheFirstPartialHourShowsOnlyItsObservedIncrease() throws {
        let reset = base.addingTimeInterval(76 * hour)
        let observations = [(10, 40), (20, 42), (30, 43)].map { minute, used in
            report("a", at: base.addingTimeInterval(Double(minute * 60)), reset: reset, used: used)
        }
        var history = WeeklyQuotaHistory()
        for item in observations {
            history.observe([item], now: try XCTUnwrap(item.fetchedAt))
        }
        let latest = try XCTUnwrap(observations.last)
        let chart = WeeklyQuotaChart(report: latest, window: latest.limits[0], history: history,
                                     now: try XCTUnwrap(latest.fetchedAt))
        XCTAssertNil(chart.hours.last?.percentagePoints)
        XCTAssertEqual(chart.hours.last?.partialPercentagePoints, 3)
        XCTAssertTrue(chart.hours.dropLast().allSatisfy { $0.partialPercentagePoints == nil })
    }

    func testCompactChartsKeepTheCapAndDrawTheMeasuredHour() throws {
        let reset = base.addingTimeInterval(123 * hour)
        var history = WeeklyQuotaHistory()
        for minutes in stride(from: -120, through: 0, by: 10) {
            let time = base.addingTimeInterval(Double(minutes * 60))
            history.observe([report("a", at: time, reset: reset, used: minutes < -100 ? 53 : 56)], now: time)
        }
        let latest = report("a", at: base, reset: reset, used: 56)
        let chart = WeeklyQuotaChart(report: latest, window: latest.limits[0], history: history, now: base)
        XCTAssertGreaterThan(try XCTUnwrap(chart.forecasts.first?.atReset), 200)
        let figure = QuotaHistoryDrawing(data: .quota(chart))

        let overview = CGSize(width: 480, height: QuotaHistoryPanel.overview.height)
        let hourly = CGSize(width: overview.width, height: QuotaHistoryPanel.hourly.height)
        let pixelWidth = Int(overview.width * 2)
        let pixelHeight = Int((overview.height + hourly.height) * 2)
        let bytesPerRow = pixelWidth * 4
        let context = try XCTUnwrap(CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
                                              bytesPerRow: bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: 2, y: -2)
        figure.draw(.overview, in: context, size: overview)
        context.translateBy(x: 0, y: overview.height)
        figure.draw(.hourly, in: context, size: hourly)
        let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        func color(_ x: Int, _ y: Int) -> [Int] {
            let offset = 2 * y * bytesPerRow + 2 * x * 4
            return [Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2])]
        }

        let rail = color(380, 24)
        XCTAssertGreaterThan(rail[0] - rail[1], 100)
        let hourlyTop = Int(overview.height)
        XCTAssertEqual(color(44, 62), color(44, hourlyTop + 60))
        XCTAssertEqual(color(460, 62), color(460, hourlyTop + 60))
        XCTAssertEqual(color(42, 146), color(42, 140))
        XCTAssertEqual(color(42, hourlyTop + 89), color(42, hourlyTop + 80))

        let bar = color(446, hourlyTop + 46)
        XCTAssertGreaterThan(bar[1] - bar[0], 90)
        XCTAssertLessThan(color(285, hourlyTop + 46)[1], 80)
        XCTAssertEqual(figure.hour(at: CGPoint(x: 446, y: 46), in: hourly),
                       base.addingTimeInterval(-2 * hour))
        XCTAssertNil(figure.hour(at: CGPoint(x: 428, y: 12), in: hourly))
        XCTAssertNil(figure.hour(at: CGPoint(x: 428, y: 108), in: hourly))
        let actualX = 44 + 416 * (1 - 123.0 / 168)
        let selected = try XCTUnwrap(figure.selection(at: CGPoint(x: actualX, y: 46), in: overview, panel: .overview))
        XCTAssertTrue(figure.accessibilityDetails(for: .overview, selectedTime: selected).contains("56.0% used"))
        XCTAssertNil(chart.measuredUse(at: base.addingTimeInterval(hour)))
        XCTAssertNotNil(chart.windowProjection(at: base.addingTimeInterval(hour)))

        func rows(_ range: Range<Int>) -> Data {
            Data(bytes: pixels.advanced(by: range.lowerBound * bytesPerRow), count: range.count * bytesPerRow)
        }
        let overviewRows = 48..<292
        let hourlyRows = (hourlyTop * 2)..<pixelHeight
        let overviewWithoutLegend = rows(overviewRows)
        let hourlyWithoutLegend = rows(hourlyRows)
        let overviewAxis = rows(292..<(hourlyTop * 2))
        context.translateBy(x: 0, y: -overview.height)
        figure.draw(.overview, in: context, size: overview, showsLegend: true)
        XCTAssertNotEqual(rows(overviewRows), overviewWithoutLegend)
        XCTAssertEqual(rows(hourlyRows), hourlyWithoutLegend)
        XCTAssertEqual(rows(292..<(hourlyTop * 2)), overviewAxis)
    }

    func testHourlyAxesEndAtTheirHighestLabeledValue() {
        let quota = HourlyChartScale(measuredMaximum: 1, minimum: 1)
        XCTAssertEqual(quota.maximum, 1)
        XCTAssertEqual(quota.levels.map { formattedNumber($0, fractionDigits: 1) }, ["0.0", "0.2", "0.4", "0.6", "0.8", "1.0"])
        let spike = HourlyChartScale(measuredMaximum: 1.1, minimum: 1)
        XCTAssertGreaterThanOrEqual(spike.maximum, 1.1)
        XCTAssertEqual(spike.levels.last, spike.maximum)

        let tokens = HourlyChartScale(measuredMaximum: 138_000_000, minimum: 10)
        XCTAssertEqual(tokens.maximum, 150_000_000)
        XCTAssertEqual(tokens.levels.last, tokens.maximum)
        XCTAssertGreaterThanOrEqual(tokens.levels.count, 5)
        let output = HourlyChartScale(measuredMaximum: 306_000, minimum: 10)
        XCTAssertEqual(compactCount(Int(output.maximum), trimsTrailingZeros: true), "320K")
    }

    func testClockGridUsesMidnightAndFixedLocalHoursAcrossDaylightSaving() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Warsaw"))
        for (month, day, midnightToFour) in [(3, 29, 3), (10, 25, 5)] {
            let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: month, day: day)))
            let tomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: start))
            let ticks = QuotaHourTick.inDomain(start...tomorrow, calendar: calendar)
            XCTAssertEqual(ticks.map(\.hour), [0, 4, 8, 12, 16, 20, 0])
            XCTAssertEqual(ticks.filter(\.isMajor).map(\.hour), [0, 12, 0])
            XCTAssertEqual(ticks[1].date.timeIntervalSince(start), Double(midnightToFour) * hour)
            XCTAssertTrue(ticks.allSatisfy {
                calendar.component(.hour, from: $0.date) == $0.hour &&
                    calendar.component(.minute, from: $0.date) == 0
            })
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

    func testChartTimestampUsesTheSameTimeZoneAsTheHourBins() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-26T00:45:00Z"))
        var calendar = Calendar(identifier: .gregorian)
        let locale = Locale(identifier: "en_GB")
        for (zone, time, expectedHour) in [("Europe/Warsaw", "01:45", 1), ("Asia/Kathmandu", "06:30", 6)] {
            calendar.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
            let label = chartTimestamp(date, calendar: calendar, locale: locale)
            XCTAssertTrue(label.contains(time), label)
            XCTAssertTrue(label.contains(zone), label)
            let bucket = UsageHours(now: date, calendar: calendar).last
            XCTAssertEqual(calendar.component(.hour, from: bucket), expectedHour)
            XCTAssertEqual(calendar.component(.minute, from: bucket), 0)
        }
    }

    func testTokenHoverSeparatesUncachedInputCacheAndOutput() {
        let calendar = Calendar.current
        let now = base.addingTimeInterval(600)
        let last = UsageHours(now: now, calendar: calendar).last
        var snapshot = UsageAnalyticsSnapshot.empty
        snapshot.statisticsRevision = UsageAnalyticsSnapshot.currentRevision
        snapshot.timeZoneIdentifier = calendar.timeZone.identifier
        snapshot.refreshedAt = now
        snapshot.codex.hourlyModels = [HourlyModelUsage(hour: last, model: "Fixture", tokens: UsageTotals(
            inputTokens: 1_200, cachedInputTokens: 700, cacheWriteInputTokens: 300, outputTokens: 13,
            reasoningOutputTokens: 0, estimatedCostUSD: 0))]
        let history = LocalTokenHistory(snapshot: snapshot, provider: .codex, now: now, calendar: calendar)
        let stack = QuotaHistoryDrawing(data: .tokens(history), calendar: calendar)
        let description = stack.accessibilityDetails(for: .hourly, selectedTime: last)
        XCTAssertTrue(description.contains("Uncached input · 200 tokens"))
        XCTAssertTrue(description.contains("Cache · 1 000 tokens"))
        XCTAssertTrue(description.contains("Output · 13 tokens"))

        let output = QuotaHistoryDrawing(data: .tokens(history, series: .output), calendar: calendar)
        let filtered = output.accessibilityDetails(for: .hourly, selectedTime: last)
        XCTAssertTrue(filtered.contains("Output · 13 tokens"))
        XCTAssertFalse(filtered.contains("Cache"))
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
