import XCTest
@testable import AIFleet

final class LocalProviderAuthTests: XCTestCase {
    func testClaudeUsesExplicitLoginResultAndRejectsFailures() {
        XCTAssertEqual(ClaudeAuthReader.decode(Data(#"{"loggedIn":false,"authMethod":"none"}"#.utf8), exitCode: 1), .signedOut)
        XCTAssertEqual(ClaudeAuthReader.decode(Data(#"{"loggedIn":true,"authMethod":"claude.ai"}"#.utf8), exitCode: 0), .signedIn)
        for data in [Data("{}".utf8), Data("not json".utf8), Data(#"{"loggedIn":"false"}"#.utf8)] {
            XCTAssertEqual(ClaudeAuthReader.decode(data, exitCode: 1), .unknown)
        }
        XCTAssertEqual(ClaudeAuthReader.decode(Data(#"{"loggedIn":false}"#.utf8), exitCode: 2), .unknown)
        XCTAssertEqual(ClaudeAuthReader.decode(Data(#"{"loggedIn":true}"#.utf8), exitCode: 1), .unknown)
    }

    func testClaudeReaderRunsAuthStatusAndBoundsHungCommands() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fake-claude")
        func write(_ body: String) throws {
            try ("#!/bin/sh\n" + body).write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }
        try write("test \"$1 $2\" = 'auth status' || exit 2\nprintf '%s' '{\"loggedIn\":false}'\nexit 1\n")
        XCTAssertEqual(ClaudeAuthReader(executableURL: executable).read(), .signedOut)
        try write("printf '%s' '{\"loggedIn\":true}'\nexit 0\n")
        XCTAssertEqual(ClaudeAuthReader(executableURL: executable).read(), .signedIn)
        try write("trap '' TERM\nexec /bin/sleep 30\n")
        let start = Date()
        XCTAssertEqual(ClaudeAuthReader(executableURL: executable, timeout: 0.1).read(), .unknown)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        XCTAssertEqual(ClaudeAuthReader(executableURL: directory.appendingPathComponent("missing")).read(), .unknown)
    }

    func testQwenSettingsDoNotProveLoginAndExpiredAccessNeedsRefresh() {
        let now = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(QwenAuthReader.decode(Data(#"{"theme":"dark"}"#.utf8), now: now), .signedOut)
        XCTAssertEqual(QwenAuthReader.decode(Data(#"{"access_token":"  "}"#.utf8), now: now), .signedOut)
        XCTAssertEqual(QwenAuthReader.decode(Data(#"{"access_token":"test-token","expiry_date":99000}"#.utf8), now: now), .signedOut)
        XCTAssertEqual(QwenAuthReader.decode(Data(#"{"access_token":"test-token","expiry_date":101000}"#.utf8), now: now), .signedIn)
        XCTAssertEqual(QwenAuthReader.decode(Data(#"{"access_token":"test-token","expiry_date":99000,"refresh_token":"test-refresh"}"#.utf8), now: now), .signedIn)
        XCTAssertEqual(QwenAuthReader.decode(Data("broken json".utf8), now: now), .unknown)
    }

    func testQwenReadsCredentialsRatherThanFilePresence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("oauth_creds.json")
        XCTAssertEqual(QwenAuthReader.read(urls: [url]), .signedOut)
        try "{}".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(QwenAuthReader.read(urls: [url]), .signedOut)
        try "broken".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(QwenAuthReader.read(urls: [url]), .unknown)
        try #"{"refresh_token":"test-refresh"}"#.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(QwenAuthReader.read(urls: [url]), .signedIn)
    }

    func testAuthFailuresCannotLookLikeKnownQuota() {
        for auth in [LocalProviderAuth.signedOut, .unknown, .signedIn] {
            let status = auth.status(for: ProviderCatalog.claude)
            XCTAssertNil(status.remainingPercent)
            XCTAssertTrue(status.limitWindows.isEmpty)
        }
        XCTAssertEqual(LocalProviderAuth.signedOut.status(for: ProviderCatalog.claude).state, .noKey)
        XCTAssertEqual(LocalProviderAuth.unknown.status(for: ProviderCatalog.claude).state, .offline)
    }
}
