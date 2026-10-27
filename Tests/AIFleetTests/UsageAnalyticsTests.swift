import XCTest
@testable import AIFleet

final class UsageAnalyticsTests: XCTestCase {
    func testAccountUsageReaderDecodesSummaryAndDailyBuckets() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let fetchedAt = Date(timeIntervalSince1970: 123)
        let response = Data(#"{"id":1,"result":{"summary":{"lifetimeTokens":11803044372,"peakDailyTokens":848260974,"longestRunningTurnSec":900,"currentStreakDays":11,"longestStreakDays":31},"dailyUsageBuckets":[{"startDate":"2026-08-22","tokens":42000}]}}"#.utf8)

        let usage = try CodexAccountUsageReader(executableURL: nil).decode(
            response: response,
            fetchedAt: fetchedAt,
            calendar: calendar
        )

        XCTAssertEqual(usage.lifetimeTokens, 11_803_044_372)
        XCTAssertEqual(usage.currentStreakDays, 11)
        XCTAssertEqual(usage.daily.map(\.tokens), [42_000])
        XCTAssertEqual(usage.fetchedAt, fetchedAt)
    }

    func testLocalDaysFollowComputerMidnightAcrossDSTChanges() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Warsaw"))
        let formatter = ISO8601DateFormatter()
        // Midnight is UTC+2 before the autumn transition and UTC+1 after it.
        for (before, after, monthDay) in [
            ("2026-10-23T21:59:59Z", "2026-10-23T22:00:00Z", 24),
            ("2026-10-26T22:59:59Z", "2026-10-26T23:00:00Z", 27)
        ] {
            var totals = UsageTotals.zero
            totals.inputTokens = 100
            totals.outputTokens = 20
            let entries = try [before, after].map {
                CodexUsageLogEntry(timestamp: try XCTUnwrap(formatter.date(from: $0)), model: "gpt-test", totals: totals)
            }
            let reader = CodexUsageLogReader(calendar: calendar)
            let analytics = reader.analytics(from: entries, fileCount: 1)
            let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: monthDay)))
            let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: day))
            let todaySelection = codexUsageSelection(from: analytics, start: day, end: day, calendar: calendar)
            let yesterdaySelection = codexUsageSelection(from: analytics, start: yesterday, end: yesterday, calendar: calendar)
            XCTAssertEqual(todaySelection.totalTokens, 120)
            XCTAssertEqual(yesterdaySelection.totalTokens, 120)
            XCTAssertEqual(todaySelection.eventCount, 1)
            XCTAssertEqual(yesterdaySelection.eventCount, 1)
        }
    }

    func testFileCacheReparsesWhenComputerTimeZoneChangesOrIsUnknown() throws {
        let file = CodexLogFile(url: URL(fileURLWithPath: "/tmp/session.jsonl"), modifiedAt: Date(), size: 42)
        let warsaw = try XCTUnwrap(TimeZone(identifier: "Europe/Warsaw"))
        let utc = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        var record = CodexFileUsageRecord(path: file.url.path, modifiedAt: file.modifiedAt, size: file.size, dailyModels: [], timeZoneIdentifier: warsaw.identifier)
        XCTAssertTrue(record.matches(file, timeZone: warsaw))
        XCTAssertFalse(record.matches(file, timeZone: utc))
        record.timeZoneIdentifier = nil
        XCTAssertFalse(record.matches(file, timeZone: warsaw))
    }

    func testCodexUsageReaderReadsNestedTokenUsage() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let file = directory.appendingPathComponent("session.jsonl")
        let line = """
        {"timestamp":"2026-08-22T12:00:00.000Z","type":"event_msg","payload":{"info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":200,"cache_write_input_tokens":50,"output_tokens":300,"reasoning_output_tokens":40,"total_tokens":1300}}}}
        """
        try line.write(to: file, atomically: true, encoding: .utf8)

        let entries = CodexUsageLogReader().readEntries(from: file)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].totals.inputTokens, 1000)
        XCTAssertEqual(entries[0].totals.cachedInputTokens, 200)
        XCTAssertEqual(entries[0].totals.cacheWriteInputTokens, 50)
        XCTAssertEqual(entries[0].totals.outputTokens, 300)
        XCTAssertEqual(entries[0].totals.reasoningOutputTokens, 40)
    }
}
