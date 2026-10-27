import XCTest
@testable import AIFleet

final class ProviderUsageAnalyticsTests: XCTestCase {
    func testKimiV2CountsCompletedStepsOnceAcrossLocalMidnight() throws {
        try withDirectory { root in
            let file = try write(root, "session/agents/main/wire.jsonl", """
            {"type":"metadata","protocol_version":"1.5","created_at":1793050000000}
            {"type":"profile.bind","modelAlias":"kimi-k2.5","time":1793050000000}
            {"type":"context.append_loop_event","time":1793055599000,"event":{"type":"step.end","uuid":"request-1","usage":{"inputOther":100,"inputCacheRead":50,"inputCacheCreation":10,"output":20}}}
            {"type":"context.append_loop_event","time":1793055599000,"event":{"type":"step.end","uuid":"request-1","usage":{"inputOther":100,"inputCacheRead":50,"inputCacheCreation":10,"output":20}}}
            {"type":"config.update","modelAlias":"kimi-new","time":1793055600000}
            {"type":"context.append_loop_event","time":1793055600000,"event":{"type":"step.end","uuid":"request-2","usage":{"inputOther":200,"inputCacheRead":0,"inputCacheCreation":0,"output":30}}}
            {"type":"agent.status.updated","usage":{"total":{"inputOther":300,"output":50,"inputCacheRead":50,"inputCacheCreation":10}}}
            {"type":"context.append_loop_event","time":1793055601000,"event":{"type":"step.end","uuid":"failed-request"}}
            {"type":"context.append_message","message":{"role":"assistant","content":[{"text":"Not accounting"}]}}
            invalid partial line
            """)
            let entries = KimiUsageLogReader().readEntries(from: file)
            XCTAssertEqual(entries.count, 2)
            XCTAssertEqual(entries.map(\.model), ["kimi-k2.5", "kimi-new"])
            XCTAssertEqual(entries[0].totals.inputTokens, 160)
            XCTAssertEqual(entries[0].totals.totalTokens, 180)
            XCTAssertEqual(entries[0].totals.cacheWriteInputTokens, 10)
            XCTAssertFalse(entries[0].totals.hasCostEstimate)

            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Warsaw"))
            let reader = CodexUsageLogReader(calendar: calendar)
            let analytics = reader.analytics(from: entries, fileCount: 1)
            let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 27)))
            let selected = codexUsageSelection(from: analytics, start: today, end: today, calendar: calendar)
            XCTAssertEqual(selected.totalTokens, 230)
            XCTAssertEqual(selected.eventCount, 1)
            XCTAssertEqual(selected.models.map(\.model), ["kimi-new"])
            XCTAssertFalse(selected.totals.hasCostEstimate)
            XCTAssertEqual(selected.daily.first?.tokens, 230)
        }
    }

    func testLegacyKimiStatusUsageDoesNotCountContextOrRepeatedUpdates() throws {
        try withDirectory { root in
            let file = try write(root, "wire.jsonl", """
            {"timestamp":1793055600,"message":{"type":"TurnBegin","payload":{}}}
            {"timestamp":1793055600,"message":{"type":"StepBegin","payload":{"n":1}}}
            {"timestamp":1793055601,"message":{"type":"StatusUpdate","payload":{"context_usage":0.9}}}
            {"timestamp":1793055602,"message":{"type":"StatusUpdate","payload":{"message_id":"api-1","token_usage":{"input_other":100,"input_cache_read":50,"input_cache_creation":10,"output":20}}}}
            {"timestamp":1793055602,"message":{"type":"StatusUpdate","payload":{"message_id":"api-1","token_usage":{"input_other":100,"input_cache_read":50,"input_cache_creation":10,"output":20}}}}
            {"timestamp":1793055603,"message":{"type":"StepBegin","payload":{"n":2}}}
            {"timestamp":1793055604,"message":{"type":"StatusUpdate","payload":{"token_usage":{"input_other":5,"output":2}}}}
            {"timestamp":1793055604,"message":{"type":"StatusUpdate","payload":{"token_usage":{"input_other":5,"output":2}}}}
            """)
            let entries = KimiUsageLogReader().readEntries(from: file)
            XCTAssertEqual(entries.count, 2)
            XCTAssertEqual(entries.reduce(0) { $0 + $1.totals.totalTokens }, 187)
            XCTAssertEqual(entries[0].timestamp, Date(timeIntervalSince1970: 1793055602))
            XCTAssertEqual(entries[0].model, "Unknown model")
        }
    }

    func testQwenUsesRequestUsageWithCacheAndReasoningAsSubsets() throws {
        try withDirectory { root in
            let file = try write(root, "session.jsonl", """
            {"uuid":"u1","timestamp":"2026-10-26T23:01:00Z","type":"user","usageMetadata":{"promptTokenCount":999,"candidatesTokenCount":999}}
            {"uuid":"a1","timestamp":"2026-10-26T23:02:00.000Z","type":"assistant","model":"qwen3-coder","usageMetadata":{"promptTokenCount":100,"candidatesTokenCount":20,"cachedContentTokenCount":80,"thoughtsTokenCount":7}}
            {"uuid":"a1","timestamp":"2026-10-26T23:02:00.000Z","type":"assistant","model":"qwen3-coder","usageMetadata":{"promptTokenCount":100,"candidatesTokenCount":20,"cachedContentTokenCount":80,"thoughtsTokenCount":7}}
            {"uuid":"a1","timestamp":"2026-10-26T23:02:00.000Z","type":"assistant","model":"qwen3-coder","usageMetadata":{"promptTokenCount":100,"candidatesTokenCount":0}}
            {"uuid":"no-usage","timestamp":"2026-10-26T23:03:00Z","type":"assistant","model":"qwen3-coder"}
            {"uuid":"only-total","timestamp":"2026-10-26T23:04:00Z","type":"assistant","usageMetadata":{"totalTokenCount":999}}
            {"uuid":"bad-time","timestamp":"invalid","type":"assistant","usageMetadata":{"promptTokenCount":1,"candidatesTokenCount":1}}
            invalid JSON
            """)
            let entries = QwenUsageLogReader().readEntries(from: file)
            XCTAssertEqual(entries.count, 1)
            let totals = try XCTUnwrap(entries.first?.totals)
            XCTAssertEqual(totals.totalTokens, 120)
            XCTAssertEqual(totals.billableInputTokens, 20)
            XCTAssertEqual(totals.cachedInputTokens, 80)
            XCTAssertEqual(totals.reasoningOutputTokens, 7)
            XCTAssertFalse(totals.hasCostEstimate)
        }
    }

    func testDiscoveryPreservesEveryAgentWireAndIsolatesProviders() throws {
        try withDirectory { root in
            let kimi = root.appendingPathComponent("kimi")
            let qwen = root.appendingPathComponent("qwen")
            let kimiLine = """
            {"type":"context.append_loop_event","time":1793055600000,"event":{"type":"step.end","uuid":"api-1","usage":{"inputOther":100,"output":20}}}
            """
            try write(kimi, "project/session/agents/main/wire.jsonl", kimiLine)
            try write(kimi, "project/session/agents/child/wire.jsonl", kimiLine)
            try write(kimi, "project/another-session/wire.jsonl", kimiLine)
            try write(kimi, "project/session/context.jsonl", kimiLine)
            try write(qwen, "project/chats/session.jsonl", """
            {"uuid":"api-1","type":"assistant","timestamp":"2026-10-26T23:01:00Z","model":"qwen-test","usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":5}}
            """)
            try write(qwen, "project/other/telemetry.jsonl", "{}")
            let kimiFiles = LocalUsageProvider.kimi.logFileMetadata(roots: [kimi, kimi])
            let qwenFiles = LocalUsageProvider.qwen.logFileMetadata(roots: [qwen])
            XCTAssertEqual(kimiFiles.count, 3)
            XCTAssertEqual(qwenFiles.count, 1)
            let kimiUsage = LocalUsageProvider.kimi.analytics(from: kimiFiles.map { LocalUsageProvider.kimi.usageRecord(for: $0) })
            let qwenRecords = qwenFiles.map { LocalUsageProvider.qwen.usageRecord(for: $0) }
            let restored = try JSONDecoder().decode([CodexFileUsageRecord].self, from: JSONEncoder().encode(qwenRecords))
            let qwenUsage = LocalUsageProvider.qwen.analytics(from: restored)
            XCTAssertEqual(kimiUsage.total.totalTokens, 360)
            XCTAssertEqual(kimiUsage.fileCount, 3)
            XCTAssertEqual(kimiUsage.eventCount, 3)
            XCTAssertEqual(qwenUsage.total.totalTokens, 15)
            XCTAssertEqual(qwenUsage.eventCount, 1)
            XCTAssertFalse(qwenUsage.total.hasCostEstimate)
            XCTAssertTrue(restored[0].matches(qwenFiles[0]))
        }
    }

    func testProviderSnapshotsPreserveExistingHistoryAndKimiQuotas() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let legacy = try decoder.decode(UsageAnalyticsSnapshot.self, from: encoder.encode(UsageAnalyticsSnapshot.empty))
        XCTAssertNil(legacy.kimiUsage)
        XCTAssertNil(legacy.qwen)
        var next = legacy
        next.codex.total.inputTokens = 123
        next.claude = .empty
        next.claude?.total.inputTokens = 456
        next.kimi.windows = [KimiQuotaWindow(id: "weekly", label: "7d", remainingPercent: 75, used: 25, limit: 100, resetAt: nil)]
        next.kimiUsage = LocalUsageProvider.kimi.analytics(from: [])
        next.qwen = LocalUsageProvider.qwen.analytics(from: [])
        let restored = try decoder.decode(UsageAnalyticsSnapshot.self, from: encoder.encode(next))
        XCTAssertEqual(restored, next)
        XCTAssertEqual(restored.codex.total.inputTokens, 123)
        XCTAssertEqual(restored.claude?.total.inputTokens, 456)
        XCTAssertEqual(restored.kimi.windows.first?.remainingPercent, 75)
        XCTAssertEqual(restored.qwen?.eventCount, 0)
        XCTAssertFalse(try XCTUnwrap(restored.kimiUsage).total.hasCostEstimate)
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    @discardableResult
    private func write(_ root: URL, _ path: String, _ content: String) throws -> URL {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: file, atomically: true, encoding: .utf8)
        return file
    }
}
