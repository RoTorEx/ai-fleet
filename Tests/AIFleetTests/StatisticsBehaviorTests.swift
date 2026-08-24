import AppKit
import XCTest
@testable import AIFleet

final class StatisticsBehaviorTests: XCTestCase {
    func testLimitNotificationNamesWindowAndShowsRelativeAndExactReset() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 24, hour: 3, minute: 30
        )))
        let resetAt = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 29, hour: 21, minute: 18
        )))

        XCTAssertEqual(
            limitNotificationBody(
                providerName: "Codex",
                threshold: 5,
                windowLabel: "7d",
                resetAt: resetAt,
                now: now,
                calendar: calendar
            ),
            "Codex reached 5% threshold (7d).\nResets in 5d 17h · Aug 29 at 21:18."
        )
    }

    func testLimitNotificationFallsBackWhenResetIsUnavailable() {
        XCTAssertEqual(
            limitNotificationBody(providerName: "Kimi", threshold: 25, windowLabel: "5h"),
            "Kimi reached 25% threshold (5h)."
        )
    }

    func testNotificationResetIncludesWindowScopedState() {
        let keys = [
            "notify.remainingLast.codex.primary",
            "notify.remainingNotifiedThresholds.kimi.weekly",
            "notify.remainingLast.codex",
            "notify.remainingThresholds",
            "provider.codex.enabled"
        ]

        XCTAssertEqual(
            Set(notificationStateKeysToReset(keys)),
            Set([
                "notify.remainingLast.codex.primary",
                "notify.remainingNotifiedThresholds.kimi.weekly",
                "notify.remainingLast.codex"
            ])
        )
    }

    func testNextDailyRefreshUsesNextLocalOccurrence() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 22, hour: 13, minute: 0
        )))

        let next = nextDailyRefreshDate(
            after: now,
            minutesAfterMidnight: 12 * 60,
            calendar: calendar
        )

        XCTAssertEqual(
            calendar.dateComponents([.year, .month, .day, .hour, .minute], from: next),
            DateComponents(year: 2026, month: 8, day: 23, hour: 12, minute: 0)
        )
    }

    func testRangeSelectionRecalculatesTotalsModelsAndEvents() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let firstDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 20)))
        let secondDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 21)))
        let firstTotals = totals(input: 100, output: 20, reasoning: 5)
        let secondTotals = totals(input: 300, output: 40, reasoning: 12)
        let codex = CodexUsageAnalytics(
            total: combined(firstTotals, secondTotals),
            today: .zero,
            sevenDays: .zero,
            thirtyDays: .zero,
            daily: [
                DailyUsage(day: firstDay, totals: firstTotals),
                DailyUsage(day: secondDay, totals: secondTotals)
            ],
            models: [],
            dailyModels: [
                DailyModelUsage(day: firstDay, model: "gpt-a", totals: firstTotals, events: 2),
                DailyModelUsage(day: secondDay, model: "gpt-b", totals: secondTotals, events: 3)
            ],
            eventCount: 5,
            fileCount: 2,
            source: "test"
        )

        let selection = codexUsageSelection(
            from: codex,
            start: secondDay,
            end: secondDay,
            calendar: calendar
        )

        XCTAssertEqual(selection.totals.totalTokens, 340)
        XCTAssertEqual(selection.totals.reasoningOutputTokens, 12)
        XCTAssertEqual(selection.daily.map(\.day), [secondDay])
        XCTAssertEqual(selection.models.map(\.model), ["gpt-b"])
        XCTAssertEqual(selection.eventCount, 3)
    }

    func testFileUsageCacheMatchesOnlyUnchangedMetadata() {
        let date = Date(timeIntervalSince1970: 1_000)
        let url = URL(fileURLWithPath: "/tmp/session.jsonl")
        let record = CodexFileUsageRecord(path: url.path, modifiedAt: date, size: 42, dailyModels: [])

        XCTAssertTrue(record.matches(CodexLogFile(url: url, modifiedAt: date, size: 42)))
        XCTAssertFalse(record.matches(CodexLogFile(url: url, modifiedAt: date, size: 43)))
    }

    func testAllTimeSelectionKeepsHistoryBeyondThirtyDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let firstDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 6, day: 1)))
        let totals = totals(input: 10, output: 2, reasoning: 1)
        let days = (0..<45).compactMap { offset -> DailyUsage? in
            guard let day = calendar.date(byAdding: .day, value: offset, to: firstDay) else { return nil }
            return DailyUsage(day: day, totals: totals)
        }
        let dailyModels = days.map {
            DailyModelUsage(day: $0.day, model: "gpt-test", totals: totals, events: 1)
        }
        let codex = CodexUsageAnalytics(
            total: days.reduce(into: UsageTotals.zero) { $0.add($1.totals) },
            today: .zero,
            sevenDays: .zero,
            thirtyDays: .zero,
            daily: days,
            models: [],
            dailyModels: dailyModels,
            eventCount: days.count,
            fileCount: 1,
            source: "test"
        )

        let selection = codexUsageSelection(from: codex, start: nil, end: nil, calendar: calendar)

        XCTAssertEqual(selection.daily.count, 45)
        XCTAssertEqual(selection.eventCount, 45)
    }

    func testAccountUsageDrivesTotalAndDaysWhileLocalLogsDriveDetails() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let firstDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 20)))
        let secondDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 21)))
        let localTotals = UsageTotals(
            inputTokens: 90,
            cachedInputTokens: 50,
            cacheWriteInputTokens: 0,
            outputTokens: 10,
            reasoningOutputTokens: 2,
            estimatedCostUSD: 1.25
        )
        let account = CodexAccountUsage(
            lifetimeTokens: 9_000,
            peakDailyTokens: 8_000,
            longestRunningTurnSeconds: nil,
            currentStreakDays: nil,
            longestStreakDays: nil,
            daily: [
                CodexAccountDailyUsage(day: firstDay, tokens: 3_000),
                CodexAccountDailyUsage(day: secondDay, tokens: 6_000)
            ],
            fetchedAt: Date()
        )
        let codex = CodexUsageAnalytics(
            total: localTotals,
            today: .zero,
            sevenDays: .zero,
            thirtyDays: .zero,
            daily: [DailyUsage(day: secondDay, totals: localTotals)],
            models: [],
            dailyModels: [DailyModelUsage(day: secondDay, model: "gpt-test", totals: localTotals, events: 1)],
            eventCount: 1,
            fileCount: 1,
            source: "test",
            accountUsage: account
        )

        let all = codexUsageSelection(from: codex, start: nil, end: nil, calendar: calendar)
        let firstOnly = codexUsageSelection(from: codex, start: firstDay, end: firstDay, calendar: calendar)

        XCTAssertEqual(all.totalTokens, 9_000)
        XCTAssertEqual(all.totals.totalTokens, 100)
        XCTAssertEqual(all.daily.map(\.tokens), [3_000, 6_000])
        XCTAssertEqual(all.estimatedCostUSD, 112.5, accuracy: 0.001)
        XCTAssertEqual(all.daily[0].estimatedCostUSD, 37.5)
        XCTAssertEqual(all.daily[1].estimatedCostUSD, 75)
        XCTAssertTrue(all.usesAccountUsage)
        XCTAssertEqual(firstOnly.totalTokens, 3_000)
        XCTAssertEqual(firstOnly.estimatedCostUSD, 37.5, accuracy: 0.001)
    }

    func testHeatmapBuildsCalendarWeeksAndLevels() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let monday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 3)))
        let nextMonday = try XCTUnwrap(calendar.date(byAdding: .day, value: 7, to: monday))
        let months = heatmapMonths(from: [
            CodexSelectedDay(day: monday, tokens: 10, estimatedCostUSD: 1.25),
            CodexSelectedDay(day: nextMonday, tokens: 40, estimatedCostUSD: nil)
        ], calendar: calendar)

        XCTAssertEqual(months.count, 1)
        XCTAssertEqual(months[0].label, "Aug")
        XCTAssertEqual(months.flatMap(\.weeks).flatMap { $0 }.compactMap { $0 }.count, 8)
        XCTAssertEqual(
            months.flatMap(\.weeks).flatMap { $0 }.compactMap { $0 }.first { $0.day == monday }?.estimatedCostUSD,
            1.25
        )
        XCTAssertEqual(heatmapLevel(tokens: 0, maximum: 40), 0)
        XCTAssertEqual(heatmapLevel(tokens: 10, maximum: 40), 1)
        XCTAssertEqual(heatmapLevel(tokens: 40, maximum: 40), 4)
    }

    func testHeatmapKeepsMonthLabelsInSeparateGroups() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let july = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 31)))
        let august = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 1)))

        let months = heatmapMonths(from: [
            CodexSelectedDay(day: july, tokens: 10, estimatedCostUSD: nil),
            CodexSelectedDay(day: august, tokens: 20, estimatedCostUSD: nil)
        ], calendar: calendar)

        XCTAssertEqual(months.map(\.label), ["Jul", "Aug"])
        XCTAssertEqual(months.flatMap(\.weeks).flatMap { $0 }.compactMap { $0 }.map(\.tokens), [10, 20])
    }

    func testHeatmapHorizonCompletesFirstVibecodingYearThenEndsAtCurrentMonth() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 2, day: 15)))
        let duringFirstYear = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 24)))
        let afterFirstYear = try XCTUnwrap(calendar.date(from: DateComponents(year: 2027, month: 2, day: 20)))

        XCTAssertEqual(
            heatmapHorizon(startingAt: start, now: duringFirstYear, calendar: calendar),
            calendar.date(from: DateComponents(year: 2027, month: 2, day: 14))
        )
        XCTAssertEqual(
            heatmapHorizon(startingAt: start, now: afterFirstYear, calendar: calendar),
            calendar.date(from: DateComponents(year: 2027, month: 2, day: 28))
        )
    }

    func testLogDiscoveryIncludesArchiveAndDeduplicatesMovedSessions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let active = root.appendingPathComponent("sessions")
        let archive = root.appendingPathComponent("archived_sessions")
        try FileManager.default.createDirectory(at: active, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let movedName = "rollout-moved.jsonl"
        try Data().write(to: active.appendingPathComponent(movedName))
        try Data().write(to: archive.appendingPathComponent(movedName))
        try Data().write(to: archive.appendingPathComponent("rollout-archived.jsonl"))

        let files = CodexUsageLogReader().codexLogFileMetadata(roots: [active, archive])

        XCTAssertEqual(files.count, 2)
        XCTAssertTrue(files.contains {
            $0.url.lastPathComponent == movedName && $0.url.deletingLastPathComponent().lastPathComponent == "sessions"
        })
        XCTAssertTrue(files.contains { $0.url.lastPathComponent == "rollout-archived.jsonl" })
    }

    func testStatisticsWindowCentersInsideVisibleScreen() {
        let visible = NSRect(x: 100, y: 50, width: 1_200, height: 800)
        let centered = centeredWindowFrame(
            windowFrame: NSRect(x: -2_000, y: 2_000, width: 1_600, height: 1_000),
            visibleFrame: visible
        )

        XCTAssertGreaterThanOrEqual(centered.minX, visible.minX)
        XCTAssertGreaterThanOrEqual(centered.minY, visible.minY)
        XCTAssertLessThanOrEqual(centered.maxX, visible.maxX)
        XCTAssertLessThanOrEqual(centered.maxY, visible.maxY)
        XCTAssertEqual(centered.size, visible.size)
    }

    func testTokenVolumeHelpCyclesThroughRequiredBooksAndElevenMore() {
        let examples = tokenVolumeHelpExamples(1_000_000, metric: .total)
        let combined = examples.joined(separator: "\n")
        let input = tokenVolumeHelpExamples(750_000, metric: .input)
        let output = tokenVolumeHelpExamples(250_000, metric: .output)

        XCTAssertEqual(examples.count, 15)
        XCTAssertTrue(combined.contains("The Little Prince"))
        XCTAssertTrue(combined.contains("The Hobbit"))
        XCTAssertTrue(combined.contains("complete Lord of the Rings trilogy"))
        XCTAssertTrue(combined.contains("complete seven-book Harry Potter series"))
        XCTAssertTrue(combined.contains("1984"))
        XCTAssertTrue(combined.contains("Brave New World"))
        XCTAssertTrue(combined.contains("Cached context can be counted repeatedly"))
        XCTAssertTrue(examples.allSatisfy { $0.hasPrefix("Total tokens cover everything the model processed") })
        XCTAssertTrue(input.allSatisfy { $0.hasPrefix("Input tokens cover everything the model read") })
        XCTAssertTrue(output.allSatisfy { $0.hasPrefix("Output tokens cover everything the model generated") })
        XCTAssertTrue(output.joined().contains("internal reasoning reported by Codex"))
        XCTAssertTrue((examples + input + output).allSatisfy { $0.contains("\n\nFor a sense of scale") })
        XCTAssertTrue(input.joined().contains("Cached context can be counted repeatedly"))
        XCTAssertFalse(output.joined().contains("Cached context can be counted repeatedly"))
        XCTAssertFalse(combined.contains("0.75"))
        XCTAssertFalse(combined.contains("Russian"))
    }

    func testBookComparisonsUseWholeNaturalCopyCounts() {
        XCTAssertEqual(bookCopyComparison(0.4, title: "Dune"), "less than one copy of Dune")
        XCTAssertEqual(bookCopyComparison(1.2, title: "Dune"), "roughly one copy of Dune")
        XCTAssertEqual(bookCopyComparison(12.6, title: "Dune"), "roughly 13 copies of Dune")
        XCTAssertEqual(bookCopyComparison(12_345.6, title: "Dune"), "roughly 12 346 copies of Dune")
        XCTAssertTrue(tokenVolumeHelpExamples(1_000_000).contains { $0.contains("~1 084 000 words each") })
        XCTAssertFalse(bookCopyComparison(12.6, title: "Dune").contains("."))
    }

    func testStatisticsNumbersUseSpacesForGroupingAndDotsForDecimals() {
        XCTAssertEqual(groupedInteger(73_938), "73 938")
        XCTAssertEqual(compactCount(11_803_040_000), "11 803.04M")
        XCTAssertEqual(compactCount(37_910_000), "37.91M")
        XCTAssertEqual(billionsCount(11_803_040_000), "11.80B")
        XCTAssertEqual(millionsCount(383_530_000), "383.53M")
        XCTAssertEqual(money(6_982), "$6 982")
        XCTAssertEqual(money(2_695.4), "$2 695")
        XCTAssertEqual(money(97.7), "$97.7")
    }

    private func totals(input: Int, output: Int, reasoning: Int) -> UsageTotals {
        UsageTotals(
            inputTokens: input,
            cachedInputTokens: 0,
            cacheWriteInputTokens: 0,
            outputTokens: output,
            reasoningOutputTokens: reasoning,
            estimatedCostUSD: 0
        )
    }

    private func combined(_ lhs: UsageTotals, _ rhs: UsageTotals) -> UsageTotals {
        var result = lhs
        result.add(rhs)
        return result
    }
}
