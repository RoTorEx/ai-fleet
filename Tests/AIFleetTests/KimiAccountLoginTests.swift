import Foundation
import XCTest
@testable import AIFleet

final class KimiAccountLoginTests: XCTestCase {
    func testDeviceIdentityPersistsAndRejectsRedirects() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try ProviderTerminalLaunch.kimiDeviceID(directory: root)
        XCTAssertEqual(try ProviderTerminalLaunch.kimiDeviceID(directory: root), first)
        let file = root.appendingPathComponent("device_id")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(atPath: file.path, withDestinationPath: "/unrelated/device")
        XCTAssertThrowsError(try ProviderTerminalLaunch.kimiDeviceID(directory: root))
    }

    @MainActor
    func testBrowserLoginChecksServerIdentityBeforeReturningCredentials() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KimiLoginURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); KimiLoginURLProtocol.handler = nil }
        var requests = 0
        KimiLoginURLProtocol.handler = { request in
            requests += 1
            switch request.url!.path {
            case "/api/oauth/device_authorization":
                return (200, #"{"device_code":"fixture-device","user_code":"fixture-code","verification_uri_complete":"https://auth.kimi.com/device","interval":1}"#)
            case "/api/oauth/token":
                return (200, #"{"access_token":"fixture-token","refresh_token":"fixture-refresh","expires_in":3600}"#)
            default:
                XCTAssertEqual(request.url!.host, "api.kimi.com")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
                return (200, #"{"user_id":"fixture-user","email":"expected@example.test"}"#)
            }
        }
        var authorized = false
        let token = try await KimiAccountLogin.authenticate(expectedEmail: "Expected@example.test", session: session, headers: [:],
            authorize: { _, _ in authorized = true }, sleep: { _ in })
        XCTAssertTrue(authorized)
        XCTAssertNotNil(token.accessToken)
        XCTAssertEqual(requests, 3)
        do {
            _ = try await KimiAccountLogin.authenticate(expectedEmail: "wrong@example.test", session: session, headers: [:],
                authorize: { _, _ in }, sleep: { _ in })
            XCTFail("A different identity must not return credentials")
        } catch { XCTAssertTrue(error is KimiAccountLogin.Failure) }
    }

    @MainActor
    func testUntrustedAuthorizationUrlCannotOpenBrowser() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KimiLoginURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); KimiLoginURLProtocol.handler = nil }
        KimiLoginURLProtocol.handler = { _ in
            (200, #"{"device_code":"fixture","user_code":"fixture","verification_uri_complete":"https://untrusted.example.test/device"}"#)
        }
        do {
            _ = try await KimiAccountLogin.authenticate(expectedEmail: "expected@example.test", session: session, headers: [:],
                authorize: { _, _ in XCTFail("Unexpected browser navigation") }, sleep: { _ in })
            XCTFail("An unrelated host must be refused")
        } catch { XCTAssertTrue(error is KimiAccountLogin.Failure) }
    }
}

private final class KimiLoginURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let result = Self.handler?(request) else { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: result.0, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(result.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
