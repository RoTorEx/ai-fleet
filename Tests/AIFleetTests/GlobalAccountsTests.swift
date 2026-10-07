import XCTest
@testable import AIFleet

final class GlobalAccountsTests: XCTestCase {
    @MainActor
    func testObservedGlobalLoginReplacesManualSelectionWithoutLeakingQuota() throws {
        let suite = "global-accounts-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AccountStore(defaults: defaults)
        store.update(FleetAccount.defaultID, name: "Personal", email: "personal@example.test")
        let work = store.add(name: "Work", email: "work@example.test")
        store.attachGlobal("codex", to: work.id)
        let service = StatusService(session: URLSession(configuration: .ephemeral))
        func status(_ email: String, _ remaining: Int) -> ProviderStatus {
            ProviderStatus(id: "codex", name: "Codex", state: .ok, detail: "Current", lastUpdated: Date(),
                remainingPercent: remaining, account: ProviderAccountIdentity(email: email, organizationID: "org",
                    organizationName: nil, subscriptionType: "business"), authentication: .signedIn)
        }
        // A historical manual choice cannot override the native login.
        store.select(work.id, for: "codex")
        service.applyGlobalStatuses([status("PERSONAL@example.test", 82)], accounts: store)
        XCTAssertEqual(service.globalAccountIDs["codex"], FleetAccount.defaultID)
        let workConnection = try XCTUnwrap(store.accounts.first { $0.id == work.id }?.connection(for: "codex"))
        let inactive = try XCTUnwrap(service.subscriptions.first { $0.id == workConnection.statusID })
        XCTAssertNil(inactive.remainingPercent)
        XCTAssertNil(inactive.account)
        XCTAssertEqual(inactive.authentication, .signInRequired)
        service.applyGlobalStatuses([status("work@example.test", 64)], accounts: store)
        XCTAssertEqual(service.globalAccountIDs["codex"], work.id)
        XCTAssertEqual(service.subscriptions.first { $0.id == workConnection.statusID }?.remainingPercent, 64)
        XCTAssertNil(service.subscriptions.first { $0.id == "codex" }?.remainingPercent)
        let restarted = AccountStore(defaults: defaults)
        XCTAssertEqual(restarted.accounts.first { $0.id == work.id }?.connection(for: "codex"), workConnection)
        XCTAssertTrue(workConnection.globalAssociation == true)
        XCTAssertNil(workConnection.configDirectory)
        XCTAssertEqual(restarted.accounts.flatMap(\.connections).filter { $0.providerID == "codex" && $0.isNativeDefault }.count, 1)
        restarted.detach("codex", from: work.id)
        XCTAssertNil(restarted.accounts.first { $0.id == work.id }?.connection(for: "codex"))
    }

    @MainActor
    func testNewNativeIdentityIsDiscoveredButDuplicateLabelsAreNotGuessed() throws {
        let suite = "global-discovery-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AccountStore(defaults: defaults)
        let status = ProviderStatus(id: "claude", name: "Claude", state: .ok, detail: "Signed in", lastUpdated: Date(),
            account: ProviderAccountIdentity(email: "new@example.test", organizationID: "team", organizationName: nil,
                subscriptionType: "team"), authentication: .signedIn)
        let owner = try XCTUnwrap(store.globalAccount(for: status))
        XCTAssertEqual(store.accounts.first { $0.id == owner }?.email, "new@example.test")
        XCTAssertEqual(store.globalAccount(for: status), owner)
        XCTAssertEqual(store.accounts.count, 2)
        let duplicate = store.add(email: "new@example.test")
        store.attachGlobal("claude", to: duplicate.id)
        XCTAssertNil(store.globalAccount(for: status), "Same email can represent different subscriptions")
        let service = StatusService(session: URLSession(configuration: .ephemeral))
        service.applyGlobalStatuses([status], accounts: store)
        XCTAssertNil(service.globalAccountIDs["claude"])
        let ambiguous = service.subscriptions.filter { $0.providerID == "claude" && $0.detail == "Global identity ambiguous" }
        XCTAssertEqual(ambiguous.count, 2)
        XCTAssertTrue(ambiguous.allSatisfy { $0.authentication == .unknown && $0.remainingPercent == nil })
    }

    @MainActor
    func testGlobalStatusDoesNotReadOrRemoveLegacyIsolatedFiles() throws {
        let suite = "global-legacy-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let auth = folder.appendingPathComponent("auth.json")
        try Data("legacy fixture".utf8).write(to: auth)
        let store = AccountStore(defaults: defaults)
        let legacy = store.add(email: "work@example.test")
        store.attach("codex", to: legacy.id, configDirectory: folder.path)
        let connection = try XCTUnwrap(store.accounts.first { $0.id == legacy.id }?.connection(for: "codex"))
        let service = StatusService(session: URLSession(configuration: .ephemeral))
        service.applyGlobalStatuses([ProviderStatus(id: "codex", name: "Codex", state: .noKey,
            detail: "Sign in required", lastUpdated: Date())], accounts: store)
        XCTAssertNil(service.subscriptions.first { $0.id == connection.statusID }?.remainingPercent)
        XCTAssertEqual(store.accounts.first { $0.id == legacy.id }?.connection(for: "codex")?.configDirectory, folder.path)
        XCTAssertEqual(try Data(contentsOf: auth), Data("legacy fixture".utf8))
        store.remove(legacy.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: auth.path))
    }

    func testGlobalLoginCommandsUseNativeLocationsAndUnsetInheritedOverrides() {
        for provider in ProviderCatalog.all {
            let connection = ProviderConnection.global(provider.id)
            let command = AccountLaunch.command(connection: connection, executable: URL(fileURLWithPath: "/tool/cli"),
                directory: URL(fileURLWithPath: "/native/home"), login: true)
            XCTAssertTrue(command.contains("-u '\(connection.selector)'"))
            XCTAssertFalse(command.contains("\(connection.selector)="))
            XCTAssertFalse(command.contains("AI Fleet/Accounts"))
            if provider.id == "gemini" {
                XCTAssertTrue(command.hasSuffix("'/tool/cli'"))
                let relogin = AccountLaunch.command(connection: connection, executable: URL(fileURLWithPath: "/tool/cli"),
                    directory: URL(fileURLWithPath: "/native/home"), login: true, hasGeminiLogin: true)
                XCTAssertTrue(relogin.hasSuffix(" --prompt-interactive '/auth login'"))
                continue
            }
            XCTAssertTrue(command.hasSuffix(provider.id == "claude" ? "' auth login" : provider.id == "qwen" ? "'/tool/cli'" : "' login"))
        }
    }
}
