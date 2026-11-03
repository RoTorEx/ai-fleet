import XCTest
@testable import AIFleet

final class CodexModelAttributionTests: XCTestCase {
    func testStructuredTurnModelsOverridePromptMentionsAndRepeatedUsageIsNotAnotherRequest() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("session.jsonl")
        func event(_ input: Int, cumulative: Int) -> [String: Any] {
            ["type": "event_msg", "timestamp": "2026-11-03T12:00:00Z", "payload": [
                "type": "token_count", "info": ["total_token_usage": ["input_tokens": cumulative],
                    "last_token_usage": ["input_tokens": input, "output_tokens": 10]]]]
        }
        let lines: [[String: Any]] = [
            ["type": "response_item", "payload": ["text": "Examples mention gpt-5.6-sol and gpt-5.5"]],
            ["type": "turn_context", "payload": ["model": "gpt-6.1-sol"]],
            event(100, cumulative: 100), event(100, cumulative: 100),
            ["type": "turn_context", "payload": ["model": "gpt-6.1-terra"]],
            event(200, cumulative: 300)
        ]
        try lines.map { try JSONSerialization.data(withJSONObject: $0) }
            .reduce(into: Data()) { $0.append($1); $0.append(10) }.write(to: file)
        let entries = CodexUsageLogReader().readEntries(from: file)
        XCTAssertEqual(entries.map(\.model), ["gpt-6.1-sol", "gpt-6.1-terra"])
        XCTAssertEqual(entries.map { $0.totals.totalTokens }, [110, 210])
        XCTAssertTrue(entries.allSatisfy { !$0.totals.hasCostEstimate }, "Unverified future rates cannot inherit an old model's price")
        let metadata = CodexLogFile(url: file, modifiedAt: Date(), size: 10)
        var cache = CodexFileUsageRecord(path: file.path, modifiedAt: metadata.modifiedAt, size: 10,
            dailyModels: [], timeZoneIdentifier: TimeZone.autoupdatingCurrent.identifier)
        XCTAssertFalse(cache.matches(metadata, parserRevision: CodexUsageLogReader.parserRevision))
        cache.parserRevision = CodexUsageLogReader.parserRevision
        XCTAssertTrue(cache.matches(metadata, parserRevision: CodexUsageLogReader.parserRevision))
    }
}
