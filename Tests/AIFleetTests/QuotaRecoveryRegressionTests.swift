import XCTest
@testable import AIFleet

final class QuotaRecoveryRegressionTests: XCTestCase {
    func testAuthOutputLargerThanPipeIsDrainedBeforeExit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let command = root.appendingPathComponent("auth")
        try "#!/bin/sh\n/usr/bin/head -c 1048576 /dev/zero\n".write(to: command, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: command.path)
        let result = try XCTUnwrap(LocalCommandReader.read(executableURL: command, arguments: [], timeout: 3))
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.data.count, 1048576)
    }

    func testClaudeMissingReportedDirectoryUsesExactRequestedProfile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"claudeAiOauth":{"accessToken":"fixture-profile-token","scopes":["user:profile"]}}"#.utf8)
            .write(to: root.appendingPathComponent(".credentials.json"))
        let profile = ClaudeProfile(id: "fixture", name: "Fixture", configDirectory: root.path)
        let snapshot = ClaudeAuthSnapshot(auth: .signedIn, authMethod: "claude.ai")
        XCTAssertEqual(ClaudeQuotaCredential.resolve(snapshot: snapshot, profile: profile).credential?.accessToken, "fixture-profile-token")
    }

    func testOwnedAppServerIgnoringTerminateCannotBlockQuotaRecovery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let command = root.appendingPathComponent("app-server")
        try "#!/bin/sh\ntrap '' TERM\nwhile :; do :; done\n".write(to: command, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: command.path)
        let start = Date()
        XCTAssertThrowsError(try CodexAccountUsageReader(executableURL: command, timeout: 0.2).read()) {
            XCTAssertEqual($0 as? CodexAccountUsageReaderError, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
    }

    func testUnrepresentableQuotaCountsAreUnavailableRatherThanCrashing() throws {
        let value = try JSONDecoder().decode(KimiCodeUsageResponse.self,
            from: Data(#"{"usage":{"limit":1e100,"used":3,"remaining":1e100}}"#.utf8))
        XCTAssertNil(value.usage?.limit)
        XCTAssertNil(value.usage?.remaining)
        XCTAssertEqual(value.usage?.used, 3)
    }
}
