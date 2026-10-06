import XCTest
@testable import AIFleet

final class ClaudeQuotaPollerTests: XCTestCase {
    func testRepeatedMenuRefreshesUseCacheAndCooldownKeepsLastGoodMeasurement() async throws {
        let suite = "claude-poller-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let poller = ClaudeQuotaPoller(defaults: defaults)
        let counts = RequestCount()
        let start = Date(timeIntervalSince1970: 1000)
        let good = try ClaudeQuota.decode(Data(#"{"five_hour":{"utilization":25}}"#.utf8), now: start)
        let first = await poller.status(key: "work", now: start) { await counts.increment(); return ClaudeQuota.Result(status: good) }
        let second = await poller.status(key: "work", now: start.addingTimeInterval(60)) {
            await counts.increment(); return ClaudeQuota.Result(status: ClaudeQuota.unavailable("Should not request"))
        }
        XCTAssertEqual(first, second)
        let rateLimit = ClaudeQuota.Result(status: ClaudeQuota.unavailable("429"), rateLimited: true, retryAt: start.addingTimeInterval(300))
        let paused = await poller.status(key: "work", now: start.addingTimeInterval(300)) { await counts.increment(); return rateLimit }
        XCTAssertEqual(paused.remainingPercent, 75)
        XCTAssertEqual(paused.lastUpdated, start)
        XCTAssertEqual(paused.state, .ok)
        XCTAssertNotNil(paused.quotaNotice)
        let cooldown = await poller.status(key: "work", now: start.addingTimeInterval(301)) {
            await counts.increment(); return ClaudeQuota.Result(status: good)
        }
        XCTAssertEqual(cooldown, paused)
        let count = await counts.value
        XCTAssertEqual(count, 2)
        let recovered = await poller.status(key: "work", now: start.addingTimeInterval(600)) {
            await counts.increment(); return ClaudeQuota.Result(status: good)
        }
        XCTAssertNil(recovered.quotaNotice)
    }

    func testBackoffDoublesSurvivesRestartAndHonorsLongServerDelay() async throws {
        let suite = "claude-poller-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let poller = ClaudeQuotaPoller(defaults: defaults)
        let counts = RequestCount()
        let start = Date(timeIntervalSince1970: 1000)
        let rateLimit = ClaudeQuota.Result(status: ClaudeQuota.unavailable("429"), rateLimited: true)
        let empty = await poller.status(key: "work", now: start) { await counts.increment(); return rateLimit }
        XCTAssertNil(empty.remainingPercent)
        XCTAssertEqual(empty.state, .ok)
        XCTAssertNotNil(empty.quotaNotice)
        let restarted = ClaudeQuotaPoller(defaults: defaults)
        _ = await restarted.status(key: "work", now: start.addingTimeInterval(60)) { await counts.increment(); return rateLimit }
        _ = await restarted.status(key: "work", now: start.addingTimeInterval(300)) { await counts.increment(); return rateLimit }
        _ = await restarted.status(key: "work", now: start.addingTimeInterval(899)) { await counts.increment(); return rateLimit }
        let count = await counts.value
        XCTAssertEqual(count, 2)
        let later = ClaudeQuota.Result(status: ClaudeQuota.unavailable("429"), rateLimited: true,
                                      retryAt: start.addingTimeInterval(10_000))
        _ = await restarted.status(key: "work", now: start.addingTimeInterval(900)) { await counts.increment(); return later }
        _ = await restarted.status(key: "work", now: start.addingTimeInterval(9999)) { await counts.increment(); return rateLimit }
        let delayed = await counts.value
        XCTAssertEqual(delayed, 3)
        // A different subscription is never delayed by this one's cooldown.
        _ = await restarted.status(key: "other", now: start.addingTimeInterval(1000)) { await counts.increment(); return rateLimit }
        let independent = await counts.value
        XCTAssertEqual(independent, 4)
    }

    func testConcurrentAndCancelledRefreshesJoinSingleRequest() async throws {
        let suite = "claude-poller-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let poller = ClaudeQuotaPoller(defaults: defaults)
        let gate = FetchGate()
        let good = try ClaudeQuota.decode(Data(#"{"five_hour":{"utilization":30}}"#.utf8))
        let first = Task { await poller.status(key: "work") { await gate.wait(); return ClaudeQuota.Result(status: good) } }
        await gate.waitUntilStarted()
        first.cancel()
        let second = Task { await poller.status(key: "work") { XCTFail("Duplicate request"); return ClaudeQuota.Result(status: good) } }
        await gate.release()
        let results = await (first.value, second.value)
        XCTAssertEqual(results.0.remainingPercent, 70)
        XCTAssertEqual(results.1, results.0)
    }

    func testAccountOrganizationAndCredentialChangesDoNotReuseCachedQuota() {
        let profile = ClaudeProfile(id: "work", name: "Work", configDirectory: "/work")
        let one = ProviderAccountIdentity(email: "person@example.test", organizationID: "one", organizationName: nil, subscriptionType: "team")
        let two = ProviderAccountIdentity(email: "person@example.test", organizationID: "two", organizationName: nil, subscriptionType: "team")
        let credential = ClaudeQuotaCredential(accessToken: "test-first", expiresAt: nil)
        let key = ClaudeQuotaPoller.key(profile: profile, identity: one, credential: credential)
        XCTAssertNotEqual(key, ClaudeQuotaPoller.key(profile: profile, identity: two, credential: credential))
        XCTAssertNotEqual(key, ClaudeQuotaPoller.key(profile: profile, identity: one, credential: ClaudeQuotaCredential(accessToken: "test-next", expiresAt: nil)))
        XCTAssertFalse(key.contains("test-first"))
        XCTAssertFalse(key.contains("person@example.test"))
    }
}

private actor RequestCount {
    private(set) var value = 0
    func increment() { value += 1 }
}

private actor FetchGate {
    private var request: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation { continuation in
            request = continuation
            observer?.resume()
            observer = nil
        }
    }
    func waitUntilStarted() async {
        if request != nil { return }
        await withCheckedContinuation { observer = $0 }
    }
    func release() {
        request?.resume()
        request = nil
    }
}
