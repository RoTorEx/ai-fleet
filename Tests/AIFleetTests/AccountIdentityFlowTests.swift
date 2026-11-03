import Foundation
import XCTest
@testable import AIFleet

final class AccountIdentityFlowTests: XCTestCase {
    @MainActor
    func testNativeImportMatchesIdentityAndRemovalDoesNotImmediatelyReattach() throws {
        let suite = "identity-flow-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AccountStore(defaults: defaults)
        let account = store.add(name: "Test", email: "expected@example.test")
        let status = ProviderStatus(id: "kimi", name: "Kimi", state: .ok, detail: "", lastUpdated: nil,
            account: ProviderAccountIdentity(email: "Expected@example.test", organizationID: nil, organizationName: nil, subscriptionType: nil),
            authentication: .signedIn)
        XCTAssertEqual(store.globalAccount(for: status), account.id)
        XCTAssertNotNil(store.accounts.first { $0.id == account.id }?.connection(for: "kimi"))
        store.detach("kimi", from: account.id)
        XCTAssertNil(store.globalAccount(for: status))
        let restored = AccountStore(defaults: defaults)
        XCTAssertNil(restored.globalAccount(for: status))
        restored.importNative(status)
        XCTAssertEqual(restored.globalAccount(for: status), account.id)
        restored.remove(account.id)
        XCTAssertNil(restored.globalAccount(for: status))
    }

    @MainActor
    func testNativeIdentityCannotBeAssignedToPendingPrivateHomeOrDifferentEmail() throws {
        let suite = "identity-flow-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AccountStore(defaults: defaults)
        let account = store.add(name: "Private", email: "private@example.test")
        store.attach("kimi", to: account.id)
        let status = ProviderStatus(id: "kimi", name: "Kimi", state: .ok, detail: "", lastUpdated: nil,
            account: ProviderAccountIdentity(email: "private@example.test", organizationID: nil, organizationName: nil, subscriptionType: nil), authentication: .signedIn)
        XCTAssertNil(store.globalAccount(for: status))
        XCTAssertEqual(AccountIdentityMatch.assess(expected: account.email, observed: "different@example.test"), .different)
        XCTAssertEqual(AccountIdentityMatch.assess(expected: account.email, observed: nil), .unavailable)
    }

    func testCommandLaunchRechecksClaudeCredentialIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("claude")
        try "#!/bin/sh\nprintf '%s' '{\"email\":\"actual@example.test\"}'\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let correct = ProviderLaunchProfile(providerID: "claude", accountID: UUID().uuidString, email: "actual@example.test", native: false)
        try ProviderIdentityGate.validate(correct, directory: root, executable: executable, environment: [:])
        let wrong = ProviderLaunchProfile(providerID: "claude", accountID: correct.accountID, email: "wrong@example.test", native: false)
        XCTAssertThrowsError(try ProviderIdentityGate.validate(wrong, directory: root, executable: executable, environment: [:]))
    }
}
