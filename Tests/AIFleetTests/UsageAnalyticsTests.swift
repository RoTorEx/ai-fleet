import XCTest
@testable import AIFleet

final class UsageAnalyticsTests: XCTestCase {
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
