import XCTest
@testable import AIFleet

final class UpdateServiceTests: XCTestCase {
    func testUpdateHTTPFailureKeepsTheActualStageAndStatusCode() throws {
        let response = try XCTUnwrap(HTTPURLResponse(url: URL(string: "https://github.com/RoTorEx/ai-fleet/releases/latest")!,
            statusCode: 403, httpVersion: nil, headerFields: nil))
        XCTAssertThrowsError(try ReleaseUpdater.validate(response, operation: "Update check")) { error in
            XCTAssertTrue(error.localizedDescription.contains("Update check"))
            XCTAssertTrue(error.localizedDescription.contains("403"))
            XCTAssertFalse(error.localizedDescription.lowercased().contains("download"))
        }
    }

    func testPublicLatestReleaseRedirectAvoidsGitHubAPIAndValidatesDestination() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UpdateURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); UpdateURLProtocol.destination = nil }
        UpdateURLProtocol.destination = "https://github.com/RoTorEx/ai-fleet/releases/tag/v1.3.4"
        let release = try await ReleaseUpdater.latestRelease(session: session)
        XCTAssertEqual(release.version, "1.3.4")
        XCTAssertEqual(release.checksum.name, release.archive.name + ".sha256")
        XCTAssertTrue(release.archive.browserDownloadURL.path.contains("/releases/download/v1.3.4/"))
        for destination in ["https://github.com/another/repo/releases/tag/v1.3.4",
                            "https://example.test/RoTorEx/ai-fleet/releases/tag/v1.3.4",
                            "https://github.com/RoTorEx/ai-fleet/releases/tag/not-a-version"] {
            UpdateURLProtocol.destination = destination
            do {
                _ = try await ReleaseUpdater.latestRelease(session: session)
                XCTFail("Untrusted or malformed release destination must be rejected")
            } catch { }
        }
    }
    func testSemanticVersionOrdering() throws {
        XCTAssertLessThan(
            try XCTUnwrap(AppSemanticVersion("1.9.9")),
            try XCTUnwrap(AppSemanticVersion("2.0.0"))
        )
        XCTAssertLessThan(
            try XCTUnwrap(AppSemanticVersion("2.0.0")),
            try XCTUnwrap(AppSemanticVersion("2.1.0"))
        )
        XCTAssertLessThan(
            try XCTUnwrap(AppSemanticVersion("2.1.0")),
            try XCTUnwrap(AppSemanticVersion("2.1.1"))
        )
    }

    func testSemanticVersionRejectsUnsupportedFormats() {
        XCTAssertNil(AppSemanticVersion("v1.2.3"))
        XCTAssertNil(AppSemanticVersion("1.2"))
        XCTAssertNil(AppSemanticVersion("1.2.3-beta.1"))
        XCTAssertNil(AppSemanticVersion("01.2.3"))
        XCTAssertNil(AppSemanticVersion("1.-2.3"))
    }
}

private final class UpdateURLProtocol: URLProtocol {
    static var destination: String?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTAssertEqual(request.url?.absoluteString, "https://github.com/RoTorEx/ai-fleet/releases/latest")
        XCTAssertEqual(request.httpMethod, "HEAD")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let response = HTTPURLResponse(url: URL(string: Self.destination!)!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
