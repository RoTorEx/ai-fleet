import XCTest
@testable import AIFleet

final class ClaudeUsageAnalyticsTests: XCTestCase {
    func testRepeatedContentBlocksCountOnceAndKeepFinalUsage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.jsonl")
        try """
        {"type":"assistant","requestId":"req1","timestamp":"2026-10-26T12:00:00Z","message":{"id":"msg1","model":"claude-opus-5-5","usage":{"input_tokens":10,"cache_read_input_tokens":100,"cache_creation_input_tokens":20,"output_tokens":2}}}
        {"type":"assistant","requestId":"req1","timestamp":"2026-10-26T12:00:00.100Z","message":{"id":"msg1","model":"claude-opus-5-5","usage":{"input_tokens":10,"cache_read_input_tokens":100,"cache_creation_input_tokens":20,"cache_creation":{"ephemeral_1h_input_tokens":10},"output_tokens":30,"output_tokens_details":{"thinking_tokens":12}}}}
        {"type":"assistant","requestId":"req1","timestamp":"2026-10-26T12:00:00.200Z","message":{"id":"msg1","model":"claude-opus-5-5","usage":{"input_tokens":10,"cache_read_input_tokens":100,"cache_creation_input_tokens":20,"output_tokens":2}}}
        {"type":"user","timestamp":"2026-10-26T12:01:00Z","message":{"usage":{"input_tokens":9000}}}
        {"type":"assistant","timestamp":"2026-10-26T12:01:00Z","message":{"id":"fake","model":"<synthetic>","usage":{"output_tokens":9000}}}
        malformed partial line
        """.write(to: file, atomically: true, encoding: .utf8)

        let entries = ClaudeUsageLogReader().readEntries(from: file)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entry.totals.inputTokens, 130)
        XCTAssertEqual(entry.totals.billableInputTokens, 10)
        XCTAssertEqual(entry.totals.outputTokens, 30)
        XCTAssertEqual(entry.totals.reasoningOutputTokens, 12)
        XCTAssertEqual(entry.totals.totalTokens, 160)
        XCTAssertEqual(entry.totals.estimatedCostUSD, 0.00079, accuracy: 0.00000001)
    }

    func testNestedTranscriptsFeedCachedPeriodSelectionAndUnknownPrices() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let agents = root.appendingPathComponent("session/subagents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        {"type":"assistant","timestamp":"2026-10-25T12:00:00Z","message":{"id":"same-id","model":"claude-haiku-4-5-20251001","usage":{"input_tokens":100,"output_tokens":20}}}
        """.write(to: root.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
        try """
        {"type":"assistant","timestamp":"2026-10-26T12:00:00Z","message":{"id":"agent-id","model":"claude-future-model","usage":{"input_tokens":200,"output_tokens":40}}}
        """.write(to: agents.appendingPathComponent("agent.jsonl"), atomically: true, encoding: .utf8)
        let reader = ClaudeUsageLogReader()
        let files = reader.logFileMetadata(root: root)
        let records = files.map { reader.usageRecord(for: $0) }
        let cached = try JSONDecoder().decode([CodexFileUsageRecord].self, from: JSONEncoder().encode(records))
        let analytics = CodexUsageLogReader().analytics(from: cached, fileCount: files.count)
        let all = codexUsageSelection(from: analytics, start: nil, end: nil)
        let firstDay = try XCTUnwrap(analytics.daily.first?.day)
        let first = codexUsageSelection(from: analytics, start: firstDay, end: firstDay)
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(all.totalTokens, 360)
        XCTAssertEqual(all.eventCount, 2)
        XCTAssertEqual(all.models.count, 2)
        XCTAssertFalse(all.usesAccountUsage)
        XCTAssertFalse(all.totals.hasCostEstimate)
        XCTAssertNil(all.daily.last(where: { $0.tokens > 0 })?.estimatedCostUSD)
        XCTAssertEqual(first.totalTokens, 120)
        XCTAssertEqual(first.models.map(\.model), ["claude-haiku-4-5-20251001"])
        XCTAssertTrue(first.totals.hasCostEstimate)
        XCTAssertEqual(first.estimatedCostUSD, 0.0002, accuracy: 0.00000001)
        XCTAssertNil(ClaudeAPIRates.rates(for: "claude-opus-4-99"))
    }

    func testOldSnapshotLoadsAndClaudeRoundTripsWithoutLosingCodex() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(UsageAnalyticsSnapshot.empty)) as? [String: Any])
        let old = try decoder.decode(UsageAnalyticsSnapshot.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(old.claude)
        var next = old
        next.claude = .empty
        next.claude?.total.inputTokens = 123
        let restored = try decoder.decode(UsageAnalyticsSnapshot.self, from: encoder.encode(next))
        XCTAssertEqual(restored.codex, old.codex)
        XCTAssertEqual(restored.claude?.total.inputTokens, 123)
        XCTAssertTrue(restored.codex.total.hasCostEstimate)
    }
}
