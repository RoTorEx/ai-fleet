import XCTest
@testable import AIFleet

final class ClaudeQuotaTests: XCTestCase {
    func testMainWindowsShowRemainingQuotaAndFractionalResetTimes() throws {
        let status = try ClaudeQuota.decode(Data(#"{"five_hour":{"utilization":24.5,"resets_at":"2026-10-06T19:39:59.920314+00:00"},"seven_day":{"utilization":90,"resets_at":"2026-10-08T14:59:59Z"},"seven_day_sonnet":{"utilization":99}}"#.utf8))
        XCTAssertEqual(status.limitWindows.map(\.remainingPercent), [76, 10])
        XCTAssertEqual(status.limitWindows.map(\.label), ["5h", "7d"])
        XCTAssertNotNil(status.limitWindows[0].resetAt)
        XCTAssertNotNil(status.limitWindows[1].resetAt)
        XCTAssertEqual(status.remainingPercent, 10)
        XCTAssertEqual(status.windowLabel, "7d")
        XCTAssertEqual(status.state, .limited)
    }

    func testMissingAndInvalidWindowsNeverBecomeFullQuota() throws {
        let weekly = try ClaudeQuota.decode(Data(#"{"five_hour":null,"seven_day":{"utilization":12.0}}"#.utf8))
        XCTAssertEqual(weekly.limitWindows.map(\.label), ["7d"])
        XCTAssertEqual(weekly.remainingPercent, 88)
        for json in ["{}", #"{"five_hour":{"utilization":null}}"#,
                     #"{"five_hour":{"utilization":-1},"seven_day":{"utilization":101}}"#] {
            let status = try ClaudeQuota.decode(Data(json.utf8))
            XCTAssertNil(status.remainingPercent)
            XCTAssertTrue(status.limitWindows.isEmpty)
        }
        XCTAssertThrowsError(try ClaudeQuota.decode(Data("broken".utf8)))
    }

    func testOAuthRequiresRealTokenAndUsableUsageScope() {
        let now = Date(timeIntervalSince1970: 100)
        for json in ["{}", #"{"mcpOAuth":{}}"#,
                     #"{"claudeAiOauth":{"accessToken":" "}}"#,
                     #"{"claudeAiOauth":{"accessToken":"test-token","expiresAt":99000}}"#,
                     #"{"claudeAiOauth":{"accessToken":"test-token","scopes":["user:inference"]}}"#] {
            XCTAssertNil(ClaudeQuotaCredential.decode(Data(json.utf8), now: now))
        }
        XCTAssertNotNil(ClaudeQuotaCredential.decode(Data(#"{"claudeAiOauth":{"accessToken":"test-token","expiresAt":101000,"scopes":["user:profile"]}}"#.utf8), now: now))
    }

    func testActiveProfileAndAuthMethodPreventDefaultAccountFallback() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = ClaudeAuthSnapshot(auth: .signedIn, authMethod: "claude.ai", configDirectory: directory.path)
        XCTAssertNil(ClaudeQuotaCredential.read(snapshot: snapshot))
        let file = directory.appendingPathComponent(".credentials.json")
        try #"{"claudeAiOauth":{"accessToken":"test-token","scopes":["user:profile"]}}"#
            .write(to: file, atomically: true, encoding: .utf8)
        XCTAssertNotNil(ClaudeQuotaCredential.read(snapshot: snapshot))
        XCTAssertNil(ClaudeQuotaCredential.read(snapshot: ClaudeAuthSnapshot(auth: .signedOut,
                         authMethod: "none", configDirectory: directory.path)))
        XCTAssertNil(ClaudeQuotaCredential.read(snapshot: ClaudeAuthSnapshot(auth: .signedIn,
                         authMethod: "api_key", configDirectory: directory.path)))
        let decoded = ClaudeAuthReader.decodeSnapshot(Data(#"{"loggedIn":true,"authMethod":"claude.ai","configDirectory":"/custom/profile"}"#.utf8), exitCode: 0)
        XCTAssertEqual(decoded.configDirectory, "/custom/profile")
        XCTAssertEqual(decoded.authMethod, "claude.ai")
    }

    func testQuotaRequestAndFailureStates() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClaudeQuotaURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); ClaudeQuotaURLProtocol.handler = nil }
        let credential = ClaudeQuotaCredential(accessToken: "test-token", expiresAt: nil)
        ClaudeQuotaURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/api/oauth/usage")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            XCTAssertNil(request.httpBody)
            return (200, Data(#"{"five_hour":{"utilization":0},"seven_day":{"utilization":15}}"#.utf8))
        }
        let success = await ClaudeQuota.fetch(credential: credential, session: session)
        XCTAssertEqual(success.remainingPercent, 85)
        XCTAssertEqual(success.state, .ok)
        for (code, expected) in [(401, ProviderStatus.State.noKey), (403, .offline), (429, .ok), (500, .offline)] {
            ClaudeQuotaURLProtocol.handler = { _ in (code, Data()) }
            let status = await ClaudeQuota.fetch(credential: credential, session: session)
            XCTAssertEqual(status.state, expected)
            XCTAssertNil(status.remainingPercent)
        }
        ClaudeQuotaURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        let offline = await ClaudeQuota.fetch(credential: credential, session: session)
        XCTAssertEqual(offline.state, .offline)
        XCTAssertNil(offline.remainingPercent)
    }

    func testRetryAfterAcceptsDelayOrHTTPDateAndRejectsInvalidValues() throws {
        let now = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(ClaudeQuota.retryDate("600", now: now), now.addingTimeInterval(600))
        XCTAssertEqual(ClaudeQuota.retryDate("0", now: now), now)
        XCTAssertEqual(ClaudeQuota.retryDate("Tue, 06 Oct 2026 16:00:00 GMT", now: now), Date(timeIntervalSince1970: 1791302400))
        for value in ["bad", "-1", "nan", "inf"] { XCTAssertNil(ClaudeQuota.retryDate(value, now: now)) }
    }
}

private final class ClaudeQuotaURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (code, data) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
