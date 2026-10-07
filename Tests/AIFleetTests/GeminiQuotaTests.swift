import XCTest
@testable import AIFleet

final class GeminiQuotaTests: XCTestCase {
    func testLocalOAuthRequiresTokensAndExpiredAccessDoesNotInventQuota() {
        let now = Date(timeIntervalSince1970: 100)
        let cached = GeminiLoginSnapshot.decode(Data(#"{"refresh_token":"fixture-refresh","access_token":"fixture-access","expiry_date":1}"#.utf8), email: "person@example.test", now: now)
        XCTAssertEqual(cached.auth, .signedIn)
        XCTAssertTrue(cached.expired)
        XCTAssertNil(cached.accessToken)
        XCTAssertEqual(GeminiLoginSnapshot.decode(Data(#"{"access_token":"fixture","expiry_date":1}"#.utf8), email: nil, now: now).auth, .signedOut)
        XCTAssertEqual(GeminiLoginSnapshot.decode(Data(#"{"settings":true}"#.utf8), email: nil, now: now).auth, .signedOut)
        XCTAssertEqual(GeminiLoginSnapshot.decode(Data("broken".utf8), email: nil, now: now).auth, .unknown)
    }

    func testNativeReaderIgnoresOldAccountsAndDistinguishesUnsupportedAuth() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = home.appendingPathComponent(".gemini")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertEqual(GeminiLoginSnapshot.read(home: home).auth, .signedOut)
        try Data(#"{"active":null,"old":["old@example.test"]}"#.utf8).write(to: folder.appendingPathComponent("google_accounts.json"))
        XCTAssertNil(GeminiLoginSnapshot.read(home: home).email)
        try Data(#"{"security":{"auth":{"selectedType":"gemini-api-key"}}}"#.utf8).write(to: folder.appendingPathComponent("settings.json"))
        XCTAssertFalse(GeminiLoginSnapshot.read(home: home).supported)
    }

    func testModelQuotaUsesLowestBucketAndKeepsZeroWhileSkippingInvalidData() throws {
        let data = Data(#"{"buckets":[{"modelId":"gemini-pro","remainingFraction":0.8},{"modelId":"gemini-pro","remainingFraction":0.25,"resetTime":"2026-10-08T00:00:00Z"},{"modelId":"gemini-flash","remainingFraction":0},{"modelId":"invalid","remainingFraction":2},{"modelId":"missing"}]}"#.utf8)
        let status = try GeminiQuota.decode(data, account: nil)
        XCTAssertEqual(status.limitWindows.count, 2)
        XCTAssertEqual(status.remainingPercent, 0)
        XCTAssertEqual(status.authentication, .signedIn)
        XCTAssertEqual(status.quotaState, .exhausted)
        XCTAssertEqual(status.limitWindows.first { $0.id == "gemini-pro" }?.remainingPercent, 25)
        XCTAssertNotNil(status.limitWindows.first { $0.id == "gemini-pro" }?.resetAt)
        let empty = try GeminiQuota.decode(Data(#"{"buckets":[{"modelId":"no-fraction"}]}"#.utf8), account: nil)
        XCTAssertNil(empty.remainingPercent)
        XCTAssertFalse(empty.hasCurrentQuota)
        XCTAssertEqual(empty.authentication, .signedIn)
    }

    func testQuotaRequestVerifiesEmailUsesProjectAndRetrievesPlanWithoutGeneration() async {
        let session = mockSession()
        GeminiProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture")
            switch request.url!.path {
            case "/oauth2/v2/userinfo": return (200, #"{"email":"actual@example.test"}"#, [:])
            case "/v1internal:loadCodeAssist":
                XCTAssertEqual(request.httpMethod, "POST")
                return (200, #"{"cloudaicompanionProject":"test-project","currentTier":{"name":"Free"},"paidTier":{"name":"Google AI Pro"}}"#, [:])
            case "/v1internal:retrieveUserQuota":
                let body = request.httpBody ?? request.httpBodyStream.flatMap(Self.readStream)
                XCTAssertEqual(body.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: String] }, ["project":"test-project"])
                return (200, #"{"buckets":[{"modelId":"gemini-pro","remainingFraction":0.6}]}"#, [:])
            default: XCTFail("Unexpected endpoint"); return (500, "{}", [:])
            }
        }
        defer { GeminiProtocol.handler = nil }
        let result = await GeminiQuota.fetch(token: "fixture", session: session).status
        XCTAssertEqual(result.remainingPercent, 60)
        XCTAssertEqual(result.account?.email, "actual@example.test")
        XCTAssertEqual(result.account?.planLabel, "Google AI Pro")
        XCTAssertEqual(result.account?.organizationID, "test-project")
        XCTAssertTrue(result.hasCurrentQuota)
    }

    func testQuotaFailuresNeverTurnMissingMeasurementsIntoFullQuota() async {
        let session = mockSession()
        defer { GeminiProtocol.handler = nil }
        for code in [401, 403, 429, 500] {
            GeminiProtocol.handler = { request in
                if request.url!.path == "/oauth2/v2/userinfo" { return (200, #"{"email":"actual@example.test"}"#, [:]) }
                return (code, "{}", ["Retry-After":"600"])
            }
            let result = await GeminiQuota.fetch(token: "fixture", session: session)
            XCTAssertNil(result.status.remainingPercent)
            XCTAssertEqual(result.status.authentication, code == 401 ? .signInRequired : .signedIn)
            if code == 429 { XCTAssertNotNil(result.retryAt) }
        }
    }

    func testRequestGateCachesSeparatelyForEachCredentialAndHonorsRetryDeadline() async {
        let poller = GeminiQuotaPoller()
        let calls = CallCounter()
        let now = Date(timeIntervalSince1970: 100)
        let fetch: @Sendable () async -> GeminiQuota.Result = {
            await calls.increment()
            return GeminiQuota.Result(status: GeminiQuota.status("Paused"), retryAt: now.addingTimeInterval(600))
        }
        _ = await poller.status(key: "credential-a", now: now, fetch: fetch)
        _ = await poller.status(key: "credential-a", now: now.addingTimeInterval(400), fetch: fetch)
        _ = await poller.status(key: "credential-b", now: now, fetch: fetch)
        let first = await calls.value
        XCTAssertEqual(first, 2)
        _ = await poller.status(key: "credential-a", now: now.addingTimeInterval(601), fetch: fetch)
        let last = await calls.value
        XCTAssertEqual(last, 3)
    }

    private func mockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GeminiProtocol.self]
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

private actor CallCounter {
    var value = 0
    func increment() { value += 1 }
}
private final class GeminiProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, String, [String:String]))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else { return }
        let (code, body, headers) = handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
