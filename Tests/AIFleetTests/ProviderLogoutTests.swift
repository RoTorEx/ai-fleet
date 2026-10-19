import XCTest
@testable import AIFleet

final class ProviderLogoutTests: XCTestCase {
    private func fixtureHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: home) }
        return home
    }

    private func write(_ text: String, _ path: String, home: URL) throws {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func testClaudeLogoutRemovesBothStoresAndIdentityPreservingSettingsAndHistory() throws {
        let home = try fixtureHome()
        try write("fixture credential", ".claude/.credentials.json", home: home)
        try write(#"{"oauthAccount":{"emailAddress":"test@example.test"},"projects":{"test":true},"theme":"dark"}"#,
                  ".claude.json", home: home)
        try write("history fixture", ".claude/history.jsonl", home: home)
        try write("other login", ".codex/auth.json", home: home)
        var deletedKeychain = false
        let logout = ProviderLogout(home: home, environment: [:], removeClaudeKeychain: { deletedKeychain = true })
        try logout.signOut("claude")
        XCTAssertTrue(deletedKeychain)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude/.credentials.json").path))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: home.appendingPathComponent(".claude.json"))) as? [String: Any])
        XCTAssertNil(json["oauthAccount"])
        XCTAssertEqual(json["theme"] as? String, "dark")
        XCTAssertNotNil(json["projects"])
        XCTAssertEqual(try String(contentsOf: home.appendingPathComponent(".claude/history.jsonl")), "history fixture")
        XCTAssertEqual(try String(contentsOf: home.appendingPathComponent(".codex/auth.json")), "other login")
        try logout.signOut("claude") // Missing credentials are an idempotent success.
    }

    func testAllFileBackedProvidersRemoveEveryMonitoredCredentialButPreserveSessions() throws {
        for provider in ProviderCatalog.all where provider.id != "claude" {
            let home = try fixtureHome()
            for path in provider.credentialPaths { try write("fixture", path, home: home) }
            try write(#"{"active":"test@example.test","old":["other@example.test"]}"#, ".gemini/google_accounts.json", home: home)
            try write(#"{"kimiApiKey":"fixture","otherSetting":true}"#, "Library/Application Support/AI Fleet/config.json", home: home)
            try write("history", ".codex/sessions/session.jsonl", home: home)
            let logout = ProviderLogout(home: home, environment: [:], removeClaudeKeychain: { XCTFail("Wrong provider") })
            try logout.signOut(provider.id)
            for path in provider.credentialPaths {
                XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(path).path))
            }
            if provider.id == "gemini" {
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: home.appendingPathComponent(".gemini/google_accounts.json"))) as? [String: Any])
                XCTAssertNil(json["active"])
                XCTAssertNotNil(json["old"])
            }
            if provider.id == "kimi" {
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: home.appendingPathComponent("Library/Application Support/AI Fleet/config.json"))) as? [String: Any])
                XCTAssertNil(json["kimiApiKey"])
                XCTAssertEqual(json["otherSetting"] as? Bool, true)
            }
            XCTAssertEqual(try String(contentsOf: home.appendingPathComponent(".codex/sessions/session.jsonl")), "history")
        }
    }

    func testFailedKeychainAccessAndMalformedMetadataDoNotDeleteFileCredentials() throws {
        let home = try fixtureHome()
        try write("fixture", ".claude/.credentials.json", home: home)
        let logout = ProviderLogout(home: home, environment: [:], removeClaudeKeychain: { throw ProviderLogout.Failure.keychain })
        XCTAssertThrowsError(try logout.signOut("claude"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude/.credentials.json").path))
        try write("malformed", ".claude.json", home: home)
        let invalid = ProviderLogout(home: home, environment: [:], removeClaudeKeychain: { XCTFail("Must validate first") })
        XCTAssertThrowsError(try invalid.signOut("claude"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude/.credentials.json").path))
    }

    func testRedirectedCredentialsAndEnvironmentKeysAreRejectedWithoutMutation() throws {
        let home = try fixtureHome()
        let outside = try fixtureHome()
        try write("fixture", "auth.json", home: outside)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".codex"), withDestinationURL: outside)
        let logout = ProviderLogout(home: home, environment: ["KIMI_API_KEY": "fixture"], removeClaudeKeychain: {})
        XCTAssertThrowsError(try logout.signOut("codex"))
        XCTAssertEqual(try String(contentsOf: outside.appendingPathComponent("auth.json")), "fixture")
        try write("fixture", ".kimi-code/credentials/kimi-code.json", home: home)
        XCTAssertThrowsError(try logout.signOut("kimi"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent(".kimi-code/credentials/kimi-code.json").path))
    }

    @MainActor
    func testLogoutWaitsForCancelledRefreshAndSuppressesNewRefreshes() async throws {
        let home = try fixtureHome()
        let suite = "logout-refresh-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let accounts = AccountStore(defaults: defaults, homeDirectory: home)
        let started = expectation(description: "Refresh started")
        let gate = LogoutRefreshGate()
        let auth = home.appendingPathComponent(".codex/auth.json")
        try write("before", ".codex/auth.json", home: home)
        let service = StatusService(session: URLSession(configuration: .ephemeral), connectionCheck: { connection in
            if connection.providerID == "codex" {
                started.fulfill()
                await gate.wait()
                // Simulate a renewal that finishes writing despite cancellation.
                try! Data("renewed".utf8).write(to: auth)
            }
            return LocalProviderAuth.signedIn.status(for: ProviderCatalog.definition(for: connection.providerID)!)
        })
        service.refresh()
        await fulfillment(of: [started], timeout: 2)
        service.refresh() // This cancels the original check but must retain its lifetime.
        let finished = Task { await service.signOutGlobally("codex", accounts: accounts,
            logout: ProviderLogout(home: home, environment: [:], removeClaudeKeychain: {})) }
        // Yield until logout owns the refresh gate, without starting any real provider.
        while service.signingOutProvider == nil { await Task.yield() }
        service.refresh()
        XCTAssertTrue(FileManager.default.fileExists(atPath: auth.path))
        await gate.release()
        await finished.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: auth.path))
        XCTAssertEqual(service.codex.authentication, .signInRequired)
        XCTAssertNil(accounts.launchError)
    }

    @MainActor
    func testSignOutUpdatesEveryBadgeWithoutLaunchingProviderAndKeepsOtherQuotas() async throws {
        let home = try fixtureHome()
        let suite = "logout-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let accounts = AccountStore(defaults: defaults, homeDirectory: home)
        let service = StatusService(session: URLSession(configuration: .ephemeral))
        let claude = ProviderStatus(id: "claude", name: "Claude", state: .ok, detail: "Current", lastUpdated: Date(),
                                    remainingPercent: 70, authentication: .signedIn)
        let codex = ProviderStatus(id: "codex", name: "Codex", state: .ok, detail: "Current", lastUpdated: Date(),
                                   remainingPercent: 50, authentication: .signedIn)
        service.applyGlobalStatuses([claude, codex], accounts: accounts)
        var deletes = 0
        let logout = ProviderLogout(home: home, environment: [:], removeClaudeKeychain: { deletes += 1 })
        await service.signOutGlobally("claude", accounts: accounts, logout: logout)
        XCTAssertEqual(deletes, 1)
        XCTAssertEqual(service.claude.authentication, .signInRequired)
        XCTAssertNil(service.claude.remainingPercent)
        XCTAssertNil(service.claude.account)
        XCTAssertEqual(service.codex.remainingPercent, 50)
        XCTAssertTrue(service.subscriptions.filter { $0.providerID == "claude" }.allSatisfy { $0.authentication == .signInRequired && $0.remainingPercent == nil })
        XCTAssertNil(service.signingOutProvider)
        XCTAssertNil(accounts.launchError)
        XCTAssertNil(service.signOutFailedProvider)
        let failure = ProviderLogout(home: home, environment: [:], removeClaudeKeychain: { throw ProviderLogout.Failure.keychain })
        await service.signOutGlobally("claude", accounts: accounts, logout: failure)
        XCTAssertEqual(service.claude.authentication, .unknown)
        XCTAssertNotNil(accounts.launchError)
        XCTAssertNil(service.signingOutProvider)
        XCTAssertEqual(service.signOutFailedProvider, "claude")
        await service.signOutGlobally("claude", accounts: accounts, logout: logout)
        XCTAssertNil(service.signOutFailedProvider)
        XCTAssertNil(accounts.launchError)
        XCTAssertEqual(service.claude.authentication, .signInRequired)
    }
}

private actor LogoutRefreshGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
