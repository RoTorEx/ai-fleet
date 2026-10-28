import Foundation
import XCTest
@testable import AIFleet

final class CodexSessionLaunchTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }

    private func auth(_ email: String) throws -> Data {
        let payload = try JSONSerialization.data(withJSONObject: ["email": email]).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return try JSONSerialization.data(withJSONObject: ["tokens": ["id_token": "header.\(payload).signature",
            "access_token": "fixture", "account_id": email]])
    }

    @MainActor
    func testSelectedAccountPersistsAndIgnoresChangesToSharedLogin() throws {
        let suite = "session-select-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = try root()
        let accounts = AccountStore(defaults: defaults, homeDirectory: root)
        let personal = accounts.add(name: "Personal", email: "personal@example.test")
        let work = accounts.add(name: "Work", email: "work@example.test")
        for a in [personal, work] { accounts.attachGlobal("codex", to: a.id) }
        let store = CodexMonitoringStore(defaults: defaults, root: root)
        let profile = store.ensureProfile(for: personal)
        let directory = try store.directory(for: profile)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try auth(personal.email).write(to: directory.appendingPathComponent("auth.json"))
        store.selectForNewSessions(personal)
        XCTAssertEqual(store.selectedLaunchAccountID, personal.id)
        store.selectForNewSessions(work)
        XCTAssertEqual(store.selectedLaunchAccountID, personal.id, "Missing separate login cannot replace selection")
        XCTAssertNotNil(store.error)
        let global = ProviderStatus(id: "codex", name: "Codex", state: .ok, detail: "Current", lastUpdated: Date(),
            remainingPercent: 100, account: ProviderAccountIdentity(email: work.email, organizationID: "work", organizationName: nil, subscriptionType: "business"))
        let rows = sortedAccountProviderRows(accountProviderRows(accounts: accounts.accounts, providerID: "codex",
            global: global, statusForConnection: { _ in nil }, codex: store))
        XCTAssertEqual(rows.map(\.account.badge), ["α", "β"])
        XCTAssertEqual(rows.filter { $0.isCurrentCLI == true }.map(\.account.id), [personal.id])
        XCTAssertEqual(CodexMonitoringStore(defaults: defaults, root: root).selectedLaunchAccountID, personal.id)
        try auth(work.email).write(to: directory.appendingPathComponent("auth.json"))
        XCTAssertThrowsError(try store.sessionHome(for: personal), "Wrong identity cannot launch under a personal badge")
    }

    @MainActor
    func testSharedSwitchRetainsOnlyHistoricalLimitsAndNeverBorrowsOtherAccountData() throws {
        let suite = "session-snapshot-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let accounts = AccountStore(defaults: defaults)
        let personal = accounts.add(email: "personal@example.test")
        let work = accounts.add(email: "work@example.test")
        for a in [personal, work] { accounts.attachGlobal("codex", to: a.id) }
        func status(_ email: String, remaining: Int) -> ProviderStatus {
            ProviderStatus(id: "codex", name: "Codex", state: .ok, detail: "Measured", lastUpdated: Date(),
                remainingPercent: remaining, limitWindows: [ProviderLimitWindow(id: "week", label: "7d", remainingPercent: remaining, resetAt: nil)],
                account: ProviderAccountIdentity(email: email, organizationID: email, organizationName: nil, subscriptionType: "pro"))
        }
        let store = CodexMonitoringStore(defaults: defaults)
        store.observeSharedLogin(status(personal.email, remaining: 68), accounts: accounts.accounts)
        let switched = status(work.email, remaining: 100)
        store.observeSharedLogin(switched, accounts: accounts.accounts)
        let historical = store.status(for: personal, global: switched, accounts: accounts.accounts)
        XCTAssertEqual(historical.remainingPercent, 68)
        XCTAssertFalse(historical.hasCurrentQuota)
        XCTAssertEqual(historical.quotaState, .stale)
        XCTAssertEqual(historical.authentication, .unknown)
        XCTAssertEqual(historical.detail, "Terminal account changed")
        XCTAssertNil(store.usage(for: personal, global: switched, accounts: accounts.accounts))
        let restored = CodexMonitoringStore(defaults: defaults).status(for: personal, global: switched, accounts: accounts.accounts)
        XCTAssertEqual(restored.remainingPercent, 68)
        accounts.update(personal.id, name: "Changed identity", email: "other@example.test")
        let changed = try XCTUnwrap(accounts.accounts.first { $0.id == personal.id })
        XCTAssertNil(store.status(for: changed, global: switched, accounts: accounts.accounts).remainingPercent)
        store.forgetAccount(personal)
        XCTAssertNil(store.status(for: personal, global: switched, accounts: accounts.accounts).remainingPercent)
    }

    @MainActor
    func testTwoRealShellWrappersKeepTheirHomesWhenSharedCredentialsChangeAndProtectLogout() async throws {
        let root = try root()
        let suite = "session-wrappers-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let accounts = AccountStore(defaults: defaults, homeDirectory: root)
        let store = CodexMonitoringStore(defaults: defaults, root: root)
        let shared = root.appendingPathComponent("shared")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let sharedAuth = shared.appendingPathComponent("auth.json")
        try Data("old global login".utf8).write(to: sharedAuth)
        let project = root.appendingPathComponent("project ' with spaces")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let cli = root.appendingPathComponent("codex-fixture")
        try """
        #!/bin/sh
        test "$1" = '-c' || exit 11
        test "$2" = 'cli_auth_credentials_store="file"' || exit 12
        test "$3" = '--no-daemon' || exit 13
        test "$4" = '-c' || exit 16
        case "$5" in forced_chatgpt_workspace_id=*) ;; *) exit 17 ;; esac
        test -z "${CODEX_SQLITE_HOME+x}" || exit 14
        test -z "${OPENAI_API_KEY+x}" || exit 15
        pwd > "$CODEX_HOME/project"
        printf '%s' "$CODEX_HOME" > "$CODEX_HOME/started"
        while [ ! -f "$CODEX_HOME/finish" ]; do /bin/sleep 0.02; done
        """.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        var sessions: [(Process, URL, URL)] = []
        defer {
            for (process, home, _) in sessions {
                try? Data().write(to: home.appendingPathComponent("finish"))
                process.waitUntilExit()
            }
        }
        var firstProfile: CodexMonitoringProfile?
        for (index, email) in ["personal@example.test", "work@example.test"].enumerated() {
            let account = accounts.add(email: email)
            let profile = store.ensureProfile(for: account)
            if index == 0 { firstProfile = profile }
            let home = try store.directory(for: profile)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try auth(email).write(to: home.appendingPathComponent("auth.json"))
            let file = try CodexSessionLaunch.prepareScript(home: home, executable: cli, project: index == 0 ? project : nil,
                                                           reusable: index == 1)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [file.path]
            process.currentDirectoryURL = project
            process.environment = ["CODEX_HOME": shared.path, "CODEX_SQLITE_HOME": shared.path, "OPENAI_API_KEY": "fixture"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            sessions.append((process, home, file))
            for _ in 0..<200 where !FileManager.default.fileExists(atPath: home.appendingPathComponent("started").path) {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertEqual(try String(contentsOf: home.appendingPathComponent("started")), home.path)
            XCTAssertTrue(try CodexSessionLaunch.hasRunningSessions(home: home))
            let launchedProject = try String(contentsOf: home.appendingPathComponent("project")).trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertEqual(URL(fileURLWithPath: launchedProject).resolvingSymlinksInPath().path, project.resolvingSymlinksInPath().path)
        }
        try Data("new corporate login".utf8).write(to: sharedAuth)
        for (process, home, _) in sessions {
            XCTAssertTrue(process.isRunning)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: home.path).contains("auth.json"))
        }
        store.signOut(try XCTUnwrap(firstProfile))
        XCTAssertTrue(store.error?.contains("running Fleet sessions") == true)
        XCTAssertNil(store.authenticatingID, "Logout must not start while that account has active sessions")
        for (index, session) in sessions.enumerated() {
            let (process, home, file) = session
            try Data().write(to: home.appendingPathComponent("finish"))
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertFalse(try CodexSessionLaunch.hasRunningSessions(home: home))
            XCTAssertEqual(FileManager.default.fileExists(atPath: file.path), index == 1,
                           "Copied launchers remain reusable; one-shot project launchers clean themselves")
            if index == 1 {
                let again = Process()
                again.executableURL = URL(fileURLWithPath: "/bin/zsh")
                again.arguments = [file.path]
                again.currentDirectoryURL = project
                again.standardOutput = FileHandle.nullDevice
                again.standardError = FileHandle.nullDevice
                try again.run()
                again.waitUntilExit()
                XCTAssertEqual(again.terminationStatus, 0)
                XCTAssertFalse(try CodexSessionLaunch.hasRunningSessions(home: home))
            }
        }
        XCTAssertEqual(try String(contentsOf: sharedAuth), "new corporate login")
    }
}
