import Foundation
import XCTest
@testable import AIFleet

@MainActor
final class ConnectionIdentityTests: XCTestCase {
    func status(_ email: String, organization: String = "one", signedIn: Bool = true) -> ProviderStatus {
        ProviderStatus(id: "claude", name: "Claude", state: .offline, detail: "Quota unavailable", lastUpdated: Date(),
            account: ProviderAccountIdentity(email: email, organizationID: organization, organizationName: nil, subscriptionType: nil),
            authentication: signedIn ? .signedIn : .unknown)
    }
    func store() throws -> (AccountStore, UserDefaults, String) {
        let name = "connection-identity-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        return (AccountStore(defaults: defaults), defaults, name)
    }
    func testRepeatedImportRemovalRestartAndExplicitReimport() throws {
        let (accounts, defaults, name) = try store()
        defer { defaults.removePersistentDomain(forName: name) }
        let observed = status(" PERSON@example.test ")
        let id = try XCTUnwrap(accounts.globalAccount(for: observed))
        let badge = try XCTUnwrap(accounts.accounts.first { $0.id == id }?.badge)
        XCTAssertEqual(accounts.globalAccount(for: observed), id)
        accounts.detach("claude", from: id)
        XCTAssertNil(accounts.globalAccount(for: observed))
        let restored = AccountStore(defaults: defaults)
        XCTAssertNil(restored.globalAccount(for: observed))
        restored.importNative(observed)
        XCTAssertEqual(restored.globalAccount(for: observed), id)
        XCTAssertEqual(restored.accounts.first { $0.id == id }?.badge, badge)
        XCTAssertNotNil(restored.accounts.first { $0.id == id }?.connection(for: "claude"))
    }
    func testUnknownAndConflictingIdentitiesNeverRebind() throws {
        let (accounts, defaults, name) = try store()
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertNil(accounts.globalAccount(for: status("person@example.test", signedIn: false)))
        let id = try XCTUnwrap(accounts.globalAccount(for: status("person@example.test")))
        XCTAssertNil(accounts.globalAccount(for: status("person@example.test", organization: "another")))
        _ = accounts.add(email: "PERSON@example.test")
        XCTAssertNil(accounts.globalAccount(for: status("person@example.test")))
        XCTAssertEqual(accounts.accounts.first { $0.id == id }?.connection(for: "claude")?.verifiedIdentity?.organizationID, "one")
    }
    func testConnectedEmailCannotRelabelCredentialsAndNewNativeEmailGetsOwnBadge() throws {
        let (accounts, defaults, name) = try store()
        defer { defaults.removePersistentDomain(forName: name) }
        let first = try XCTUnwrap(accounts.globalAccount(for: status("one@example.test")))
        accounts.update(first, name: "Personal", email: "other@example.test")
        XCTAssertEqual(accounts.accounts.first { $0.id == first }?.email, "one@example.test")
        let second = try XCTUnwrap(accounts.globalAccount(for: status("two@example.test")))
        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(accounts.accounts.first { $0.id == first }?.badge, accounts.accounts.first { $0.id == second }?.badge)
    }
    func testCandidateIdentityCommitsOnlyToLiveMatchingAssociation() throws {
        let (accounts, defaults, name) = try store()
        defer { defaults.removePersistentDomain(forName: name) }
        let account = accounts.add(name: "New", email: "")
        accounts.attachGlobal("claude", to: account.id)
        XCTAssertTrue(accounts.confirmIdentity(ConnectionIdentity(email: "ONE@example.test", organizationID: "org"), provider: "claude", accountID: account.id))
        XCTAssertFalse(accounts.confirmIdentity(ConnectionIdentity(email: "two@example.test", organizationID: "org"), provider: "claude", accountID: account.id))
        XCTAssertFalse(accounts.confirmIdentity(ConnectionIdentity(email: "one@example.test", organizationID: "different"), provider: "claude", accountID: account.id))
        XCTAssertFalse(accounts.confirmIdentity(ConnectionIdentity(email: "one@example.test", organizationID: nil), provider: "claude", accountID: account.id))
        accounts.detach("claude", from: account.id)
        XCTAssertFalse(accounts.confirmIdentity(ConnectionIdentity(email: "one@example.test", organizationID: "org"), provider: "claude", accountID: account.id))
    }

    func testQuotaFromAnotherOrganizationIsNotAssignedToVerifiedConnection() {
        let initial = status("one@example.test")
        let identity = ConnectionIdentity(status: initial)
        let connection = ProviderConnection(id: UUID().uuidString, providerID: "claude", configDirectory: "/fixture", verifiedIdentity: identity)
        let service = StatusService(session: URLSession(configuration: .ephemeral))
        let wrong = ProviderStatus(id: "claude", name: "Claude", state: .ok, detail: "Current", lastUpdated: Date(), remainingPercent: 80,
            account: ProviderAccountIdentity(email: "one@example.test", organizationID: "wrong", organizationName: nil, subscriptionType: nil), authentication: .signedIn)
        service.applyScopedStatus(wrong, connection: connection, expectedEmail: "one@example.test")
        let result = try? XCTUnwrap(service.subscriptions.first { $0.id == connection.statusID })
        XCTAssertNotNil(result)
        XCTAssertNil(result?.remainingPercent)
        XCTAssertEqual(result?.authentication, .unknown)
    }

    func testRemovingLegacyNamedDefaultLeavesOnlyHiddenNativeFallback() throws {
        let (accounts, defaults, name) = try store()
        defer { defaults.removePersistentDomain(forName: name) }
        accounts.update(FleetAccount.defaultID, name: "Legacy personal", email: "one@example.test")
        accounts.remove(FleetAccount.defaultID)
        XCTAssertFalse(accounts.visibleAccounts.contains { $0.id == FleetAccount.defaultID })
        XCTAssertNil(accounts.globalAccount(for: status("one@example.test")))
        let restored = AccountStore(defaults: defaults)
        XCTAssertFalse(restored.visibleAccounts.contains { $0.id == FleetAccount.defaultID })
        XCTAssertNil(restored.globalAccount(for: status("one@example.test")))
    }

    func testCandidateClaudeHomeRetainsExactKeychainSelectorWithoutMovingOldHome() throws {
        let home = URL(fileURLWithPath: "/private/tmp")
        let id = UUID().uuidString
        let previous = ProviderLaunchProfile(providerID: "claude", accountID: id, email: "one@example.test", native: false)
        var candidate = previous
        candidate.credentialHomeID = UUID().uuidString
        let old = try ProviderTerminalLaunch.directory(previous, home: home)
        let new = try ProviderTerminalLaunch.directory(candidate, home: home)
        XCTAssertNotEqual(old, new)
        XCTAssertNotEqual(ClaudeProfile(id: id, name: "Claude", configDirectory: old.path).keychainService,
                          ClaudeProfile(id: id, name: "Claude", configDirectory: new.path).keychainService)
        let restored = try JSONDecoder().decode(ProviderLaunchProfile.self, from: JSONEncoder().encode(candidate))
        XCTAssertEqual(try ProviderTerminalLaunch.directory(restored, home: home), new)
    }
}

extension ConnectionIdentityTests {
    func testWrongCodexCandidatePreservesExistingCredentialsAndProfile() async throws {
        let (accounts, defaults, name) = try store()
        defer { defaults.removePersistentDomain(forName: name) }
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let account = accounts.add(email: "expected@example.test")
        accounts.attachGlobal("codex", to: account.id)
        let store = CodexMonitoringStore(defaults: defaults, root: root, loginAccounts: accounts,
            measure: { _ in CodexMonitoringResult(status: self.status("expected@example.test"), usage: nil, usageError: nil) },
            authenticate: { _, _, directory in
                // Successful native process, but a different browser account.
                let payload = try JSONSerialization.data(withJSONObject: ["email": "wrong@example.test"])
                let jwt = "x." + payload.base64EncodedString().replacingOccurrences(of: "=", with: "") + ".x"
                let data = try JSONSerialization.data(withJSONObject: ["tokens": ["access_token": jwt, "id_token": jwt, "account_id": "workspace"]])
                try data.write(to: directory.appendingPathComponent("auth.json"))
            })
        let profile = store.ensureProfile(for: account)
        let original = try store.directory(for: profile)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        let preserved = Data("existing credentials must survive".utf8)
        try preserved.write(to: original.appendingPathComponent("auth.json"))
        store.signIn(profile)
        for _ in 0..<200 where store.authenticatingID != nil || store.refreshing { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNotNil(store.error)
        XCTAssertEqual(store.profile(for: account), profile)
        XCTAssertEqual(try Data(contentsOf: original.appendingPathComponent("auth.json")), preserved)
        XCTAssertEqual(accounts.accounts.first { $0.id == account.id }?.email, "expected@example.test")
    }
}
