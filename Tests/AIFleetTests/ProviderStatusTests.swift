import XCTest
@testable import AIFleet

final class ProviderStatusTests: XCTestCase {
    func testExhaustionAndStaleMeasurementsDoNotInvalidateLogin() throws {
        let exhausted = try ClaudeQuota.decode(Data(#"{"five_hour":{"utilization":100}}"#.utf8))
        XCTAssertEqual(exhausted.authentication, .signedIn)
        XCTAssertEqual(exhausted.quotaState, .exhausted)
        XCTAssertTrue(exhausted.hasCurrentQuota)
        let stale = exhausted.withQuotaNotice("Last known · retry later")
        XCTAssertEqual(stale.authentication, .signedIn)
        XCTAssertEqual(stale.quotaState, .stale)
        XCTAssertEqual(stale.remainingPercent, 0)
        XCTAssertFalse(stale.hasCurrentQuota)
        let rejected = exhausted.withAuthentication(.signInRequired)
        XCTAssertEqual(rejected.remainingPercent, 0)
        XCTAssertFalse(rejected.hasCurrentQuota, "Old measurements cannot drive alerts or Lowest after login rejection")
    }

    func testConnectionAndIdentityMappingPreserveIndependentStates() {
        let status = ProviderStatus(id: "claude", name: "Claude", state: .offline,
            detail: "Quota unavailable", lastUpdated: Date(), authentication: .signedIn, quotaState: .unavailable)
        let identity = ProviderAccountIdentity(email: "person@example.test", organizationID: "company",
                                               organizationName: "Company", subscriptionType: "team")
        let profile = ClaudeProfile(id: "work", name: "Work", configDirectory: "/profiles/work")
        let connection = ProviderConnection(id: "work", providerID: "claude", configDirectory: "/profiles/work")
        let result = connection.status(from: profile.status(from: status, account: identity)).withAccount(identity)
        XCTAssertEqual(result.authentication, .signedIn)
        XCTAssertEqual(result.quotaState, .unavailable)
        XCTAssertEqual(result.account, identity)
        XCTAssertFalse(result.hasCurrentQuota)
        XCTAssertEqual(result.authentication.marker, "○")
    }

    func testUnknownLoginAndUnsupportedQuotaRemainDistinct() {
        let unknown = LocalProviderAuth.unknown.status(for: ProviderCatalog.qwen)
        XCTAssertEqual(unknown.authentication, .unknown)
        XCTAssertEqual(unknown.authentication.marker, "?")
        XCTAssertFalse(unknown.authentication.needsAccess)
        let missing = LocalProviderAuth.signedOut.status(for: ProviderCatalog.qwen)
        XCTAssertTrue(missing.authentication.needsAccess)
        XCTAssertEqual(missing.authentication.marker, "×")
        let configured = LocalProviderAuth.signedIn.status(for: ProviderCatalog.qwen)
        XCTAssertEqual(configured.authentication, .signedIn)
        XCTAssertEqual(configured.quotaState, .unsupported)
        XCTAssertFalse(configured.hasCurrentQuota)
    }

    @MainActor
    func testNativeClaudeLoginSurvivesUsageEndpointFailuresExceptCredentialRejection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fake-claude")
        try "#!/bin/sh\n/bin/cat \"$CLAUDE_CONFIG_DIR/auth-fixture.json\"\n"
            .write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try JSONSerialization.data(withJSONObject: ["loggedIn": true, "authMethod": "claude.ai",
            "configDirectory": directory.path, "email": "person@example.test", "subscriptionType": "team"])
            .write(to: directory.appendingPathComponent("auth-fixture.json"))
        try Data(#"{"claudeAiOauth":{"accessToken":"test-token","scopes":["user:profile"]}}"#.utf8)
            .write(to: directory.appendingPathComponent(".credentials.json"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderStateProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let profile = ClaudeProfile(id: "work", name: "Work", configDirectory: directory.path)
        for code in [200, 401, 403, 429, 500, -1] {
            ProviderStateProtocol.code = code
            let result = await StatusService.checkClaudeProfile(profile, executableURL: executable, quotaSession: session)
            XCTAssertEqual(result.authentication, code == 401 ? .signInRequired : .signedIn, "HTTP \(code)")
            XCTAssertEqual(result.quotaState, code == 200 ? .exhausted : (code == 401 ? .unknown : .unavailable))
            XCTAssertEqual(result.hasCurrentQuota, code == 200)
            XCTAssertEqual(result.account?.email, "person@example.test")
        }
    }
}

private final class ProviderStateProtocol: URLProtocol {
    static var code = 200
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if Self.code == -1 {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.code,
            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"five_hour":{"utilization":100}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
