import XCTest
@testable import AIFleet

final class KimiQuotaTests: XCTestCase {
    @MainActor
    func testRefreshFailuresKeepTheirActualCauseAndPreserveCredentials() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("credentials")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let auth = folder.appendingPathComponent("kimi-code.json")
        let original = Data(#"{"access_token":"fixture-access","refresh_token":"fixture-refresh","expires_at":1}"#.utf8)
        try original.write(to: auth)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [KimiRefreshProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); KimiRefreshProtocol.reply = nil }
        let service = StatusService(session: session)
        let connection = ProviderConnection(id: "fixture", providerID: "kimi", configDirectory: root.path)
        let cases: [(Int, String, ProviderStatus.QuotaFailure)] = [
            (400, #"{"error":"invalid_grant","error_description":"revoked"}"#, .signInRequired),
            (401, "{}", .signInRequired),
            (403, "{}", .signInRequired),
            (400, #"{"error":"invalid_request"}"#, .unavailable),
            (429, "{}", .rateLimited),
            (503, "{}", .unavailable),
            (200, "not json", .invalidResponse)
        ]
        for (code, body, reason) in cases {
            KimiRefreshProtocol.reply = (code, body)
            let result = await service.checkKimi(connection: connection)
            XCTAssertEqual(result.quotaFailureReason, reason, "HTTP \(code): \(body)")
            XCTAssertFalse(result.hasCurrentQuota)
            if reason == .signInRequired {
                XCTAssertEqual(result.authentication, .signInRequired)
                XCTAssertEqual(MenuConnectionState(status: result).detail, "Sign in required")
                XCTAssertEqual(MenuConnectionState(status: result).marker, "×")
            }
            XCTAssertEqual(try Data(contentsOf: auth), original)
        }
        KimiRefreshProtocol.reply = nil
        let networkFailure = await service.checkKimi(connection: connection)
        XCTAssertEqual(networkFailure.quotaFailureReason, .network)
    }
}

private final class KimiRefreshProtocol: URLProtocol {
    nonisolated(unsafe) static var reply: (Int, String)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let (code, body) = Self.reply else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        XCTAssertEqual(request.url?.absoluteString, "https://auth.kimi.com/api/oauth/token")
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
