import Foundation
import XCTest
@testable import AIFleet

final class ProviderTerminalLaunchTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }

    func testSwitchForEveryProviderAffectsOnlyNextInvocationAndPreservesExistingProcess() throws {
        let root = try root()
        let bin = root.appendingPathComponent("native-bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let environment = ["PATH": bin.path + ":/usr/bin:/bin"]
        for provider in ProviderTerminalLaunch.providers {
            let selector = ProviderConnection.global(provider).selector
            let executable = bin.appendingPathComponent(provider)
            try "#!/bin/sh\nprintf '%s\\n' \"$\(selector)\"\nIFS= read -r next\nprintf '%s\\n' \"$\(selector)\"\n"
                .write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            let first = ProviderLaunchProfile(providerID: provider, accountID: UUID().uuidString, email: "old@example.test", native: true)
            let next = ProviderLaunchProfile(providerID: provider, accountID: UUID().uuidString, email: "new@example.test", native: false)
            try ProviderTerminalLaunch.choose(first, home: root, application: root, environment: environment)
            let oldPlan = try ProviderTerminalLaunch.plan(provider, arguments: [], home: root, environment: environment)
            let process = Process(), input = Pipe(), output = Pipe()
            process.executableURL = oldPlan.executable; process.environment = oldPlan.environment
            process.standardInput = input; process.standardOutput = output
            try process.run()
            defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
            try ProviderTerminalLaunch.choose(next, home: root, application: root, environment: environment)
            XCTAssertTrue(process.isRunning)
            let nextPlan = try ProviderTerminalLaunch.plan(provider, arguments: [], home: root, environment: environment)
            XCTAssertNotEqual(nextPlan.environment[selector], oldPlan.environment[selector])
            XCTAssertEqual(nextPlan.profile, next)
            try input.fileHandleForWriting.write(contentsOf: Data("continue\n".utf8))
            try input.fileHandleForWriting.close()
            process.waitUntilExit()
            let observed = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
            let oldDirectory = oldPlan.environment[selector] ?? ""
            XCTAssertEqual(observed, oldDirectory + "\n" + oldDirectory + "\n")
            if provider == "claude" {
                XCTAssertNil(oldPlan.environment[selector], "The native Claude Keychain must retain its implicit default selector")
            }
            XCTAssertEqual(process.terminationStatus, 0)
            if provider == "gemini" {
                XCTAssertEqual(nextPlan.directory?.deletingLastPathComponent().path, nextPlan.environment[selector])
            } else { XCTAssertEqual(nextPlan.directory?.path, nextPlan.environment[selector]) }
            let custom = try ProviderTerminalLaunch.plan(provider, arguments: [], home: root,
                environment: environment.merging([selector: "/explicit/profile"]) { _, supplied in supplied })
            XCTAssertNil(custom.profile)
            XCTAssertEqual(custom.environment[selector], "/explicit/profile")
        }
    }

    func testCredentialHomesStaySeparateAndExistingSettingsAreNeverOverwritten() throws {
        let root = try root()
        let native = root.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: native.appendingPathComponent("projects"), withIntermediateDirectories: true)
        try Data("saved conversation".utf8).write(to: native.appendingPathComponent("projects/history"))
        try Data("native credentials".utf8).write(to: native.appendingPathComponent(".credentials.json"))
        let profile = ProviderLaunchProfile(providerID: "claude", accountID: UUID().uuidString, email: "test@example.test", native: false)
        try ProviderTerminalLaunch.prepare(profile, home: root)
        let directory = try ProviderTerminalLaunch.directory(profile, home: root)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("projects/history")), "saved conversation")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".credentials.json").path))
        try Data("independent settings".utf8).write(to: directory.appendingPathComponent("settings.json"))
        try ProviderTerminalLaunch.prepare(profile, home: root)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("settings.json")), "independent settings")
        XCTAssertEqual(try String(contentsOf: native.appendingPathComponent(".credentials.json")), "native credentials")
        try FileManager.default.removeItem(at: directory.appendingPathComponent("projects"))
        try FileManager.default.createSymbolicLink(atPath: directory.appendingPathComponent("projects").path, withDestinationPath: "/unrelated/history")
        XCTAssertThrowsError(try ProviderTerminalLaunch.prepare(profile, home: root))
    }

    @MainActor
    func testDefaultSelectionsPersistIndependentlyAndRemovingOneAccountPreservesOtherDefaults() throws {
        let root = try root(), suite = "provider-switch-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let accounts = AccountStore(defaults: defaults, homeDirectory: root)
        let first = accounts.add(email: "one@example.test"), second = accounts.add(email: "two@example.test")
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for name in ["claude", "kimi"] {
            let file = bin.appendingPathComponent(name)
            try "#!/bin/sh\nexit 0\n".write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
        let store = ProviderLaunchStore(defaults: defaults, home: root)
        let global = LocalProviderAuth.signedOut.status(for: ProviderCatalog.claude)
        store.switchAccount(first, providerID: "claude", global: global, environment: ["PATH": bin.path])
        store.switchAccount(second, providerID: "kimi", global: global, environment: ["PATH": bin.path])
        XCTAssertEqual(store.selected, ["claude": first.id, "kimi": second.id])
        let restored = ProviderLaunchStore(defaults: defaults, home: root)
        XCTAssertEqual(restored.selected, store.selected)
        try restored.forget(first.id)
        XCTAssertEqual(restored.selected, ["kimi": second.id])
        XCTAssertNil(try ProviderTerminalLaunch.read("claude", home: root))
        XCTAssertEqual(try ProviderTerminalLaunch.read("kimi", home: root)?.accountID, second.id)
    }

    func testCredentialRedirectsAndExistingCommandsAreRejectedWithoutReplacingThem() throws {
        let root = try root()
        for (provider, credential) in [("claude", ".credentials.json"), ("kimi", "config.toml"),
                                       ("qwen", "oauth_creds.json"), ("gemini", "oauth_creds.json")] {
            let profile = ProviderLaunchProfile(providerID: provider, accountID: UUID().uuidString,
                                                email: "test@example.test", native: false)
            try ProviderTerminalLaunch.prepare(profile, home: root)
            let directory = try ProviderTerminalLaunch.directory(profile, home: root)
            let target = directory.appendingPathComponent(credential)
            try FileManager.default.createSymbolicLink(atPath: target.path, withDestinationPath: "/unrelated/credentials")
            XCTAssertThrowsError(try ProviderTerminalLaunch.validateCredentialPaths(profile, home: root))
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: target.path), "/unrelated/credentials")
        }
        let bin = root.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let command = bin.appendingPathComponent("kimi-code")
        try Data("existing command".utf8).write(to: command)
        XCTAssertThrowsError(try ProviderTerminalLaunch.installShim("kimi", home: root, application: root))
        XCTAssertEqual(try String(contentsOf: command), "existing command")
        XCTAssertFalse(FileManager.default.fileExists(atPath: bin.appendingPathComponent("kimi").path),
                       "A conflict in an alias must leave every command untouched")
    }

    @MainActor
    func testIndependentProviderLimitsCannotBorrowAnotherAccountsIdentityOrWindows() {
        let service = StatusService(session: URLSession(configuration: .ephemeral))
        let first = ProviderConnection(id: "first", providerID: "claude", configDirectory: "/fixture/first", globalAssociation: true)
        let second = ProviderConnection(id: "second", providerID: "claude", configDirectory: "/fixture/second", globalAssociation: true)
        let measured = ProviderStatus(id: "claude", name: "Claude", state: .ok, detail: "Measured", lastUpdated: Date(),
            remainingPercent: 80, limitWindows: [ProviderLimitWindow(id: "5h", label: "5h", remainingPercent: 80, resetAt: nil)],
            account: ProviderAccountIdentity(email: "first@example.test", organizationID: nil, organizationName: nil, subscriptionType: "team"))
        service.applyScopedStatus(measured, connection: first, expectedEmail: "first@example.test")
        service.applyScopedStatus(measured, connection: second, expectedEmail: "second@example.test")
        XCTAssertEqual(service.subscriptions.first { $0.id == first.statusID }?.remainingPercent, 80)
        let wrong = service.subscriptions.first { $0.id == second.statusID }
        XCTAssertNil(wrong?.remainingPercent)
        XCTAssertTrue(wrong?.limitWindows.isEmpty == true)
        XCTAssertEqual(wrong?.authentication, .unknown)
        let legacy = ProviderConnection.global("claude")
        service.applyScopedStatus(measured, connection: first, expectedEmail: "first@example.test", presentation: legacy)
        XCTAssertEqual(service.subscriptions.first { $0.id == legacy.statusID }?.remainingPercent, 80,
                       "An existing native-default connection keeps its original row identity after independent login")
    }
}
