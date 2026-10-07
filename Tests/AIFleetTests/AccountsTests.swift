import XCTest
@testable import AIFleet

final class AccountsTests: XCTestCase {
    @MainActor
    func testSharedBadgesProviderSelectionsAndRemovalPreserveLogins() throws {
        let suite = "ai-fleet-accounts-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let store = AccountStore(defaults: defaults, homeDirectory: home)
        XCTAssertEqual(store.accounts.first?.badge, "α")
        let work = store.add(name: "Work", email: "person@example.test")
        store.attach("claude", to: work.id, configDirectory: home.path)
        store.attach("codex", to: work.id)
        store.select(work.id, for: "claude")
        store.update(work.id, name: "Company", email: "person@example.test")
        let restarted = AccountStore(defaults: defaults, homeDirectory: home)
        let claude = try XCTUnwrap(restarted.selected(for: "claude"))
        XCTAssertEqual(claude.badge, "β")
        XCTAssertEqual(claude.name, "Company")
        XCTAssertEqual(claude.connection(for: "claude")?.configDirectory, home.path)
        XCTAssertEqual(restarted.linkedAccounts(for: "codex").last?.badge, "β")
        XCTAssertEqual(restarted.selected(for: "codex")?.badge, "α")
        let login = home.appendingPathComponent(".credentials.json")
        try "fixture".write(to: login, atomically: true, encoding: .utf8)
        restarted.remove(work.id)
        XCTAssertEqual(restarted.selected(for: "claude")?.id, FleetAccount.defaultID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: login.path))
        XCTAssertEqual(restarted.add().badge, "γ", "Removing β must not reassign its badge to a new account")
    }

    @MainActor
    func testThirdCorporateCodexSelectionKeepsClaudeAndOtherLoginsAcrossRestart() throws {
        let suite = "ai-fleet-third-account-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = AccountStore(defaults: defaults, homeDirectory: home)
        let corporateClaude = store.add(name: "Company A", email: "person@company-a.test")
        let nativeClaude = try XCTUnwrap(store.selected(for: "claude")?.connection(for: "claude"))
        store.move(nativeClaude, to: corporateClaude.id)
        let corporateCodex = store.add(name: "Company B", email: "person@company-b.test")
        store.attach("codex", to: corporateCodex.id)
        let isolated = try XCTUnwrap(store.accounts.first { $0.id == corporateCodex.id }?.connection(for: "codex"))
        XCTAssertEqual(store.selected(for: "codex")?.id, FleetAccount.defaultID, "Adding a connection does not switch before launch or explicit choice")
        store.select(corporateCodex.id, for: "codex")
        let restarted = AccountStore(defaults: defaults, homeDirectory: home)
        XCTAssertEqual(restarted.selected(for: "codex")?.badge, "γ")
        XCTAssertEqual(restarted.selected(for: "claude")?.id, corporateClaude.id)
        XCTAssertEqual(restarted.selected(for: "claude")?.connection(for: "claude"), nativeClaude)
        XCTAssertNotEqual(isolated.credentialURL(home: home), store.accounts.first?.connection(for: "codex")?.credentialURL(home: home))
        let command = AccountLaunch.command(connection: isolated, executable: URL(fileURLWithPath: "/bin/codex"), directory: home, login: false)
        XCTAssertTrue(command.contains(ClaudeProfileLaunch.shellQuote("CODEX_HOME=" + isolated.configDirectory!)))
        restarted.select(FleetAccount.defaultID, for: "codex")
        XCTAssertEqual(restarted.selected(for: "codex")?.badge, "α")
        XCTAssertEqual(restarted.selected(for: "claude")?.id, corporateClaude.id)
        XCTAssertEqual(restarted.linkedAccounts(for: "codex").count, 2)
    }

    @MainActor
    func testMoveKeepsConnectionIdentityAndDefaultRecoveryDoesNotMixProviders() throws {
        let suite = "ai-fleet-accounts-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AccountStore(defaults: defaults)
        let work = store.add(name: "Work")
        let current = try XCTUnwrap(store.accounts.first?.connection(for: "claude"))
        store.move(current, to: work.id)
        store.select(work.id, for: "claude")
        store.attach("claude", to: FleetAccount.defaultID)
        store.remove(work.id)
        XCTAssertEqual(store.accounts.flatMap(\.connections).filter { $0.providerID == "claude" && $0.configDirectory == nil }.count, 1)
        XCTAssertTrue(store.accounts.allSatisfy { Set($0.connections.map(\.providerID)).count == $0.connections.count })
        XCTAssertNotNil(store.selected(for: "claude"))
        let restored = AccountStore(defaults: defaults)
        XCTAssertEqual(restored.accounts, store.accounts)
    }

    @MainActor
    func testMigrationPreservesClaudePathsAndSelectionAndNeverDeletesSource() throws {
        let suite = "ai-fleet-accounts-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = [ClaudeProfile.current, ClaudeProfile(id: "work", name: "Company", configDirectory: "/profiles/company")]
        let data = try JSONEncoder().encode(legacy)
        defaults.set(data, forKey: "claude.profiles")
        defaults.set("work", forKey: "claude.selectedProfile")
        let migrated = AccountStore(defaults: defaults)
        XCTAssertEqual(migrated.selected(for: "claude")?.badge, "β")
        XCTAssertEqual(migrated.selected(for: "claude")?.connection(for: "claude")?.configDirectory, legacy[1].configDirectory)
        XCTAssertEqual(migrated.selected(for: "claude")?.connection(for: "claude")?.id, legacy[1].id)
        XCTAssertEqual(migrated.linkedAccounts(for: "codex").count, 1)
        migrated.update("work", name: "New name", email: "person@example.test")
        XCTAssertEqual(defaults.data(forKey: "claude.profiles"), data)
        XCTAssertEqual(AccountStore(defaults: defaults).selected(for: "claude")?.name, "New name")
    }

    func testEveryProviderLaunchAndCredentialReadUseTheSameSelectedDirectory() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let executable = folder.appendingPathComponent("fake ' cli")
        try "#!/bin/sh\nprintf '%s\\n' \"$CLAUDE_CONFIG_DIR\" \"$CODEX_HOME\" \"$KIMI_CODE_HOME\" \"$QWEN_HOME\" \"$GEMINI_CLI_HOME\" \"$*\"\n"
            .write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        for provider in ProviderCatalog.all {
            let path = "/accounts/a ' $(touch unwanted) `echo bad`/" + provider.id
            let connection = ProviderConnection(id: provider.id, providerID: provider.id, configDirectory: path)
            let command = AccountLaunch.command(connection: connection, executable: executable, directory: folder, login: true)
            let result = try XCTUnwrap(LocalCommandReader.read(executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", command]))
            XCTAssertEqual(result.exitCode, 0)
            XCTAssertTrue(String(decoding: result.data, as: UTF8.self).contains(path))
            if let credential = connection.credentialURL() { XCTAssertTrue(credential.path.hasPrefix(path + "/")) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("unwanted").path))
        }
    }

    func testTooltipUsesProviderIdentityInsteadOfGuessingFromSharedEmail() throws {
        let claims: [String: Any] = ["email": "actual@example.test", "https://api.openai.com/auth": ["chatgpt_plan_type": "plus", "chatgpt_account_id": "workspace"]]
        let payload = try JSONSerialization.data(withJSONObject: claims).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let identity = try XCTUnwrap(CodexProfileIdentity.read(auth: ["tokens": ["id_token": "fixture.\(payload).signature"]], accountID: nil))
        let connection = ProviderConnection(id: "work", providerID: "codex", configDirectory: "/work/codex")
        let account = FleetAccount(id: "work", badgeIndex: 1, name: "Work", email: "label@example.test", connections: [connection])
        let status = ProviderStatus(id: "codex", name: "Codex", state: .ok, detail: "80% left", lastUpdated: nil, account: identity)
        let tooltip = account.tooltip(for: connection, status: status)
        XCTAssertEqual(tooltip, "actual@example.test\nPlus")
        XCTAssertEqual(account.tooltip(for: connection, status: nil), "label@example.test")
        XCTAssertNil(CodexProfileIdentity.read(auth: ["tokens": ["id_token": "bad"]], accountID: nil))
    }

    @MainActor
    func testCodexAndKimiRequestsStayScopedAndRefreshOnlyOriginatingKimiFile() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AccountQuotaProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let service = StatusService(session: session)
        for id in ["a", "b"] {
            let path = folder.appendingPathComponent(id)
            let codex = ProviderConnection(id: id, providerID: "codex", configDirectory: path.path)
            let kimi = ProviderConnection(id: id, providerID: "kimi", configDirectory: path.path)
            try FileManager.default.createDirectory(at: path.appendingPathComponent("credentials"), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["tokens": ["access_token": "test-\(id)", "account_id": "workspace-\(id)"]])
                .write(to: codex.credentialURL()!)
            try JSONSerialization.data(withJSONObject: ["access_token": "expired-\(id)", "refresh_token": "refresh-\(id)", "expires_at": 1])
                .write(to: kimi.credentialURL()!)
            let codexResult = await service.checkCodex(connection: codex)
            let kimiResult = await service.checkKimi(connection: kimi)
            XCTAssertEqual(codexResult.remainingPercent, id == "a" ? 80 : 10)
            XCTAssertEqual(kimiResult.remainingPercent, id == "a" ? 80 : 10)
            let written = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: kimi.credentialURL()!)) as? [String: Any])
            XCTAssertEqual(written["access_token"] as? String, "test-\(id)")
            XCTAssertEqual(written["refresh_token"] as? String, "refresh-\(id)")
            if id == "b" {
                let first = ProviderConnection(id: "a", providerID: "kimi", configDirectory: folder.appendingPathComponent("a").path)
                let unchanged = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: first.credentialURL()!)) as? [String: Any])
                XCTAssertEqual(unchanged["access_token"] as? String, "test-a")
            }
        }
        let empty = ProviderConnection(id: "empty", providerID: "kimi", configDirectory: folder.appendingPathComponent("empty").path)
        let result = await service.checkKimi(connection: empty)
        XCTAssertEqual(result.state, .noKey, "An empty custom connection must not borrow default Kimi credentials or API balance")
    }
}

private final class AccountQuotaProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body: String
        if request.url?.host == "auth.kimi.com" {
            let data = request.httpBody ?? request.httpBodyStream.map { stream in
                stream.open()
                defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 1024)
                let count = stream.read(&bytes, maxLength: bytes.count)
                return count > 0 ? Data(bytes.prefix(count)) : Data()
            } ?? Data()
            let id = String(decoding: data, as: UTF8.self).contains("refresh-b") ? "b" : "a"
            body = "{\"access_token\":\"test-\(id)\",\"expires_in\":3600}"
        } else {
            let id = request.value(forHTTPHeaderField: "Authorization") == "Bearer test-b" ? "b" : "a"
            let used = id == "a" ? 20 : 90
            if request.url?.host == "chatgpt.com" {
                guard request.value(forHTTPHeaderField: "ChatGPT-Account-ID") == "workspace-\(id)" else {
                    client?.urlProtocol(self, didFailWithError: URLError(.userAuthenticationRequired)); return
                }
                body = "{\"rate_limit\":{\"primary_window\":{\"used_percent\":\(used),\"limit_window_seconds\":18000}}}"
            } else {
                body = "{\"usage\":{\"limit\":100,\"used\":\(used)}}"
            }
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
