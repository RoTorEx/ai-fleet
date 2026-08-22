import AppKit
import XCTest
@testable import AIFleet

final class StatisticsBehaviorTests: XCTestCase {
    func testLimitNotificationNamesWindowAndEndsAtPeriod() {
        XCTAssertEqual(
            limitNotificationBody(providerName: "Codex", threshold: 5, windowLabel: "7d"),
            "Codex reached 5% threshold (7d)."
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
            windowFrame: NSRect(x: -2_000, y: 2_000, width: 900, height: 650),
            visibleFrame: visible
        )

        XCTAssertGreaterThanOrEqual(centered.minX, visible.minX)
        XCTAssertGreaterThanOrEqual(centered.minY, visible.minY)
        XCTAssertLessThanOrEqual(centered.maxX, visible.maxX)
        XCTAssertLessThanOrEqual(centered.maxY, visible.maxY)
    }

    func testTokenVolumeHelpUsesBookScaleAndExplainsRepeatedCache() {
        let help = tokenVolumeHelp(1_000_000)

        XCTAssertTrue(help.contains("7.5 novels"))
        XCTAssertTrue(help.contains("repeated cached context"))
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
