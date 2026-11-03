import Foundation
import XCTest
@testable import AIFleet

final class CodexTerminalLaunchTests: XCTestCase {
    private struct Fixture {
        let home: URL
        let native: URL
        let environment: [String: String]
        let alpha: CodexLaunchSelection
        let beta: CodexLaunchSelection
        var app: URL { home.appendingPathComponent("Applications/AI Fleet.app") }
    }

    private func fixture() throws -> Fixture {
        let home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: home) }
        let alpha = CodexLaunchSelection(accountID: UUID().uuidString, profileID: UUID().uuidString,
                                         email: "alpha@example.test", workspaceID: "alpha", usesStandardHome: false)
        let beta = CodexLaunchSelection(accountID: UUID().uuidString, profileID: UUID().uuidString,
                                        email: "beta@example.test", workspaceID: "beta", usesStandardHome: true)
        let standard = home.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: standard, withIntermediateDirectories: true)
        try Data("model = \"fixture\"\n".utf8).write(to: standard.appendingPathComponent("config.toml"))
        for name in ["sessions", "skills", "plugins", "rules", "thread-writer-locks"] {
            try FileManager.default.createDirectory(at: standard.appendingPathComponent(name), withIntermediateDirectories: true)
            try Data("retained \(name)".utf8).write(to: standard.appendingPathComponent(name + "/retained"))
        }
        try Data("shared history".utf8).write(to: standard.appendingPathComponent("history.jsonl"))
        for selection in [alpha, beta] {
            let directory = try CodexTerminalLaunch.profileDirectory(selection, home: home)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let claims = try JSONSerialization.data(withJSONObject: ["email": selection.email]).base64EncodedString()
            let data = try JSONSerialization.data(withJSONObject: ["tokens": ["access_token": "fixture",
                "account_id": selection.workspaceID, "id_token": "x.\(claims).y"]])
            try data.write(to: directory.appendingPathComponent("auth.json"))
            if selection.usesStandardHome { try data.write(to: standard.appendingPathComponent("auth.json")) }
        }
        let bin = home.appendingPathComponent("native-bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let native = bin.appendingPathComponent("codex")
        try """
        #!/bin/sh
        printf '%s\\n' "$CODEX_HOME"
        IFS= read -r next
        printf '%s\\n' "$CODEX_HOME"
        cat "$CODEX_HOME/auth.json"
        """.write(to: native, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: native.path)
        return Fixture(home: home, native: native, environment: ["PATH": bin.path + ":/usr/bin:/bin"], alpha: alpha, beta: beta)
    }

    func testChoosingNextAccountLeavesRunningProcessAndBothCredentialBundlesUnchanged() throws {
        let f = try fixture()
        let sharedAuth = f.home.appendingPathComponent(".codex/auth.json")
        let betaAuth = try Data(contentsOf: sharedAuth)
        let alphaHome = try CodexTerminalLaunch.profileDirectory(f.alpha, home: f.home)
        let alphaAuth = try Data(contentsOf: alphaHome.appendingPathComponent("auth.json"))
        try CodexTerminalLaunch.choose(f.beta, home: f.home, application: f.app, environment: f.environment)
        let old = try CodexTerminalLaunch.plan(arguments: [], home: f.home, environment: f.environment)
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = old.executable
        process.arguments = old.arguments
        process.environment = old.environment
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        XCTAssertTrue(process.isRunning)

        try CodexTerminalLaunch.choose(f.alpha, home: f.home, application: f.app, environment: f.environment)
        XCTAssertTrue(process.isRunning, "Selecting the next account must never stop an existing process")
        let next = try CodexTerminalLaunch.plan(arguments: ["resume", "retained-session"], home: f.home, environment: f.environment)
        XCTAssertEqual(next.environment["CODEX_HOME"], alphaHome.path)
        XCTAssertEqual(next.environment["CODEX_SQLITE_HOME"], f.home.appendingPathComponent(".codex").path)
        XCTAssertEqual(old.environment["CODEX_HOME"], f.home.appendingPathComponent(".codex").path)
        XCTAssertEqual(try Data(contentsOf: sharedAuth), betaAuth)
        XCTAssertEqual(try Data(contentsOf: alphaHome.appendingPathComponent("auth.json")), alphaAuth)
        try input.fileHandleForWriting.write(contentsOf: Data("continue\n".utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let observed = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)!
        XCTAssertTrue(observed.hasPrefix(old.directory.path + "\n" + old.directory.path + "\n"))
        XCTAssertTrue(observed.hasSuffix(String(data: betaAuth, encoding: .utf8)!))
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(next.arguments.contains("--no-daemon"))
        XCTAssertTrue(next.arguments.contains("forced_chatgpt_workspace_id=\"alpha\""))
    }

    func testSharedHistorySettingsAndSkillsRemainAvailableAndOldProfileAssetsArePreserved() throws {
        let f = try fixture()
        let profile = try CodexTerminalLaunch.profileDirectory(f.alpha, home: f.home)
        let oldSkills = profile.appendingPathComponent("skills")
        try FileManager.default.createDirectory(at: oldSkills, withIntermediateDirectories: true)
        try Data("old profile skill".utf8).write(to: oldSkills.appendingPathComponent("original"))
        try CodexTerminalLaunch.choose(f.alpha, home: f.home, application: f.app, environment: f.environment)
        XCTAssertEqual(try String(contentsOf: profile.appendingPathComponent("history.jsonl")), "shared history")
        XCTAssertEqual(try String(contentsOf: profile.appendingPathComponent("sessions/retained")), "retained sessions")
        XCTAssertEqual(try String(contentsOf: profile.appendingPathComponent(".fleet-before-shared/skills/original")), "old profile skill")
        let config = f.home.appendingPathComponent(".codex/config.toml")
        try "model = \"changed\"\n".write(to: config, atomically: true, encoding: .utf8)
        XCTAssertEqual(try String(contentsOf: profile.appendingPathComponent("config.toml")), "model = \"changed\"\n")
        XCTAssertTrue(CodexTerminalLaunch.isSharedConfig(profile.appendingPathComponent("config.toml"), home: f.home))
        try CodexTerminalLaunch.prepareSharedState(directory: profile, home: f.home)
        XCTAssertEqual(try String(contentsOf: profile.appendingPathComponent(".fleet-before-shared/skills/original")), "old profile skill")
    }

    func testExplicitHomesAndServerCommandsKeepTheirNativeScopeButResumeUsesSelection() throws {
        let f = try fixture()
        try CodexTerminalLaunch.choose(f.alpha, home: f.home, application: f.app, environment: f.environment)
        for args in [["agents"], ["-c", "model=\"fixture\"", "app-server"], ["--remote", "unix:///tmp/test", "resume"], ["--version"]] {
            let plan = try CodexTerminalLaunch.plan(arguments: args, home: f.home, environment: f.environment)
            XCTAssertFalse(plan.routed)
            XCTAssertEqual(plan.arguments, args)
        }
        var custom = f.environment
        custom["CODEX_HOME"] = "/explicit/home"
        let plan = try CodexTerminalLaunch.plan(arguments: [], home: f.home, environment: custom)
        XCTAssertFalse(plan.routed)
        XCTAssertEqual(plan.environment["CODEX_HOME"], "/explicit/home")
        XCTAssertTrue(try CodexTerminalLaunch.plan(arguments: ["-m", "fixture", "resume", "--last"], home: f.home,
                                                  environment: f.environment).routed)
        XCTAssertThrowsError(try CodexTerminalLaunch.plan(arguments: ["-c", "cli_auth_credentials_store=keyring"], home: f.home,
                                                         environment: f.environment))
    }

    func testUnrelatedShimAndRedirectedCredentialsCannotBeReplacedOrSelected() throws {
        let f = try fixture()
        let shim = f.home.appendingPathComponent(".local/bin/codex")
        try FileManager.default.createDirectory(at: shim.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("unrelated executable".utf8).write(to: shim)
        XCTAssertThrowsError(try CodexTerminalLaunch.choose(f.alpha, home: f.home, application: f.app, environment: f.environment))
        XCTAssertEqual(try String(contentsOf: shim), "unrelated executable")
        XCTAssertNil(try CodexTerminalLaunch.readSelection(home: f.home))
        try FileManager.default.removeItem(at: shim)
        let profile = try CodexTerminalLaunch.profileDirectory(f.alpha, home: f.home)
        let auth = profile.appendingPathComponent("auth.json")
        try FileManager.default.moveItem(at: auth, to: profile.appendingPathComponent("retained-auth"))
        try FileManager.default.createSymbolicLink(at: auth, withDestinationURL: profile.appendingPathComponent("retained-auth"))
        XCTAssertThrowsError(try CodexTerminalLaunch.choose(f.alpha, home: f.home, application: f.app, environment: f.environment))
        XCTAssertNil(try CodexTerminalLaunch.readSelection(home: f.home))
    }

    func testSessionMarkerBlocksCredentialChangesWhileSelectionRemainsAllowed() throws {
        let f = try fixture()
        let profile = try CodexTerminalLaunch.profileDirectory(f.alpha, home: f.home)
        _ = try CodexTerminalLaunch.registerSession(directory: profile)
        XCTAssertThrowsError(try CodexCredentialSwitch.checkLegacyConsumers(profile))
        let marker = profile.appendingPathComponent("FleetSessions/terminal-\(getpid()).pid")
        try Data("\(getpid())\nold-process-start\n".utf8).write(to: marker)
        XCTAssertNoThrow(try CodexCredentialSwitch.checkLegacyConsumers(profile), "A reused PID must not block another account's login")
        try CodexTerminalLaunch.choose(f.alpha, home: f.home, application: f.app, environment: f.environment)
        XCTAssertEqual(try CodexTerminalLaunch.readSelection(home: f.home), f.alpha)
    }

    func testWrongWorkspaceAndPartialProfilePreparationPreserveOriginalSelectionAndFiles() throws {
        let f = try fixture()
        try CodexTerminalLaunch.choose(f.beta, home: f.home, application: f.app, environment: f.environment)
        let wrong = CodexLaunchSelection(accountID: f.alpha.accountID, profileID: f.alpha.profileID,
                                         email: f.alpha.email, workspaceID: "another-workspace", usesStandardHome: false)
        XCTAssertThrowsError(try CodexTerminalLaunch.choose(wrong, home: f.home, application: f.app, environment: f.environment))
        let profile = try CodexTerminalLaunch.profileDirectory(f.alpha, home: f.home)
        let config = profile.appendingPathComponent("config.toml")
        try Data("retained original config".utf8).write(to: config)
        try FileManager.default.createSymbolicLink(atPath: profile.appendingPathComponent("skills").path,
                                                   withDestinationPath: "/unrelated/skills")
        XCTAssertThrowsError(try CodexTerminalLaunch.choose(f.alpha, home: f.home, application: f.app, environment: f.environment))
        XCTAssertEqual(try String(contentsOf: config), "retained original config")
        XCTAssertEqual(try CodexTerminalLaunch.readSelection(home: f.home), f.beta)
    }
}
