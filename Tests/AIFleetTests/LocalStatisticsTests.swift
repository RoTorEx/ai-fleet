import Foundation
import XCTest
@testable import AIFleet

final class LocalStatisticsTests: XCTestCase {
    func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }
    func testStructuredModelsCounterResetAndPromptMentions() throws {
        let file = try root().appendingPathComponent("log.jsonl")
        let lines: [[String: Any]] = [
            ["type":"session_meta", "payload":["base_instructions":"gpt-5.6-sol"]],
            ["type":"turn_context", "payload":["model":"gpt-6.1-sol"]],
            event(model: nil, cumulative: 100), event(model: nil, cumulative: 100),
            event(model: "unknown-future", cumulative: 200), event(model: nil, cumulative: 100)
        ]
        try lines.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        let entries = CodexUsageLogReader().readEntries(from: file)
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries.map(\.model), ["gpt-6.1-sol", "unknown-future", "gpt-6.1-sol"])
        XCTAssertTrue(entries[0].totals.hasCostEstimate)
        XCTAssertFalse(entries[1].totals.hasCostEstimate)
    }
    func event(model: String?, cumulative: Int) -> [String: Any] {
        var info: [String: Any] = ["last_token_usage":["input_tokens":80,"output_tokens":20],"total_token_usage":["total_tokens":cumulative]]
        if let model { info["model"] = model }
        return ["timestamp":"2026-11-06T12:00:00Z","type":"event_msg","payload":["type":"token_count","info":info]]
    }
    func testOneSelectionDrivesModelsDaysCoverageAndNeverRemoteLifetime() {
        let now = Date(timeIntervalSince1970: 1793966400)
        let known = UsageTotals(inputTokens: 80, cachedInputTokens: 0, cacheWriteInputTokens: 0, outputTokens: 20, reasoningOutputTokens: 0, estimatedCostUSD: 2)
        var unknown = known; unknown.estimatedCostUSD = 0; unknown.costEstimateAvailable = false
        var snapshot = UsageAnalyticsSnapshot.empty
        snapshot.statisticsRevision = 4
        snapshot.codex.dailyModels = [DailyModelUsage(day: now, model: "same-name", totals: known, events: 1)]
        var other = CodexUsageAnalytics.empty
        other.dailyModels = [DailyModelUsage(day: now, model: "same-name", totals: unknown, events: 1)]
        snapshot.qwen = other
        snapshot.codex.accountUsage = CodexAccountUsage(lifetimeTokens: 99_000, peakDailyTokens: nil, longestRunningTurnSeconds: nil, currentStreakDays: nil, longestStreakDays: nil, daily: [], fetchedAt: now)
        let selected = LocalStatistics(snapshot: snapshot, now: now)
        XCTAssertEqual(selected.totals.totalTokens, 200)
        XCTAssertEqual(selected.models.count, 2)
        XCTAssertEqual(selected.daily.reduce(0) { $0 + $1.totals.totalTokens }, 200)
        XCTAssertNil(selected.cost.fullEstimateUSD)
        XCTAssertEqual(selected.cost.knownEstimateUSD, 2)
        XCTAssertEqual(selected.cost.coverage, 0.5)
        let single = LocalStatistics(snapshot: snapshot, providers: [.codex], now: now)
        XCTAssertEqual(single.cost.fullEstimateUSD, 2)
        let empty = LocalStatistics(snapshot: snapshot, providers: [], now: now)
        XCTAssertTrue(empty.emptySelection)
        XCTAssertNil(empty.cost.coverage)
        XCTAssertEqual(empty.totals.totalTokens, 0)
    }
    func testIndependentBasenamesAndConflictingLogicalCopies() throws {
        let root = try root(), a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        let first = a.appendingPathComponent("same.jsonl"), second = b.appendingPathComponent("same.jsonl")
        try "{}".write(to: first, atomically: true, encoding: .utf8)
        try "{}".write(to: second, atomically: true, encoding: .utf8)
        XCTAssertEqual(CodexUsageLogReader().codexLogFileMetadata(roots: [a,b]).count, 2)
        let header = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"00000000-0000-0000-0000-000000000001\"}}\n"
        try (header + "different one\n").write(to: first, atomically: true, encoding: .utf8)
        try (header + "different two\n").write(to: second, atomically: true, encoding: .utf8)
        let files = CodexUsageLogReader().codexLogFileMetadata(roots: [a,b])
        XCTAssertEqual(files.count, 2)
        XCTAssertTrue(files.allSatisfy { $0.issue != nil })
    }
    func testRoundedUnitsExactIntegersAndEmptyBookScale() {
        XCTAssertEqual(compactCount(999_995_000), "1.00B")
        XCTAssertEqual(compactCount(999_950), "1.00M")
        XCTAssertEqual(groupedInteger(Int.max), "9 223 372 036 854 775 807")
        XCTAssertTrue(TokenBookScale.comparisons(tokens: 0, metric: .input).isEmpty)
        XCTAssertEqual(TokenBookScale.comparisons(tokens: 100, metric: .input).count, 15)
    }
}

extension LocalStatisticsTests {
    @MainActor
    func testServiceRefreshMigratesWithoutRemoteReadAndRetainsMissingSources() async throws {
        let root = try root(), logs = root.appendingPathComponent("logs"), cache = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let file = logs.appendingPathComponent("accounting.jsonl")
        let header = "{\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-6.1-sol\"}}\n"
        let usage = String(decoding: try JSONSerialization.data(withJSONObject: event(model: nil, cumulative: 100)), as: UTF8.self)
        try (header + usage).write(to: file, atomically: true, encoding: .utf8)
        var legacy = UsageAnalyticsSnapshot.empty
        legacy.codex.total.estimatedCostUSD = 900
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(legacy).write(to: cache.appendingPathComponent("usage-analytics-cache.json"))
        let suite = "statistics-selection-\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let service = UsageAnalyticsService(cacheDirectory: cache, discoverFiles: { CodexUsageLogReader().codexLogFileMetadata(roots: [logs]) }, preferences: preferences)
        XCTAssertFalse(service.snapshot.codex.total.hasCostEstimate)
        let quota = ProviderStatus(id: "kimi", name: "Kimi", state: .offline, detail: "Fixture", lastUpdated: nil)
        service.refresh(kimi: quota)
        for _ in 0..<300 where service.isRefreshing { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(service.isRefreshing)
        XCTAssertEqual(service.snapshot.statisticsRevision, 4)
        XCTAssertEqual(service.snapshot.codex.total.totalTokens, 100)
        XCTAssertNotNil(service.snapshot.legacyLocalHistory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.appendingPathComponent("usage-analytics-files-cache.json").path))
        service.selectedProviders = []
        let restored = UsageAnalyticsService(cacheDirectory: cache, discoverFiles: { [] }, preferences: preferences)
        XCTAssertTrue(restored.selectedProviders.isEmpty)
        XCTAssertTrue(restored.localStatistics().emptySelection)
        try FileManager.default.removeItem(at: file)
        service.refresh(kimi: quota)
        for _ in 0..<300 where service.isRefreshing { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(service.snapshot.sourceIssues?.isEmpty ?? true)
        let data = try Data(contentsOf: cache.appendingPathComponent("usage-analytics-files-cache.json"))
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("accounting.jsonl"))
    }
    func testIncompleteFilesRetainUsableRecordsWithoutClaimingCompleteCost() throws {
        let file = try root().appendingPathComponent("partial.jsonl")
        let event = String(decoding: try JSONSerialization.data(withJSONObject: event(model: "gpt-6.1-sol", cumulative: 100)), as: UTF8.self)
        try (event + "\n{incomplete").write(to: file, atomically: true, encoding: .utf8)
        let metadata = CodexLogFile(url: file, modifiedAt: Date(), size: event.utf8.count)
        let record = CodexUsageLogReader().usageRecord(for: metadata)
        XCTAssertEqual(record.eventCount, 1)
        XCTAssertNotNil(record.sourceIssue)
        XCTAssertFalse(record.excluded == true)
        var snapshot = UsageAnalyticsSnapshot.empty
        snapshot.statisticsRevision = 4
        snapshot.codex = CodexUsageLogReader().analytics(from: [record], fileCount: 1)
        snapshot.sourceIssues = [StatisticsSourceIssue(provider: .codex, message: record.sourceIssue!)]
        let result = LocalStatistics(snapshot: snapshot)
        XCTAssertNil(result.cost.fullEstimateUSD)
        XCTAssertEqual(result.cost.recordedTokens, 100)
        XCTAssertGreaterThan(result.cost.knownEstimateUSD, 0)
        XCTAssertTrue(LocalStatistics(snapshot: snapshot, providers: [.claude]).sourceIssues.isEmpty)
    }
    func testOverflowAndStaleCatalogNeverProduceAFullEstimate() {
        var totals = UsageTotals(inputTokens: Int.max - 1, cachedInputTokens: 0, cacheWriteInputTokens: 0, outputTokens: 0, reasoningOutputTokens: 0, estimatedCostUSD: 1)
        let extra = UsageTotals(inputTokens: 5, cachedInputTokens: 0, cacheWriteInputTokens: 0, outputTokens: 0, reasoningOutputTokens: 0, estimatedCostUSD: 1)
        totals.add(extra)
        XCTAssertTrue(totals.overflowDetected == true)
        XCTAssertFalse(totals.hasCostEstimate)
        var snapshot = UsageAnalyticsSnapshot.empty
        snapshot.codex.dailyModels = [DailyModelUsage(day: Date(), model: "legacy", totals: extra, events: 1)]
        let result = LocalStatistics(snapshot: snapshot)
        XCTAssertTrue(result.stale)
        XCTAssertNil(result.cost.fullEstimateUSD)
        XCTAssertEqual(result.cost.knownEstimateUSD, 0)
        XCTAssertEqual(result.models.first?.totals.estimatedCostUSD, 0)
    }
}

private final class StatisticsDiscoveryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let release = DispatchSemaphore(value: 0)
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    func discover(first: CodexLogFile, second: CodexLogFile) -> [CodexLogFile] {
        lock.lock(); count += 1; let current = count; lock.unlock()
        if current == 1 { _ = release.wait(timeout: .now() + 3); return [first] }
        return [second]
    }
}

extension LocalStatisticsTests {
    @MainActor
    func testLateCancelledDiscoveryCannotOverwriteNewSnapshot() async throws {
        let root = try root()
        let a = root.appendingPathComponent("a.jsonl"), b = root.appendingPathComponent("b.jsonl")
        try String(decoding: JSONSerialization.data(withJSONObject: event(model: "gpt-6.1-sol", cumulative: 100)), as: UTF8.self).write(to: a, atomically: true, encoding: .utf8)
        var large = event(model: "gpt-6.1-sol", cumulative: 300)
        large["payload"] = ["type":"token_count", "info":["last_token_usage":["input_tokens":240,"output_tokens":60]]]
        try String(decoding: JSONSerialization.data(withJSONObject: large), as: UTF8.self).write(to: b, atomically: true, encoding: .utf8)
        let first = CodexLogFile(url: a, modifiedAt: Date(), size: 100), second = CodexLogFile(url: b, modifiedAt: Date(), size: 200)
        let gate = StatisticsDiscoveryGate()
        defer { gate.release.signal() }
        let service = UsageAnalyticsService(cacheDirectory: root.appendingPathComponent("cache"), discoverFiles: { gate.discover(first: first, second: second) })
        let quota = ProviderStatus(id: "kimi", name: "Kimi", state: .offline, detail: "Fixture", lastUpdated: nil)
        service.refresh(kimi: quota)
        for _ in 0..<100 where gate.calls == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(gate.calls, 1)
        service.refresh(kimi: quota)
        for _ in 0..<300 where service.isRefreshing { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(service.snapshot.codex.total.totalTokens, 300)
        gate.release.signal()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(service.snapshot.codex.total.totalTokens, 300)
    }
    func testLocalDaySelectionIncludesDSTTransitionAndRejectsWrongCacheZone() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Warsaw"))
        let formatter = ISO8601DateFormatter()
        let stamps = ["2026-10-24T21:59:59Z", "2026-10-24T22:00:00Z", "2026-10-25T22:59:59Z", "2026-10-25T23:00:00Z"]
        let totals = UsageTotals(inputTokens: 1, cachedInputTokens: 0, cacheWriteInputTokens: 0, outputTokens: 0, reasoningOutputTokens: 0, estimatedCostUSD: 1)
        let entries = try stamps.map { CodexUsageLogEntry(timestamp: try XCTUnwrap(formatter.date(from: $0)), model: "fixture", totals: totals) }
        var snapshot = UsageAnalyticsSnapshot.empty
        snapshot.statisticsRevision = 4; snapshot.timeZoneIdentifier = calendar.timeZone.identifier
        snapshot.codex = CodexUsageLogReader(calendar: calendar).analytics(from: entries, fileCount: 1)
        let now = try XCTUnwrap(formatter.date(from: "2026-10-26T12:00:00Z"))
        XCTAssertEqual(LocalStatistics(snapshot: snapshot, days: 1, now: now, calendar: calendar).totals.totalTokens, 1)
        XCTAssertEqual(LocalStatistics(snapshot: snapshot, days: 2, now: now, calendar: calendar).totals.totalTokens, 3)
        var utc = calendar; utc.timeZone = TimeZone(secondsFromGMT: 0)!
        XCTAssertTrue(LocalStatistics(snapshot: snapshot, now: now, calendar: utc).stale)
    }
    func testParserAndCatalogRevisionsInvalidateUnchangedFiles() {
        let file = CodexLogFile(url: URL(fileURLWithPath: "/fixture/file.jsonl"), modifiedAt: Date(), size: 12)
        var cached = CodexFileUsageRecord(path: file.url.path, modifiedAt: file.modifiedAt, size: file.size, dailyModels: [], timeZoneIdentifier: TimeZone.current.identifier)
        XCTAssertFalse(cached.matches(file, revision: 4))
        cached.parserRevision = 4; cached.rateRevision = CodexAPIRates.revision
        cached.modifiedAtEpoch = file.modifiedAt.timeIntervalSince1970
        XCTAssertTrue(cached.matches(file, revision: 4))
        XCTAssertFalse(cached.matches(CodexLogFile(url: file.url, modifiedAt: file.modifiedAt.addingTimeInterval(0.2), size: file.size), revision: 4))
        cached.rateRevision = "previous-catalog"
        XCTAssertFalse(cached.matches(file, revision: 4))
    }
}

extension LocalStatisticsTests {
    func testVerifiedTokenReportSurvivesUnavailableQuotaWithoutBorrowingIdentity() {
        let account = FleetAccount(id: UUID().uuidString, badgeIndex: 0, name: "Personal", email: "one@example.test", connections: [])
        let connection = ProviderConnection(id: UUID().uuidString, providerID: "codex", configDirectory: "/fixture")
        let status = ProviderStatus(id: "codex", name: "Codex", state: .offline, detail: "Quota unavailable", lastUpdated: Date())
        let usage = CodexAccountUsage(lifetimeTokens: 500, peakDailyTokens: nil, longestRunningTurnSeconds: nil, currentStreakDays: nil, longestStreakDays: nil, daily: [], fetchedAt: Date())
        var measurement = CodexMonitoringResult(status: status, usage: usage, usageError: nil,
            usageIdentity: CodexCredentialSwitch.Identity(email: account.email, accountID: "workspace"))
        let report = StatisticsProviderReport.make(account: account, connection: connection, status: status, measurement: measurement)
        XCTAssertEqual(report?.accountUsage?.lifetimeTokens, 500)
        XCTAssertTrue(report?.limits.isEmpty == true)
        measurement.usageIdentity = CodexCredentialSwitch.Identity(email: "other@example.test", accountID: "workspace")
        XCTAssertNil(StatisticsProviderReport.make(account: account, connection: connection, status: status, measurement: measurement))
        measurement.usageIdentity = nil
        XCTAssertNil(StatisticsProviderReport.make(account: account, connection: connection, status: status, measurement: measurement))
    }
}
