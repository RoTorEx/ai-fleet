import XCTest
@testable import AIFleet

final class CodexAuthenticationTests: XCTestCase {
    private func fixture(_ script: String) throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("native-cli")
        try ("#!/bin/sh\n" + script).write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (root, executable)
    }

    func testInventoryRecognizesCLIsAndAppServersWithoutReadingArguments() {
        let pids = CodexProcessInventory.parse("""
          31 /opt/homebrew/Caskroom/codex/0.164.0/bin/codex
          42 /Users/test/.codex/packages/app-server-daemon/bin/codex
          52 codex
          60 /Applications/Visual Studio Code.app/Contents/MacOS/Electron
          61 /work/codex-code-mode-host
          62 /work/not-codex
        """)
        XCTAssertEqual(pids, [31, 42, 52])
    }

    func testActiveProcessesAndFailedInventoryNeverLaunchOrMutateLogin() throws {
        let (root, executable) = try fixture("touch \"$FLEET_FIXTURE/started\"\n")
        let auth = root.appendingPathComponent("auth.json")
        try Data("unchanged fixture credentials".utf8).write(to: auth)
        for action in [CodexAuthenticationOperation.Action.login, .logout] {
            XCTAssertThrowsError(try CodexAuthenticationOperation().run(action, executable: executable,
                environment: ["FLEET_FIXTURE": root.path], inventory: { [123, 456] })) { error in
                guard case CodexAuthenticationError.activeProcesses([123, 456]) = error else {
                    return XCTFail("Wrong error: \(error)")
                }
            }
        }
        XCTAssertThrowsError(try CodexAuthenticationOperation().run(.login, executable: executable,
            inventory: { throw CodexAuthenticationError.inventoryUnavailable }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("started").path))
        XCTAssertEqual(try String(contentsOf: auth), "unchanged fixture credentials")
    }

    func testNativeCommandsUnsetOverridesAndKeepHistoryAndOtherCredentials() throws {
        let (root, executable) = try fixture("""
        test -z "${CODEX_HOME+x}" || exit 10
        test -z "${OPENAI_API_KEY+x}" || exit 11
        test -z "${CODEX_API_KEY+x}" || exit 12
        test -z "${CODEX_ACCESS_TOKEN+x}" || exit 13
        printf '%s' "$1" > "$FLEET_FIXTURE/action"
        """)
        let history = root.appendingPathComponent("history.jsonl")
        try Data("retained history".utf8).write(to: history)
        let environment = ["CODEX_HOME": "/wrong/account", "OPENAI_API_KEY": "fixture", "CODEX_API_KEY": "fixture",
                           "CODEX_ACCESS_TOKEN": "fixture", "FLEET_FIXTURE": root.path]
        for action in [CodexAuthenticationOperation.Action.login, .logout] {
            try CodexAuthenticationOperation().run(action, executable: executable, environment: environment, inventory: { [] })
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("action")), action.rawValue)
            XCTAssertEqual(try String(contentsOf: history), "retained history")
        }
    }

    func testStatisticsAndAuthCannotOverlapAndReleaseGateOnFailure() throws {
        try CodexCredentialAccess.perform {
            XCTAssertThrowsError(try CodexAuthenticationOperation().run(.login, inventory: { XCTFail("Must not inspect processes"); return [] }))
            XCTAssertThrowsError(try CodexAccountUsageReader(executableURL: nil).read()) { error in
                guard case CodexAuthenticationError.busy = error else { return XCTFail("Wrong error") }
            }
        }
        XCTAssertThrowsError(try CodexAuthenticationOperation().run(.login, executable: nil, inventory: { [] }))
        XCTAssertNoThrow(try CodexCredentialAccess.perform {})
    }

    func testNativeFailureTimeoutAndCancelDoNotReportSuccessAndAllowRetry() throws {
        let (_, failure) = try fixture("exit 7\n")
        XCTAssertThrowsError(try CodexAuthenticationOperation().run(.login, executable: failure, inventory: { [] }))
        let (_, sleeping) = try fixture("exec /bin/sleep 10\n")
        XCTAssertThrowsError(try CodexAuthenticationOperation().run(.login, executable: sleeping, inventory: { [] }, timeout: 0.05)) { error in
            guard case CodexAuthenticationError.timedOut = error else { return XCTFail("Wrong error") }
        }
        let cancelled = CodexAuthenticationOperation()
        cancelled.cancel()
        XCTAssertThrowsError(try cancelled.run(.login, executable: failure, inventory: { [] })) { error in
            guard case CodexAuthenticationError.cancelled = error else { return XCTFail("Wrong error") }
        }
        XCTAssertNoThrow(try CodexCredentialAccess.perform {})
    }

    @MainActor
    func testSignInStateRefusalAndCancellationReachUserWithoutChangingLogin() async throws {
        let (_, executable) = try fixture("exec /bin/sleep 10\n")
        let suite = "codex-signin-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let accounts = AccountStore(defaults: defaults)
        accounts.startCodexSignIn(executable: executable, inventory: { [123] })
        XCTAssertTrue(accounts.codexSigningIn)
        for _ in 0..<200 where accounts.codexSigningIn { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(accounts.codexSigningIn)
        XCTAssertTrue(accounts.launchError?.contains("PIDs: 123") == true)
        accounts.startCodexSignIn(executable: executable, inventory: { [] })
        // Let the owned child start, then exercise the same cancel action as the UI.
        try await Task.sleep(nanoseconds: 100_000_000)
        accounts.cancelCodexSignIn()
        for _ in 0..<200 where accounts.codexSigningIn { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(accounts.codexSigningIn)
        XCTAssertTrue(accounts.launchError?.contains("cancelled") == true)
        XCTAssertNoThrow(try CodexCredentialAccess.perform {})
    }

    @MainActor
    func testRefusedNativeLogoutPreservesProviderIdentityAndQuota() async throws {
        let suite = "codex-auth-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let accounts = AccountStore(defaults: defaults)
        let service = StatusService(session: URLSession(configuration: .ephemeral))
        let codex = ProviderStatus(id: "codex", name: "Codex", state: .ok, detail: "Current", lastUpdated: Date(),
                                  remainingPercent: 50, authentication: .signedIn)
        service.applyGlobalStatuses([codex], accounts: accounts)
        await service.signOutGlobally("codex", accounts: accounts, logout: ProviderLogout(signOutCodex: {
            throw CodexAuthenticationError.activeProcesses([123])
        }))
        XCTAssertEqual(service.codex.authentication, .signedIn)
        XCTAssertEqual(service.codex.remainingPercent, 50)
        XCTAssertNil(service.signOutFailedProvider)
        XCTAssertTrue(accounts.launchError?.contains("codex resume") == true)
    }
}
