import XCTest
@testable import AIFleet

final class AntigravityQuotaTests: XCTestCase {
    func testSignInUsesTheCLIsACPBrowserAuthentication() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("agy")
        let script = #"""
        #!/bin/sh
        set -eu
        test "$#" -eq 1 && test "$1" = acp
        IFS= read -r initialization
        case "$initialization" in *'"method":"initialize"'*) ;; *) exit 1 ;; esac
        printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"authMethods":[{"id":"oauth-personal"}]}}'
        IFS= read -r login
        case "$login" in *'"method":"authenticate"'*) ;; *) exit 2 ;; esac
        case "$login" in *'"methodId":"oauth-personal"'*) ;; *) exit 3 ;; esac
        printf '%s\n' '{"jsonrpc":"2.0","method":"test/notification"}' '{"jsonrpc":"2.0","id":2,"result":{}}'
        """# + "\n"
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        try AntigravityAuthentication().run(executable: executable, timeout: 3)
    }

    private func stored(_ json: String) -> Data {
        Data(("go-keyring-base64:" + Data(json.utf8).base64EncodedString() + "\n").utf8)
    }

    func testKeychainRecordNeedsAnUnexpiredAccessTokenAndARefreshTokenAloneProvesNothing() {
        // The record shape Antigravity CLI 1.5.15 stores; Go writes the expiry with nanoseconds.
        let now = AntigravityLoginSnapshot.date("2026-11-23T13:30:00+01:00")!
        let record = { (expiry: String) in
            #"{"token":{"access_token":"fixture-access","token_type":"Bearer","refresh_token":"fixture-refresh","expiry":"\#(expiry)","expires_in":3599},"auth_method":"consumer","id_token_email":"person@example.test"}"#
        }
        let live = AntigravityLoginSnapshot.decode(stored(record("2026-11-23T14:09:57.123456789+01:00")), now: now)
        XCTAssertEqual(live.auth, .signedIn)
        XCTAssertEqual(live.accessToken, "fixture-access")
        XCTAssertEqual(live.email, "person@example.test")
        let expired = AntigravityLoginSnapshot.decode(stored(record("2026-11-23T12:09:57.5+01:00")), now: now)
        XCTAssertEqual(expired.auth, .unknown, "Only the CLI renews the token")
        XCTAssertTrue(expired.expired)
        XCTAssertNil(expired.accessToken)
        XCTAssertEqual(AntigravityLoginSnapshot.decode(stored(#"{"token":{}}"#), now: now).auth, .signedOut)
        XCTAssertEqual(AntigravityLoginSnapshot.decode(Data("go-keyring-base64:%%%".utf8), now: now).auth, .unknown)
        XCTAssertEqual(AntigravityLoginSnapshot.decode(Data("broken".utf8), now: now).auth, .unknown)
        XCTAssertEqual(AntigravityLoginSnapshot.decode(Data(record("2026-11-23T14:09:57Z").utf8), now: now).auth, .signedIn,
                       "A plain JSON record is read too")
    }

    func testExpiredSignInSaysHowToRenewAndCannotCountAsSignedIn() async {
        let expired = await AntigravityQuota.check { AntigravityLoginSnapshot(auth: .unknown, email: "person@example.test", expired: true) }
        XCTAssertEqual(expired.detail, "Open agy to renew sign-in")
        XCTAssertEqual(expired.authentication, .unknown)
        XCTAssertFalse(expired.hasCurrentQuota)
        let signedOut = await AntigravityQuota.check { AntigravityLoginSnapshot(auth: .signedOut) }
        XCTAssertEqual(signedOut.detail, "Sign in required")
        XCTAssertEqual(signedOut.authentication, .signInRequired)
    }

    func testModelQuotaJoinsThinkingLevelsKeepsZeroAndSkipsModelsWithoutAMeasurement() throws {
        let json = #"""
        {"models":{
          "gemini-3.8-flash-high":{"displayName":"Gemini 3.8 Flash (High)","quotaInfo":{"remainingFraction":0.8,"resetTime":"2026-11-23T18:00:00Z"}},
          "gemini-3.8-flash-low":{"displayName":"Gemini 3.8 Flash (Low)","quotaInfo":{"remainingFraction":0.8,"resetTime":"2026-11-23T18:00:00Z"}},
          "claude-opus-4-6-thinking":{"displayName":"Claude Opus 4.6 (Thinking)","quotaInfo":{"resetTime":"2026-11-24T09:00:00Z"}},
          "claude-sonnet-4-6":{"displayName":"Claude Sonnet 4.6 (Thinking)","quotaInfo":{"remainingFraction":0.35}},
          "gpt-oss-120b-medium":{"displayName":"GPT-OSS 120B (Medium)","quotaInfo":{}},
          "retired":{"displayName":"Retired","disabled":true,"quotaInfo":{"remainingFraction":0.01}},
          "tab-model":{"displayName":"Tab"},
          "broken":{"quotaInfo":{"remainingFraction":7}}
        },"defaultAgentModelId":"gemini-3.8-flash-high"}
        """#
        let status = try AntigravityQuota.decode(Data(json.utf8), account: nil)
        XCTAssertEqual(status.limitWindows.map(\.label),
                       ["Claude Opus 4.6 (Thinking)", "Claude Sonnet 4.6 (Thinking)", "Gemini 3.8 Flash"])
        XCTAssertEqual(status.limitWindows.map(\.remainingPercent), [0, 35, 80],
                       "A quota with a reset time and no fraction is spent: proto3 JSON leaves out a zero")
        XCTAssertEqual(status.remainingPercent, 0)
        XCTAssertEqual(status.windowLabel, "Claude Opus 4.6 (Thinking)")
        XCTAssertEqual(status.state, .limited)
        XCTAssertNotNil(status.limitWindows[2].resetAt)
        XCTAssertNil(status.limitWindows[1].resetAt)
        // Levels of one model that disagree stay separate lines.
        let split = #"{"models":{"a-high":{"displayName":"A (High)","quotaInfo":{"remainingFraction":0.5}},"a-low":{"displayName":"A (Low)","quotaInfo":{"remainingFraction":0.9}}}}"#
        XCTAssertEqual(try AntigravityQuota.decode(Data(split.utf8), account: nil).limitWindows.map(\.label), ["A (High)", "A (Low)"])
        let empty = try AntigravityQuota.decode(Data(#"{"models":{}}"#.utf8), account: nil)
        XCTAssertEqual(empty.detail, "Signed in · no quota data")
        XCTAssertNil(empty.remainingPercent)
    }

    func testQuotaRequestVerifiesEmailReadsPlanAndListsModelsWithoutGeneration() async {
        let session = mockSession()
        AntigravityProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture")
            switch (request.url!.host, request.url!.path) {
            case ("www.googleapis.com", "/oauth2/v2/userinfo"): return (200, #"{"email":"actual@example.test"}"#)
            case ("daily-cloudcode-pa.googleapis.com", "/v1internal:loadCodeAssist"):
                return (200, #"{"cloudaicompanionProject":{"id":"test-project"},"currentTier":{"name":"Antigravity Starter Quota"}}"#)
            case ("daily-cloudcode-pa.googleapis.com", "/v1internal:fetchAvailableModels"):
                let body = request.httpBody ?? request.httpBodyStream.map(Self.readStream)
                XCTAssertEqual(body.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: String] }, ["project": "test-project"])
                return (200, #"{"models":{"m":{"displayName":"Model","quotaInfo":{"remainingFraction":0.6}}}}"#)
            default: XCTFail("Unexpected endpoint \(request.url!)"); return (500, "{}")
            }
        }
        defer { AntigravityProtocol.handler = nil }
        let result = await AntigravityQuota.fetch(token: "fixture", cachedEmail: "stored@example.test", session: session).status
        XCTAssertEqual(result.id, "antigravity")
        XCTAssertEqual(result.remainingPercent, 60)
        XCTAssertEqual(result.account?.email, "actual@example.test")
        XCTAssertEqual(result.account?.planLabel, "Antigravity Starter Quota")
        XCTAssertTrue(result.hasCurrentQuota)
    }

    func testPlanLookupFailureStillListsModelsAndRejectedTokenRequiresSignIn() async {
        let session = mockSession()
        AntigravityProtocol.handler = { request in
            switch request.url!.path {
            case "/oauth2/v2/userinfo": return (200, #"{"email":"actual@example.test"}"#)
            case "/v1internal:loadCodeAssist": return (400, "{}")
            case "/v1internal:fetchAvailableModels":
                let body = request.httpBody ?? request.httpBodyStream.map(Self.readStream)
                XCTAssertEqual(body.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: String] }, [:])
                return (200, #"{"models":{"m":{"quotaInfo":{"remainingFraction":1}}}}"#)
            default: return (500, "{}")
            }
        }
        let listed = await AntigravityQuota.fetch(token: "fixture", session: session).status
        XCTAssertEqual(listed.remainingPercent, 100)
        XCTAssertEqual(listed.windowLabel, "m")
        AntigravityProtocol.handler = { request in
            request.url!.path == "/oauth2/v2/userinfo" ? (200, #"{"email":"actual@example.test"}"#) : (401, "{}")
        }
        defer { AntigravityProtocol.handler = nil }
        let rejected = await AntigravityQuota.fetch(token: "fixture", session: session).status
        XCTAssertEqual(rejected.authentication, .signInRequired)
        XCTAssertNil(rejected.remainingPercent, "A failure never becomes a full quota")
    }

    func testAntigravityIsAProviderWithItsOwnSwitchAndNoLocalSignOut() {
        XCTAssertEqual(ProviderCatalog.definition(for: "antigravity")?.name, "Antigravity")
        XCTAssertEqual(CodexProcessControl.provider(executable: "/opt/homebrew/Caskroom/antigravity-cli/1.5.15/antigravity", script: nil),
                       "antigravity")
        XCTAssertThrowsError(try ProviderLogout().signOut("antigravity"))
        let profile = ProviderConnection(id: "p", providerID: "antigravity", configDirectory: "/accounts/p")
        let command = AccountLaunch.command(connection: profile, executable: URL(fileURLWithPath: "/tool/agy"),
                                            directory: URL(fileURLWithPath: "/home"), login: true)
        XCTAssertFalse(command.contains("/accounts/p"), "There is no home selector to pass a directory through")
    }

    private func mockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AntigravityProtocol.self]
        return URLSession(configuration: config)
    }
    private static func readStream(_ stream: InputStream) -> Data {
        stream.open(); defer { stream.close() }
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&bytes, maxLength: bytes.count)
            if count <= 0 { break }
            data.append(contentsOf: bytes.prefix(count))
        }
        return data
    }
}

private final class AntigravityProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else { return }
        let (code, body) = handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
