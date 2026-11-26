import AppKit
import CoreGraphics
import SwiftUI
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
        XCTAssertEqual(drawing.accessibilityDetails(for: .overview, selectedTime: nil), "Monthly quota")
        XCTAssertTrue(drawing.accessibilityDetails(for: .overview, selectedTime: base).hasSuffix(". 74.0% used"))
        XCTAssertTrue(drawing.accessibilityDetails(for: .hourly, selectedTime: nil).contains("Hourly history unavailable"))
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

    @MainActor
    func testReturningToThePreviousEmailRestoresItsSavedQuotaCycles() throws {
        let oldTime = base.addingTimeInterval(-48 * hour)
        let oldReset = base.addingTimeInterval(-24 * hour)
        let currentReset = base.addingTimeInterval(72 * hour)
        func weekly(_ remaining: Int, reset: Date) -> [ProviderLimitWindow] {
            [ProviderLimitWindow(id: "weekly", label: "7d", remainingPercent: remaining, resetAt: reset)]
        }
        let previous = try target(.codex, id: "a", windows: weekly(19, reset: oldReset), now: oldTime,
                                  email: "a@example.test")
        let a = try target(.codex, id: "a", windows: weekly(69, reset: currentReset), now: base, email: "a@example.test")
        let b = try target(.codex, id: "b", windows: weekly(34, reset: currentReset), now: base, email: "b@example.test")
        var saved = WeeklyQuotaHistory()
        saved.observe([try XCTUnwrap(previous.report)], now: oldTime)
        saved.observe([try XCTUnwrap(a.report), try XCTUnwrap(b.report)], now: base)
        let restored = try JSONDecoder().decode(WeeklyQuotaHistory.self, from: JSONEncoder().encode(saved))
        func chart(for target: QuotaHistoryTarget, reset: Date? = nil) throws -> WeeklyQuotaChart {
            guard case .quota(let chart) = target.quotaFigure(history: restored, now: base, displayedReset: reset) else {
                throw CocoaError(.coderInvalidValue)
            }
            return chart
        }

        XCTAssertEqual(try chart(for: a).latest?.used, 31)
        XCTAssertEqual(try chart(for: b).latest?.used, 66)
        XCTAssertEqual(try chart(for: b).cycleResets, [currentReset])
        XCTAssertEqual(try chart(for: a).cycleResets, [currentReset, oldReset])
        XCTAssertEqual(try chart(for: a, reset: oldReset).latest?.used, 81)
    }

    func testRetainsObservationsAcrossWeeklyResetsWithoutAnAgeLimit() throws {
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
        let retainedTimes = daysAgo.map { base.addingTimeInterval(-Double($0) * day) }
        XCTAssertEqual(history.records[key]?.map(\.time), retainedTimes)
        XCTAssertEqual(history.records.count, 2)

        let chart = WeeklyQuotaChart(report: latest, window: window, history: history, now: base)
        XCTAssertEqual(chart.segments.flatMap { $0 }.map(\.time), [base])
        XCTAssertEqual(chart.hours.count, 72)
    }

    @MainActor
    func testFiveHourMeterFollowsItsOwnResetAndStaysOffArchivedCycles() throws {
        let week = WeeklyQuotaPace.weekSeconds
        let oldTime = base.addingTimeInterval(-week)
        let oldReset = base.addingTimeInterval(-hour)
        let newReset = oldReset.addingTimeInterval(week)
        let shortReset = base.addingTimeInterval(60)
        let weekly = ProviderLimitWindow(id: "seven_day", label: "7d", remainingPercent: 18, resetAt: newReset)
        let short = ProviderLimitWindow(id: "five_hour", label: "5h", remainingPercent: 95, resetAt: shortReset)
        let previous = try target(.claude, id: "claude", windows: [
            ProviderLimitWindow(id: weekly.id, label: weekly.label, remainingPercent: 13, resetAt: oldReset)
        ], now: oldTime)
        let current = try target(.claude, id: "claude", windows: [weekly, short], now: base)
        var history = WeeklyQuotaHistory()
        history.observe([try XCTUnwrap(previous.report)], now: oldTime)
        func drawing(at time: Date, displayedReset: Date? = nil) -> QuotaHistoryDrawing {
            let data = current.quotaFigure(history: history, now: time, displayedReset: displayedReset)
            return QuotaHistoryDrawing(data: data, otherLimits: [short])
        }
        let active = try XCTUnwrap(drawing(at: base).fiveHourMeter)
        XCTAssertEqual(active.used, 5)
        XCTAssertFalse(active.isStale)
        XCTAssertEqual(active.reset, "Reset \(chartTimestamp(shortReset, calendar: .current))")
        XCTAssertTrue(try XCTUnwrap(drawing(at: shortReset).fiveHourMeter).isStale)
        XCTAssertNil(drawing(at: base, displayedReset: oldReset).fiveHourMeter)
    }

    func testWeeklyResetShowsTheNewCycleAndKeepsThePreviousMeasurements() throws {
        let oldReset = base.addingTimeInterval(48 * hour)
        let currentReset = base.addingTimeInterval(WeeklyQuotaPace.weekSeconds)
        let oldTime = base.addingTimeInterval(-hour)
        let previous = report("a", at: oldTime, reset: oldReset, used: 89)
        let current = report("a", at: base, reset: currentReset, used: 2)
        var history = WeeklyQuotaHistory()
        history.observe([previous], now: oldTime)
        history.observe([current], now: base)
        let live = WeeklyQuotaChart(report: current, window: current.limits[0], history: history,
                                    now: base, range: .sevenDays)
        XCTAssertEqual(live.latest?.used, 2)
        XCTAssertNil(live.earlyResetAt)
        XCTAssertNil(live.measuredUse(at: oldTime))
        XCTAssertEqual(live.hours.count, 168)
        let liveHeading = QuotaHistoryDrawing(data: .quota(live)).accessibilityDetails(for: .overview, selectedTime: nil)
        XCTAssertEqual(liveHeading, "Weekly quota")
        XCTAssertEqual(live.cycleReset(offset: 1), oldReset)
        XCTAssertTrue(try XCTUnwrap(live.cycleLabel(calendar: .current)).contains(":"))
        let prior = WeeklyQuotaChart(report: current, window: current.limits[0], history: history,
                                     now: base, range: .sevenDays, displayedReset: oldReset)
        XCTAssertEqual(prior.latest?.used, 89)
        XCTAssertEqual(prior.earlyResetAt, base)
        XCTAssertEqual(prior.cycleReset(offset: -1), currentReset)
        XCTAssertTrue(prior.isHistorical)
        XCTAssertTrue(prior.forecasts.isEmpty)
        XCTAssertTrue(try XCTUnwrap(prior.cycleLabel(calendar: .current)).contains(":"))
        XCTAssertEqual(prior.hours.map(\.percentagePoints), live.hours.map(\.percentagePoints))
        XCTAssertEqual(prior.sustainablePerHour, live.sustainablePerHour)
        let drawing = QuotaHistoryDrawing(data: .quota(prior))
        XCTAssertEqual(drawing.accessibilityDetails(for: .overview, selectedTime: nil), "Weekly quota")
        XCTAssertTrue(drawing.accessibilityDetails(for: .overview, selectedTime: oldTime).contains(". 89.0% used."))
        let resetDetails = drawing.accessibilityDetails(for: .overview, selectedTime: base)
        XCTAssertTrue(resetDetails.contains("Early reset"))
        XCTAssertTrue(resetDetails.contains("Scheduled reset"))
        let saved = try JSONDecoder().decode(WeeklyQuotaHistory.self, from: JSONEncoder().encode(history))
        let key = WeeklyQuotaHistoryKey(report: current, window: current.limits[0])
        XCTAssertEqual(saved.records[key]?.map(\.reset), [oldReset, currentReset])
        XCTAssertEqual(saved.records[key]?.map(\.used), [89, 2])
    }

    func testAChangedResetTimeAloneDoesNotMarkAnEarlyReset() {
        let previousTime = base.addingTimeInterval(-60)
        let oldReset = base.addingTimeInterval(48 * hour)
        var history = WeeklyQuotaHistory()
        history.observe([report("a", at: previousTime, reset: oldReset, used: 30)], now: previousTime)
        let report = report("a", at: base, reset: base.addingTimeInterval(WeeklyQuotaPace.weekSeconds), used: 30)
        let prior = WeeklyQuotaChart(report: report, window: report.limits[0], history: history, now: base,
                                     displayedReset: oldReset)
        XCTAssertTrue(prior.isHistorical)
        XCTAssertNil(prior.earlyResetAt)
    }

    func testPlanIsVisibleOnTheFirstAndSeventhDays() throws {
        let reset = base.addingTimeInterval(WeeklyQuotaPace.weekSeconds)
        let now = base.addingTimeInterval(18 * 60)
        var history = WeeklyQuotaHistory()
        history.observe([report("a", at: base, reset: reset, used: 0)], now: base)
        let second = base.addingTimeInterval(9 * 60)
        history.observe([report("a", at: second, reset: reset, used: 1)], now: second)
        let report = report("a", at: now, reset: reset, used: 2)
        let chart = WeeklyQuotaChart(report: report, window: report.limits[0], history: history, now: now)
        XCTAssertTrue(chart.forecasts.isEmpty)
        let size = CGSize(width: 480, height: QuotaHistoryPanel.overview.height)
        let width = Int(size.width * 2)
        let height = Int(size.height * 2)
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 2, y: -2)
        QuotaHistoryDrawing(data: .quota(chart)).draw(.overview, in: context, size: size)
        let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        // The first and seventh plateaus both have visible plan strokes.
        let panel = QuotaHistoryPanel.overview
        let firstY = Int((panel.headerHeight + panel.plotHeight * 6 / 7) * 2)
        let lastY = Int((panel.headerHeight + 1.7) * 2)
        XCTAssertGreaterThan(Int(pixels[(firstY * width + 150) * 4]), 100)
        XCTAssertGreaterThan(Int(pixels[(lastY * width + 860) * 4]), 100)
        let offset = ((Int((panel.headerHeight + panel.plotHeight) * 2) - 5) * width + 93) * 4
        XCTAssertLessThan(Int(pixels[offset + 2]) - Int(pixels[offset]), 75)
    }

    func testSevenDayTokensPreserveMissingCoverageFromAnOlderSnapshot() {
        let calendar = Calendar(identifier: .gregorian)
        let hours = UsageHours(now: base, calendar: calendar, range: .sevenDays)
        var snapshot = UsageAnalyticsSnapshot.empty
        snapshot.statisticsRevision = UsageAnalyticsSnapshot.currentRevision
        snapshot.timeZoneIdentifier = calendar.timeZone.identifier
        snapshot.refreshedAt = base
        let tokens = UsageTotals(inputTokens: 240, cachedInputTokens: 120, cacheWriteInputTokens: 0,
                                 outputTokens: 30, reasoningOutputTokens: 0, estimatedCostUSD: 0)
        snapshot.codex.hourlyModels = [HourlyModelUsage(hour: hours.last, model: "Fixture", tokens: tokens)]
        let legacy = LocalTokenHistory(snapshot: snapshot, provider: .codex, now: base, calendar: calendar, range: .sevenDays)
        XCTAssertNil(legacy.hours.first?.tokens)
        XCTAssertNotNil(legacy.hours.last?.tokens)
        snapshot.hourlyHistoryDays = 7
        snapshot.codex.hourlyModels.insert(HourlyModelUsage(hour: hours.start, model: "Fixture", tokens: tokens), at: 0)
        let refreshed = LocalTokenHistory(snapshot: snapshot, provider: .codex, now: base, calendar: calendar, range: .sevenDays)
        XCTAssertEqual(refreshed.hours.first?.tokens?.totalTokens, 270)
        XCTAssertEqual(refreshed.hours.count, 168)
        let fiveDays = LocalTokenHistory(snapshot: snapshot, provider: .codex, now: base, calendar: calendar, range: .fiveDays)
        XCTAssertEqual(fiveDays.hours.count, 120)
        XCTAssertEqual(fiveDays.hours.first?.tokens?.totalTokens, 0)
    }

    func testSevenDayPlotsRenderOnTheSameSizeCanvasInBothThemes() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = base.addingTimeInterval(20 * 60)
        let window = UsageHours(now: now, calendar: calendar, range: .sevenDays)
        let reset = window.last.addingTimeInterval(hour)
        var history = WeeklyQuotaHistory()
        var used = 0
        for minute in stride(from: 0, through: Int(now.timeIntervalSince(window.start) / 60), by: 10) {
            let time = window.start.addingTimeInterval(Double(minute) * 60)
            if minute % 60 == 20 && (minute / 60) % 17 < 6 { used += 1 + (minute / 60) % 3 }
            history.observe([report("preview", at: time, reset: reset, used: min(used, 96))], now: time)
        }
        let current = report("preview", at: now, reset: reset, used: min(used, 96))
        let quota = WeeklyQuotaChart(report: current, window: current.limits[0], history: history, now: now,
                                     calendar: calendar, range: .sevenDays)
        XCTAssertTrue(quota.hours.prefix(24).contains { ($0.percentagePoints ?? 0) > 0 })
        var snapshot = UsageAnalyticsSnapshot.empty
        snapshot.statisticsRevision = UsageAnalyticsSnapshot.currentRevision
        snapshot.timeZoneIdentifier = calendar.timeZone.identifier
        snapshot.refreshedAt = now
        snapshot.hourlyHistoryDays = 7
        snapshot.codex.hourlyModels = window.starts.enumerated().compactMap { index, start in
            let activity = index % 23
            guard (3...15).contains(activity) else { return nil }
            let total = (1 + index % 11) * 540_000
            let tokens = UsageTotals(inputTokens: total, cachedInputTokens: total * 3 / 4,
                                     cacheWriteInputTokens: 0, outputTokens: total / 8,
                                     reasoningOutputTokens: 0, estimatedCostUSD: 0)
            return HourlyModelUsage(hour: start, model: "Preview", tokens: tokens)
        }
        let tokens = LocalTokenHistory(snapshot: snapshot, provider: .codex, now: now, calendar: calendar, range: .sevenDays)
        let size = CGSize(width: 740, height: QuotaHistoryPanel.hourly.height)
        let width = Int(size.width * 2)
        let height = Int(size.height * 4)
        for theme in [ColorScheme.light, .dark] {
            let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                                  bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 2, y: -2)
            QuotaHistoryDrawing(data: .quota(quota), calendar: calendar).draw(.hourly, in: context,
                                                                              size: size, colorScheme: theme)
            context.translateBy(x: 0, y: size.height)
            QuotaHistoryDrawing(data: .tokens(tokens), calendar: calendar).draw(.hourly, in: context,
                                                                                size: size, colorScheme: theme)
            let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
            if theme == .light {
                XCTAssertGreaterThan(pixels[0], 230)
            } else {
                XCTAssertLessThan(pixels[0], 35)
            }
            if let directory = ProcessInfo.processInfo.environment["FLEET_UI_CAPTURE_DIR"],
               let image = context.makeImage() {
                let name = theme == .light ? "quota-seven-days-light.png" : "quota-seven-days-dark.png"
                try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to:
                    URL(fileURLWithPath: directory).appendingPathComponent(name))
            }
        }
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
        XCTAssertEqual(try XCTUnwrap(initial.pace.dailyBudgetPercent), 400.0 / 7, accuracy: 1e-8)
        let justReset = report("a", at: base, reset: base.addingTimeInterval(167.5 * hour), used: 1)
        XCTAssertTrue(WeeklyQuotaChart(report: justReset, window: justReset.limits[0], history: history, now: base).forecasts.isEmpty)
        history.observe([first], now: previous)
        history.observe([current], now: base)

        let chart = WeeklyQuotaChart(report: current, window: current.limits[0], history: history, now: base)
        XCTAssertEqual(chart.forecasts.map(\.period), [.window, .day])
        XCTAssertEqual(try XCTUnwrap(chart.forecasts.first?.atReset), 43.0 * 168 / 92, accuracy: 1e-8)
        XCTAssertEqual(try XCTUnwrap(chart.forecasts.last?.atReset), 43 + 13.0 / 24 * 76, accuracy: 1e-8)
        XCTAssertEqual(chart.forecasts.map { $0.plotEndpoint(reset: reset).time }, [reset, reset])
        let atReset = chart.projections(at: reset)
        XCTAssertEqual(atReset.map { $0.period }, [.window, .day])
        XCTAssertEqual(atReset.map { $0.used }, chart.forecasts.map(\.atReset))
        let drawing = QuotaHistoryDrawing(data: .quota(chart))
        let readout = drawing.accessibilityDetails(for: .overview, selectedTime: base.addingTimeInterval(20 * hour))
        XCTAssertTrue(readout.contains("Window average · 52.3% projected"))
        XCTAssertTrue(readout.contains("Trailing 24h · 53.8% projected"))
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

    func testCoincidentForecastsDrawBothColors() throws {
        let reset = base.addingTimeInterval(72 * hour)
        let previous = base.addingTimeInterval(-24 * hour)
        let current = report("a", at: base, reset: reset, used: 60)
        var history = WeeklyQuotaHistory()
        history.observe([report("a", at: previous, reset: reset, used: 45)], now: previous)
        let chart = WeeklyQuotaChart(report: current, window: current.limits[0], history: history, now: base)
        XCTAssertEqual(chart.forecasts.map(\.atReset), [105, 105])

        let size = CGSize(width: 480, height: QuotaHistoryPanel.overview.height)
        let width = Int(size.width * 2)
        let height = Int(size.height * 2)
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 2, y: -2)
        QuotaHistoryDrawing(data: .quota(chart)).draw(.overview, in: context, size: size)
        let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        var gold = 0
        var coral = 0
        // Sample the projected path beyond the last reading, below the limit rail.
        let shift = Int((QuotaHistoryPanel.overview.headerHeight - 24) * 2)
        for y in (54 + shift)..<(152 + shift) {
            for x in 600..<830 {
                let offset = (y * width + x) * 4
                let red = Int(pixels[offset])
                let green = Int(pixels[offset + 1])
                let blue = Int(pixels[offset + 2])
                if red > 210 && green - blue > 70 { gold += 1 }
                if red > 210 && (105...135).contains(green) && (65...85).contains(blue) { coral += 1 }
            }
        }
        XCTAssertGreaterThan(gold, 20)
        XCTAssertGreaterThan(coral, 20)
        if let directory = ProcessInfo.processInfo.environment["FLEET_UI_CAPTURE_DIR"],
           let image = context.makeImage() {
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to:
                URL(fileURLWithPath: directory).appendingPathComponent("quota-coincident-forecasts.png"))
        }
    }

    @MainActor
    func testStatisticsQuotaStackKeepsItsHeightWhenTheSelectedAccountChanges() async throws {
        let now = Date()
        let weekly = ProviderLimitWindow(id: "weekly", label: "7d", remainingPercent: 57,
                                         resetAt: now.addingTimeInterval(76 * hour))
        let short = ProviderLimitWindow(id: "primary", label: "5h", remainingPercent: 20,
                                       resetAt: now.addingTimeInterval(2 * hour))
        let monthly = ProviderLimitWindow(id: "monthly", label: "1m", remainingPercent: 74,
                                         resetAt: now.addingTimeInterval(8 * 24 * hour))
        let connected = try target(.codex, id: "codex-connected", windows: [weekly], now: now)
        let disconnected = try target(.codex, id: "codex-disconnected", windows: [], now: now)
        let kimi = try target(.kimi, id: "kimi", windows: [short, monthly], now: now)
        let qwen = try target(.qwen, id: "qwen", windows: [], now: now)
        let targets = [connected, disconnected, kimi, qwen]
        XCTAssertEqual(Set(targets.map(\.id)).count, targets.count)
        let fixture = QuotaHistorySelectionFixture()
        let view = QuotaHistoryLayoutFixture(targets: targets, fixture: fixture)
        let host = NSHostingController(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 450),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = host
        defer { window.contentViewController = nil }
        host.view.layoutSubtreeIfNeeded()
        let originalHeight = host.view.fittingSize.height
        XCTAssertGreaterThan(originalHeight, 412)

        for target in [disconnected, kimi, qwen, connected] {
            fixture.request = QuotaHistoryRequest(targetID: target.id, provider: target.provider)
            for _ in 0..<5 {
                try await Task.sleep(nanoseconds: 10_000_000)
                host.view.layoutSubtreeIfNeeded()
            }
            let size = host.view.fittingSize
            XCTAssertEqual(size.height, originalHeight, accuracy: 1, target.id)
            if let directory = ProcessInfo.processInfo.environment["FLEET_UI_CAPTURE_DIR"] {
                window.setContentSize(size)
                host.view.layoutSubtreeIfNeeded()
                if let bitmap = host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds) {
                    host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
                    let name = target.id.replacingOccurrences(of: ":", with: "-")
                    try bitmap.representation(using: .png, properties: [:])?.write(to:
                        URL(fileURLWithPath: directory).appendingPathComponent("quota-\(name).png"))
                }
            }
        }
    }

    @MainActor
    func testMenuQuotaPopoverWaitsForLayoutAndReusesThePanelAcrossProviderClicks() async throws {
        let app = NSApplication.shared
        let visible = try XCTUnwrap(NSScreen.main?.visibleFrame)
        let frame = CGRect(x: visible.maxX - 374, y: visible.maxY - 580, width: 354, height: 570)
        let owner = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        let firstAnchor = NSView(frame: CGRect(x: 325, y: 463, width: 23, height: 20))
        let secondAnchor = NSView(frame: CGRect(x: 325, y: 375, width: 23, height: 20))
        let thirdAnchor = NSView(frame: CGRect(x: 325, y: 295, width: 23, height: 20))
        let now = Date()
        let weekly = ProviderLimitWindow(id: "weekly", label: "7d", remainingPercent: 57, resetAt: now.addingTimeInterval(76 * hour))
        let monthly = ProviderLimitWindow(id: "monthly", label: "1m", remainingPercent: 71, resetAt: now.addingTimeInterval(48 * hour))
        let short = ProviderLimitWindow(id: "five_hour", label: "5h", remainingPercent: 95, resetAt: now.addingTimeInterval(3 * hour))
        let fable = ProviderLimitWindow(id: "seven_day_fable", label: "7d (Fable)", remainingPercent: 0,
                                        resetAt: weekly.resetAt, weeklyModel: "Fable")
        let first = try target(.claude, id: "popover-claude", windows: [weekly, short, fable], now: now)
        let second = try target(.codex, id: "popover-codex", windows: [weekly], now: now)
        let third = try target(.kimi, id: "popover-kimi", windows: [monthly], now: now)
        let presentation = MenuQuotaHistory()
        for anchor in [firstAnchor, secondAnchor, thirdAnchor] {
            owner.contentView?.addSubview(anchor)
            presentation.register(anchor)
        }
        owner.alphaValue = 0
        owner.orderFrontRegardless()
        defer { presentation.dismiss(); owner.orderOut(nil) }

        presentation.toggle(first, anchoredTo: firstAnchor, openStatistics: {})
        let panel = try XCTUnwrap(owner.childWindows?.first)
        XCTAssertEqual(panel.alphaValue, 0)
        for _ in 0..<50 where panel.alphaValue == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(panel.alphaValue, 1)
        let measured = panel.frame
        XCTAssertTrue(visible.contains(measured))
        let view = try XCTUnwrap(panel.contentView)
        let hosted = try XCTUnwrap(view.subviews.first)
        let fullContent = NSHostingView(rootView: QuotaHistoryView(
            targets: [first], selection: .constant(nil), openInStatistics: { _ in })
            .padding(10).frame(width: hosted.bounds.width))
        let fullHeight = ceil(fullContent.fittingSize.height)
        if visible.height >= fullHeight + 16 {
            XCTAssertGreaterThanOrEqual(hosted.bounds.height, fullHeight)
        }
        if let directory = ProcessInfo.processInfo.environment["FLEET_UI_CAPTURE_DIR"],
           let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to:
                URL(fileURLWithPath: directory).appendingPathComponent("quota-compact-popover.png"))
        }
        for (target, anchor) in [(second, secondAnchor), (third, thirdAnchor), (first, firstAnchor)] {
            let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown,
                location: anchor.convert(CGPoint(x: 11, y: 10), to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: owner.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            app.sendEvent(down)
            XCTAssertTrue(owner.childWindows?.first === panel)
            presentation.toggle(target, anchoredTo: anchor, openStatistics: {})
            try await Task.sleep(nanoseconds: 30_000_000)
            XCTAssertTrue(owner.childWindows?.first === panel)
            XCTAssertEqual(presentation.presented, target.id)
            XCTAssertEqual(panel.alphaValue, 1)
            XCTAssertEqual(panel.frame, measured)
        }
        presentation.toggle(first, anchoredTo: firstAnchor, openStatistics: {})
        XCTAssertNil(presentation.presented)
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

    func testHourlyQuotaStatisticsUseCompleteHoursIncludingZero() {
        let now = base.addingTimeInterval(250 * 60)
        let reset = base.addingTimeInterval(48 * hour)
        var history = WeeklyQuotaHistory()
        for minute in stride(from: 30, through: 250, by: 10) {
            let time = base.addingTimeInterval(Double(minute * 60))
            let used = switch minute {
            case 30: 0
            case 40..<130: 15
            case 130..<190: 18
            case 190..<250: 27
            default: 41
            }
            history.observe([report("a", at: time, reset: reset, used: used)], now: time)
        }
        let current = report("a", at: now, reset: reset, used: 41)
        let chart = WeeklyQuotaChart(report: current, window: current.limits[0], history: history, now: now)
        XCTAssertEqual(chart.hours.compactMap(\.partialPercentagePoints), [15, 14])
        XCTAssertEqual(chart.hours.suffix(4).map(\.percentagePoints), [0, 3, 9, nil])
        let drawing = QuotaHistoryDrawing(data: .quota(chart))
        let cursor = base.addingTimeInterval(175 * 60)
        let readout = drawing.accessibilityDetails(for: .hourly, selectedTime: cursor)
        XCTAssertTrue(readout.hasSuffix(". 3.0% of weekly quota"))
        XCTAssertTrue(drawing.headerMetrics(for: .hourly).map(\.label).starts(with: ["Average 4.0%", "Median 3.0%"]))
        let partial = drawing.accessibilityDetails(for: .hourly, selectedTime: now)
        XCTAssertTrue(partial.contains("14.0% of weekly quota · partial hour"))
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

        let weeklyHeader = Int(QuotaHistoryPanel.overview.headerHeight)
        let weeklyShift = weeklyHeader - 24
        let rail = color(380, weeklyHeader)
        XCTAssertGreaterThan(rail[0] - rail[1], 100)
        let hourlyTop = Int(overview.height)
        let headerOffset = Int(QuotaHistoryPanel.hourly.headerHeight - 24)
        for y in [62 + weeklyShift, hourlyTop + 60 + headerOffset] {
            XCTAssertGreaterThan(color(44, y)[0], color(42, y)[0] + 12)
            XCTAssertGreaterThan(color(460, y)[0], color(462, y)[0] + 12)
        }
        XCTAssertEqual(color(42, 146 + weeklyShift), color(42, 140 + weeklyShift))
        XCTAssertEqual(color(42, hourlyTop + 89 + headerOffset), color(42, hourlyTop + 80 + headerOffset))

        let bar = color(446, hourlyTop + 46 + headerOffset)
        XCTAssertGreaterThan(bar[1] - bar[0], 45)
        XCTAssertLessThan(color(285, hourlyTop + 46 + headerOffset)[1], 80)
        let sharedTime = try XCTUnwrap(figure.selection(at: CGPoint(x: 446, y: 46 + headerOffset), in: hourly, panel: .hourly))
        XCTAssertEqual(sharedTime, base.addingTimeInterval(-2 * hour))
        let timestamp = chartHour(sharedTime, calendar: .current)
        XCTAssertTrue(figure.accessibilityDetails(for: .hourly, selectedTime: sharedTime)
            .hasPrefix(timestamp + ". 3.0% of weekly quota"))
        let bucket = try XCTUnwrap(Calendar.current.dateInterval(of: .hour, for: sharedTime)?.start)
        var snapshot = UsageAnalyticsSnapshot.empty
        snapshot.statisticsRevision = UsageAnalyticsSnapshot.currentRevision
        snapshot.timeZoneIdentifier = Calendar.current.timeZone.identifier
        snapshot.refreshedAt = base
        snapshot.claude = .empty
        snapshot.claude?.hourlyModels = [HourlyModelUsage(hour: bucket, model: "Fixture", tokens: UsageTotals(
            inputTokens: 120, cachedInputTokens: 10, cacheWriteInputTokens: 0, outputTokens: 8,
            reasoningOutputTokens: 0, estimatedCostUSD: 0))]
        let tokens = QuotaHistoryDrawing(data: .tokens(LocalTokenHistory(snapshot: snapshot, provider: .claude, now: base)))
        XCTAssertTrue(tokens.accessibilityDetails(for: .hourly, selectedTime: sharedTime)
            .hasPrefix(timestamp + ". Total · 128 tokens"))
        XCTAssertNil(figure.selection(at: CGPoint(x: 428, y: 12), in: hourly, panel: .hourly))
        XCTAssertNil(figure.selection(at: CGPoint(x: 428, y: 108 + headerOffset), in: hourly, panel: .hourly))
        let actualX = 44 + 416 * (1 - 123.0 / 168)
        let selected = try XCTUnwrap(figure.selection(at: CGPoint(x: actualX, y: CGFloat(46 + weeklyShift)),
                                                       in: overview, panel: .overview))
        XCTAssertTrue(figure.accessibilityDetails(for: .overview, selectedTime: selected).contains("56.0% used"))
        XCTAssertNil(chart.measuredUse(at: base.addingTimeInterval(hour)))
        XCTAssertEqual(chart.projections(at: base.addingTimeInterval(hour)).map { $0.period }, [.window])

        func rows(_ range: Range<Int>) -> Data {
            Data(bytes: pixels.advanced(by: range.lowerBound * bytesPerRow), count: range.count * bytesPerRow)
        }
        let overviewAxisTop = Int((overview.height - QuotaHistoryPanel.overview.axisHeight) * 2)
        let overviewRows = (weeklyHeader * 2)..<overviewAxisTop
        let hourlyRows = (hourlyTop * 2)..<pixelHeight
        let hourlyAxisRows = ((hourlyTop + Int(hourly.height - QuotaHistoryPanel.hourly.axisHeight) + 1) * 2)..<pixelHeight
        let overviewWithoutLegend = rows(overviewRows)
        let hourlyWithoutLegend = rows(hourlyRows)
        let hourlyAxis = rows(hourlyAxisRows)
        let overviewAxis = rows(overviewAxisTop..<(hourlyTop * 2))
        let tooltipY = hourlyTop + Int(QuotaHistoryPanel.hourly.headerHeight) + 13
        let beforeTooltip = color(420, tooltipY)
        let outsideTooltip = color(180, tooltipY)
        context.translateBy(x: 0, y: -overview.height)
        figure.draw(.overview, in: context, size: overview, showsLegend: true)
        XCTAssertNotEqual(rows(overviewRows), overviewWithoutLegend)
        XCTAssertEqual(rows(hourlyRows), hourlyWithoutLegend)
        XCTAssertEqual(rows(overviewAxisTop..<(hourlyTop * 2)), overviewAxis)
        context.translateBy(x: 0, y: overview.height)
        figure.draw(.hourly, in: context, size: hourly, selectedTime: sharedTime)
        let highlightedBar = color(446, hourlyTop + 46 + headerOffset)
        XCTAssertGreaterThan(highlightedBar[1] - highlightedBar[0], bar[1] - bar[0] + 30)
        XCTAssertNotEqual(color(420, tooltipY), beforeTooltip)
        XCTAssertEqual(color(180, tooltipY), outsideTooltip)
        XCTAssertEqual(rows(hourlyAxisRows), hourlyAxis)

        if let directory = ProcessInfo.processInfo.environment["FLEET_UI_CAPTURE_DIR"] {
            let height = Int((overview.height + hourly.height * 2) * 2)
            let preview = try XCTUnwrap(CGContext(data: nil, width: pixelWidth, height: height, bitsPerComponent: 8,
                                                  bytesPerRow: bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            let captures: [(name: String, theme: ColorScheme, legend: Bool)] = [
                ("quota-linked-readouts.png", .dark, false),
                ("quota-linked-readouts-light.png", .light, false),
                ("quota-legend-sections.png", .dark, true)
            ]
            for (name, theme, showsLegend) in captures {
                preview.saveGState()
                preview.translateBy(x: 0, y: CGFloat(height))
                preview.scaleBy(x: 2, y: -2)
                figure.draw(.overview, in: preview, size: overview, selectedTime: selected, showsLegend: showsLegend,
                            colorScheme: theme)
                preview.translateBy(x: 0, y: overview.height)
                figure.draw(.hourly, in: preview, size: hourly, selectedTime: sharedTime, showsLegend: showsLegend,
                            colorScheme: theme)
                preview.translateBy(x: 0, y: hourly.height)
                tokens.draw(.hourly, in: preview, size: hourly, selectedTime: sharedTime, showsLegend: showsLegend,
                            colorScheme: theme)
                preview.restoreGState()
                let image = try XCTUnwrap(preview.makeImage())
                try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to:
                    URL(fileURLWithPath: directory).appendingPathComponent(name))
            }
        }
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

    func testWeeklyHoverSnapsToAPacingCrossingEquallyFromEitherSide() throws {
        let reset = base.addingTimeInterval(WeeklyQuotaPace.weekSeconds - 4 * hour)
        let crossing = base.addingTimeInterval(hour)
        let now = base.addingTimeInterval(3 * hour)
        var history = WeeklyQuotaHistory()
        for minute in stride(from: 0, through: 180, by: 10) {
            let time = base.addingTimeInterval(Double(minute * 60))
            history.observe([report("a", at: time, reset: reset, used: time < crossing ? 14 : 16)], now: time)
        }
        let latest = report("a", at: now, reset: reset, used: 16)
        let chart = WeeklyQuotaChart(report: latest, window: latest.limits[0], history: history, now: now)
        let start = try XCTUnwrap(chart.cycleStart)
        let figure = QuotaHistoryDrawing(data: .quota(chart))
        let size = CGSize(width: 480, height: QuotaHistoryPanel.overview.height)
        XCTAssertEqual(chart.planCrossings, [crossing])
        for offset in [-61, -59, 59, 61] {
            let time = crossing.addingTimeInterval(Double(offset * 60))
            let x = 44 + 416 * time.timeIntervalSince(start) / WeeklyQuotaPace.weekSeconds
            let selected = try XCTUnwrap(figure.selection(at: CGPoint(x: x, y: 70), in: size, panel: .overview))
            let expected = abs(offset) < 60 ? crossing : time
            XCTAssertEqual(selected.timeIntervalSince(expected), 0, accuracy: 0.01)
        }

        let width = Int(size.width * 2)
        let height = Int(size.height * 2)
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 2, y: -2)
        figure.draw(.overview, in: context, size: size)
        let x = Int((44 + 416 * crossing.timeIntervalSince(start) / WeeklyQuotaPace.weekSeconds) * 2)
        let y = Int((size.height - QuotaHistoryPanel.overview.axisHeight - QuotaHistoryPanel.overview.plotHeight / 7) * 2)
        let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        let hasRedMarker = (x - 5...x + 5).contains { column in
            (y - 5...y + 5).contains { row in
                let index = (row * width + column) * 4
                return Int(pixels[index]) - Int(pixels[index + 1]) > 110
            }
        }
        XCTAssertTrue(hasRedMarker)
        if let directory = ProcessInfo.processInfo.environment["FLEET_UI_CAPTURE_DIR"], let image = context.makeImage() {
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to:
                URL(fileURLWithPath: directory).appendingPathComponent("quota-pacing-crossing.png"))
        }
    }

    func testClockGridUsesMidnightAndFixedLocalHoursAcrossDaylightSaving() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Warsaw"))
        for (month, day, midnightToSix) in [(3, 29, 5), (10, 25, 7)] {
            let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: month, day: day)))
            let tomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: start))
            let ticks = QuotaHourTick.inDomain(start...tomorrow, calendar: calendar)
            XCTAssertEqual(ticks.map(\.hour), [0, 6, 12, 18, 0])
            XCTAssertEqual(ticks.filter(\.isMajor).map(\.hour), [0, 12, 0])
            XCTAssertEqual(ticks[1].date.timeIntervalSince(start), Double(midnightToSix) * hour)
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
        let prior = WeeklyQuotaChart(report: current, window: current.limits[0], history: history,
                                     now: now, displayedReset: oldReset)
        XCTAssertNil(prior.earlyResetAt)
        let bins = Dictionary(uniqueKeysWithValues: result.hours.map { ($0.start, $0.percentagePoints) })
        XCTAssertEqual(result.hours.count, 72)
        XCTAssertEqual(bins[base] ?? nil, 7)
        for missing in 1...3 { XCTAssertNil(bins[base.addingTimeInterval(Double(missing) * hour)] ?? nil) }
        XCTAssertEqual(bins[base.addingTimeInterval(4 * hour)] ?? nil, 4)
        XCTAssertEqual(result.cycleStart, oldReset)
        XCTAssertTrue(result.segments.flatMap { $0 }.allSatisfy { $0.reset == newReset })
    }

    func testHourWithAnEarlyResetKeepsTheObservedNewCycleUsage() throws {
        let oldReset = base.addingTimeInterval(48 * hour)
        let newReset = base.addingTimeInterval(WeeklyQuotaPace.weekSeconds + 2 * 60)
        let readings = [(0, 97), (1, 99), (2, 0), (10, 2), (20, 3), (30, 5), (40, 6), (50, 8), (60, 8)]
        var history = WeeklyQuotaHistory()
        for (minute, used) in readings {
            let time = base.addingTimeInterval(Double(minute * 60))
            let reset = minute < 2 ? oldReset : newReset
            history.observe([report("a", at: time, reset: reset, used: used)], now: time)
        }
        let now = base.addingTimeInterval(hour)
        let latest = report("a", at: now, reset: newReset, used: 8)
        let chart = WeeklyQuotaChart(report: latest, window: latest.limits[0], history: history, now: now)
        let resetHour = try XCTUnwrap(chart.hours.first { $0.start == base })
        XCTAssertNil(resetHour.percentagePoints)
        XCTAssertEqual(resetHour.partialPercentagePoints, 8)
        let readout = QuotaHistoryDrawing(data: .quota(chart)).accessibilityDetails(for: .hourly, selectedTime: base)
        XCTAssertTrue(readout.contains("8.0% of weekly quota · partial hour"))
    }

    func testAStaleTokenSnapshotExplainsAnUnscannedHour() {
        let calendar = Calendar.current
        let now = base.addingTimeInterval(hour)
        let previous = base.addingTimeInterval(-hour)
        var snapshot = UsageAnalyticsSnapshot.empty
        snapshot.statisticsRevision = UsageAnalyticsSnapshot.currentRevision
        snapshot.timeZoneIdentifier = calendar.timeZone.identifier
        snapshot.refreshedAt = base.addingTimeInterval(-10 * 60)
        let tokens = UsageTotals(inputTokens: 120, cachedInputTokens: 60, cacheWriteInputTokens: 0,
                                 outputTokens: 8, reasoningOutputTokens: 0, estimatedCostUSD: 0)
        snapshot.codex.hourlyModels = [HourlyModelUsage(hour: previous, model: "Fixture", tokens: tokens)]
        let stale = LocalTokenHistory(snapshot: snapshot, provider: .codex, now: now, calendar: calendar)
        let staleDrawing = QuotaHistoryDrawing(data: .tokens(stale), calendar: calendar)
        let unscanned = staleDrawing.accessibilityDetails(for: .hourly, selectedTime: base)
        XCTAssertTrue(unscanned.contains("Awaiting local log scan. Last scan"))

        snapshot.refreshedAt = now
        snapshot.codex.hourlyModels.append(HourlyModelUsage(hour: base, model: "Fixture", tokens: tokens))
        let refreshed = LocalTokenHistory(snapshot: snapshot, provider: .codex, now: now, calendar: calendar)
        let updated = QuotaHistoryDrawing(data: .tokens(refreshed), calendar: calendar)
        XCTAssertTrue(updated.accessibilityDetails(for: .hourly, selectedTime: base).contains("Total · 128 tokens"))
    }

    func testTokenCoverageUsesTheStartOfTheScanAndDoesNotSwitchTheSelectedModel() {
        let calendar = Calendar.current
        let current = calendar.dateInterval(of: .hour, for: base)!.start
        let previous = current.addingTimeInterval(-hour)
        var snapshot = UsageAnalyticsSnapshot.empty
        snapshot.statisticsRevision = UsageAnalyticsSnapshot.currentRevision
        snapshot.timeZoneIdentifier = calendar.timeZone.identifier
        snapshot.scannedThrough = previous.addingTimeInterval(50 * 60)
        snapshot.refreshedAt = current.addingTimeInterval(5 * 60)
        let usage = UsageTotals(inputTokens: 100, cachedInputTokens: 20, cacheWriteInputTokens: 0,
                                outputTokens: 10, reasoningOutputTokens: 0, estimatedCostUSD: 0)
        snapshot.codex.hourlyModels = [HourlyModelUsage(hour: previous, model: "Actual", tokens: usage)]
        let history = LocalTokenHistory(snapshot: snapshot, provider: .codex, now: current, calendar: calendar)
        XCTAssertEqual(history.hours.suffix(2).first?.tokens?.totalTokens, 110)
        XCTAssertTrue(history.hours.suffix(2).first?.partial == true)
        XCTAssertNil(history.hours.last?.tokens)
        let filtered = LocalTokenHistory(snapshot: snapshot, provider: .codex, model: "Selected",
                                         now: current, calendar: calendar)
        XCTAssertTrue(filtered.models.contains("Selected"))
        XCTAssertEqual(filtered.hours.suffix(2).first?.tokens?.totalTokens, 0)
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
            XCTAssertFalse(label.contains(zone), label)
            let bucket = UsageHours(now: date, calendar: calendar).last
            XCTAssertEqual(calendar.component(.hour, from: bucket), expectedHour)
            XCTAssertEqual(calendar.component(.minute, from: bucket), 0)
        }
    }

    func testChartHourLabelsTheLocalInterval() throws {
        let formatter = ISO8601DateFormatter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Warsaw"))
        let locale = Locale(identifier: "en_US")
        let evening = try XCTUnwrap(formatter.date(from: "2026-11-25T17:00:00Z"))
        let late = try XCTUnwrap(formatter.date(from: "2026-11-25T22:00:00Z"))
        XCTAssertEqual(chartHour(evening, calendar: calendar, locale: locale), "Nov 25 18–19")
        XCTAssertEqual(chartHour(late, calendar: calendar, locale: locale), "Nov 25 23–Nov 26 00")

        let first = try XCTUnwrap(formatter.date(from: "2026-10-25T00:00:00Z"))
        let second = first.addingTimeInterval(hour)
        XCTAssertNotEqual(chartHour(first, calendar: calendar, locale: locale),
                          chartHour(second, calendar: calendar, locale: locale))
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
        XCTAssertTrue(description.contains(". Total · 1 213 tokens · partial hour. Uncached input · 200 tokens (16.5%)"))
        XCTAssertTrue(description.contains("Cache · 1 000 tokens (82.4%)"))
        XCTAssertTrue(description.contains("Output · 13 tokens (1.1%)"))

        let output = QuotaHistoryDrawing(data: .tokens(history, series: .output), calendar: calendar)
        let filtered = output.accessibilityDetails(for: .hourly, selectedTime: last)
        XCTAssertTrue(filtered.contains("Total · 1 213 tokens · partial hour. Output · 13 tokens (1.1%)"))
        XCTAssertFalse(filtered.contains("Cache"))
    }

    func testHourlyTokenMeanUsesCoveredHoursAndTheSelectedSeries() {
        let calendar = Calendar.current
        let now = base.addingTimeInterval(600)
        let hours = UsageHours(now: now, calendar: calendar)
        var snapshot = UsageAnalyticsSnapshot.empty
        snapshot.statisticsRevision = UsageAnalyticsSnapshot.currentRevision
        snapshot.timeZoneIdentifier = calendar.timeZone.identifier
        snapshot.refreshedAt = now
        snapshot.codex.hourlyModels = [
            HourlyModelUsage(hour: hours.start, model: "Fixture", tokens: UsageTotals(
                inputTokens: 5_680, cachedInputTokens: 0, cacheWriteInputTokens: 0, outputTokens: 1_420,
                reasoningOutputTokens: 0, estimatedCostUSD: 0)),
            HourlyModelUsage(hour: hours.last, model: "Fixture", tokens: UsageTotals(
                inputTokens: 1_000_000, cachedInputTokens: 0, cacheWriteInputTokens: 0, outputTokens: 200_000,
                reasoningOutputTokens: 0, estimatedCostUSD: 0))
        ]
        let history = LocalTokenHistory(snapshot: snapshot, provider: .codex, now: now, calendar: calendar,
                                        range: .sevenDays)
        let all = QuotaHistoryDrawing(data: .tokens(history), calendar: calendar)
        let output = QuotaHistoryDrawing(data: .tokens(history, series: .output), calendar: calendar)
        XCTAssertEqual(all.headerMetrics(for: .hourly).map(\.label), ["Average 100/h", "Median 0/h"])
        XCTAssertEqual(output.headerMetrics(for: .hourly).map(\.label), ["Average 20/h", "Median 0/h"])
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

    @MainActor
    private func target(_ provider: StatisticsProvider, id: String, windows: [ProviderLimitWindow],
                        now: Date, email: String = "fixture@example.test") throws -> QuotaHistoryTarget {
        let connection = ProviderConnection(id: id, providerID: provider.rawValue, globalAssociation: true)
        let account = FleetAccount(id: id, badgeIndex: windows.isEmpty ? 1 : 0, name: "Fixture", email: email,
                                   connections: [connection])
        let status = ProviderStatus(id: provider.rawValue, name: provider.title,
                                    state: windows.isEmpty ? .noKey : .ok, detail: "Fixture", lastUpdated: now,
                                    remainingPercent: windows.first?.remainingPercent, limitWindows: windows,
                                    account: windows.isEmpty ? nil : ProviderAccountIdentity(
                                        email: account.email, organizationID: nil, organizationName: nil, subscriptionType: nil))
        let row = MenuAccountConnection(account: account, connection: connection, status: status, isSelected: true)
        return try XCTUnwrap(QuotaHistoryTarget(row: row, codex: CodexMonitoringStore.shared))
    }
}

@MainActor
private final class QuotaHistorySelectionFixture: ObservableObject {
    @Published var request: QuotaHistoryRequest?
}

private struct QuotaHistoryLayoutFixture: View {
    let targets: [QuotaHistoryTarget]
    @ObservedObject var fixture: QuotaHistorySelectionFixture

    var body: some View {
        QuotaHistoryView(targets: targets, selection: $fixture.request)
            .frame(width: 740)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}
