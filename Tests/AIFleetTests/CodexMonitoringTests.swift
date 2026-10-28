import AppKit
import SwiftUI
import XCTest
@testable import AIFleet

final class CodexMonitoringTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }

    private func executable(root: URL, script: String) throws -> URL {
        let path = root.appendingPathComponent("native-fixture")
        try ("#!/bin/sh\n" + script).write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        return path
    }

    private func usage(_ tokens: Int) -> CodexAccountUsage {
        CodexAccountUsage(lifetimeTokens: tokens, peakDailyTokens: nil, longestRunningTurnSeconds: nil,
                          currentStreakDays: nil, longestStreakDays: nil, daily: [], fetchedAt: Date())
    }

    func testNativeProfileLoginAndLogoutPreserveOtherProfilesAndGlobalAuth() throws {
        let root = try root()
        let native = root.appendingPathComponent("native")
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        for directory in [native, first, second] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(directory.lastPathComponent.utf8).write(to: directory.appendingPathComponent("auth.json"))
            try Data("saved history".utf8).write(to: directory.appendingPathComponent("history.jsonl"))
        }
        let cli = try executable(root: root, script: """
        test "$1" = '-c' || exit 11
        test "$2" = 'cli_auth_credentials_store="file"' || exit 12
        test -z "${OPENAI_API_KEY+x}" || exit 13
        test -z "${CODEX_SQLITE_HOME+x}" || exit 14
        shift 2
        case "$1" in
          login) printf 'independent login' > "$CODEX_HOME/auth.json" ;;
          logout) /bin/rm "$CODEX_HOME/auth.json" ;;
          *) exit 15 ;;
        esac
        """)
        let environment = ["CODEX_HOME": native.path, "CODEX_SQLITE_HOME": native.path, "OPENAI_API_KEY": "fixture"]
        try CodexAuthenticationOperation().run(.login, executable: cli, environment: environment,
            inventory: { XCTFail("Other active Codex sessions must not block an independent monitoring login"); return [123] },
            profileDirectory: first)
        XCTAssertEqual(try String(contentsOf: first.appendingPathComponent("auth.json")), "independent login")
        try CodexAuthenticationOperation().run(.logout, executable: cli, environment: environment, profileDirectory: first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.appendingPathComponent("auth.json").path))
        XCTAssertEqual(try String(contentsOf: native.appendingPathComponent("auth.json")), "native")
        XCTAssertEqual(try String(contentsOf: second.appendingPathComponent("auth.json")), "second")
        XCTAssertEqual(try String(contentsOf: first.appendingPathComponent("history.jsonl")), "saved history")
    }

    func testAccountUsageReaderUsesRequestedHomeAndOnlyBlocksTheSameProfile() throws {
        let root = try root()
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        let cli = try executable(root: root, script: """
        test "$1" = '-c' || exit 11
        test "$2" = 'cli_auth_credentials_store="file"' || exit 12
        test "$3" = 'app-server' || exit 13
        IFS= read -r initialize
        IFS= read -r initialized
        IFS= read -r request
        case "$CODEX_HOME" in
          */first) tokens=111 ;;
          */second) tokens=222 ;;
          *) exit 14 ;;
        esac
        printf '{"id":1,"result":{"summary":{"lifetimeTokens":%s},"dailyUsageBuckets":[]}}\\n' "$tokens"
        while IFS= read -r rest; do :; done
        """)
        try CodexCredentialAccess.perform(scope: first.path) {
            XCTAssertThrowsError(try CodexAccountUsageReader(executableURL: cli, timeout: 2, profileDirectory: first).read())
            let read = try CodexAccountUsageReader(executableURL: cli, timeout: 2, profileDirectory: second).read()
            XCTAssertEqual(read.lifetimeTokens, 222)
        }
        XCTAssertEqual(try CodexAccountUsageReader(executableURL: cli, timeout: 2, profileDirectory: first).read().lifetimeTokens, 111)
    }

    @MainActor
    func testProfilesPersistIndependentlyAndRefreshKeepsQuotaAndTokensScoped() async throws {
        let root = try root()
        let suite = "monitoring-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var measured: [String] = []
        let store = CodexMonitoringStore(defaults: defaults, root: root, measure: { directory in
            measured.append(directory.lastPathComponent)
            let marker = try! String(contentsOf: directory.appendingPathComponent("auth.json"))
            let status = ProviderStatus(id: "codex", name: "Codex", state: .ok, detail: "Measured", lastUpdated: Date(),
                remainingPercent: marker == "first" ? 80 : 20,
                account: ProviderAccountIdentity(email: marker + "@example.test", organizationID: marker,
                                                  organizationName: nil, subscriptionType: "pro"))
            return CodexMonitoringResult(status: status, usage: self.usage(marker == "first" ? 111 : 222), usageError: nil)
        }, authenticate: { _, action, directory in
            if action == .logout { try FileManager.default.removeItem(at: directory.appendingPathComponent("auth.json")) }
        })
        let first = store.add(label: "Personal")
        let second = store.add(label: "Work")
        let empty = store.add(label: "Not connected")
        for (profile, marker) in [(first, "first"), (second, "second")] {
            let directory = try store.directory(for: profile)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(marker.utf8).write(to: directory.appendingPathComponent("auth.json"))
        }
        store.refresh(force: true)
        for _ in 0..<200 where store.refreshing { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(Set(measured), Set([first.id, second.id]))
        XCTAssertEqual(store.results[first.id]?.status.remainingPercent, 80)
        XCTAssertEqual(store.results[first.id]?.usage?.lifetimeTokens, 111)
        XCTAssertEqual(store.results[second.id]?.status.account?.email, "second@example.test")
        XCTAssertEqual(store.results[second.id]?.usage?.lifetimeTokens, 222)
        XCTAssertEqual(store.results[empty.id]?.status.authentication, .signInRequired)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try store.directory(for: empty).path))
        let restarted = CodexMonitoringStore(defaults: defaults, root: root)
        XCTAssertEqual(restarted.profiles, store.profiles)
        XCTAssertTrue(restarted.results.isEmpty, "Old measurements must not be reported as fresh after restart")
        store.signOut(first)
        for _ in 0..<200 where store.authenticatingID != nil || store.refreshing { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(store.results[first.id]?.status.authentication, .signInRequired)
        XCTAssertNil(store.results[first.id]?.usage)
        XCTAssertEqual(store.results[second.id]?.usage?.lifetimeTokens, 222)
        store.signIn(first)
        for _ in 0..<200 where store.authenticatingID != nil || store.refreshing { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(store.error?.contains("did not save") == true)
        XCTAssertEqual(store.results[first.id]?.status.authentication, .signInRequired)
        store.signIn(second)
        for _ in 0..<200 where store.authenticatingID != nil || store.refreshing { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNil(store.error)
        let permissions = try FileManager.default.attributesOfItem(atPath:
            store.directory(for: second).appendingPathComponent("auth.json").path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        store.remove(second)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try store.directory(for: second).appendingPathComponent("auth.json").path))
        XCTAssertFalse(store.profiles.contains(second))
    }

    @MainActor
    func testRedirectedProfileCannotAuthenticateOrBeMeasured() async throws {
        let root = try root()
        let outside = try self.root()
        let suite = "monitor-redirect-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CodexMonitoringStore(defaults: defaults, root: root,
            measure: { _ in XCTFail("Must not read redirected credentials"); fatalError() },
            authenticate: { _, _, _ in XCTFail("Must not launch native auth") })
        let profile = store.add(label: "Redirected")
        let directory = try store.directory(for: profile)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: outside)
        store.signIn(profile)
        XCTAssertNotNil(store.error)
        XCTAssertNil(store.authenticatingID)
        store.refresh(force: true)
        for _ in 0..<200 where store.refreshing { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNil(store.results[profile.id])
    }

    func testProviderDateTotalsNeverUseLocalOrOtherAccountHistory() throws {
        let first = Date(timeIntervalSince1970: 1000)
        let second = first.addingTimeInterval(86400)
        let usage = CodexAccountUsage(lifetimeTokens: 9000, peakDailyTokens: nil, longestRunningTurnSeconds: nil,
            currentStreakDays: nil, longestStreakDays: nil,
            daily: [CodexAccountDailyUsage(day: first, tokens: 100), CodexAccountDailyUsage(day: second, tokens: 200)], fetchedAt: second)
        XCTAssertEqual(codexMonitoringTokens(usage, start: nil, end: nil), 9000)
        XCTAssertEqual(codexMonitoringTokens(usage, start: second, end: second), 200)
        XCTAssertNil(codexMonitoringTokens(nil, start: nil, end: nil))
        XCTAssertNil(codexMonitoringTokens(self.usage(500), start: first, end: second))
    }

    @MainActor
    func testProfileBrowserCancellationAndRedirectedCredentialFile() async throws {
        let root = try root()
        let outside = try self.root()
        let suite = "monitor-cancel-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cli = try executable(root: root, script: "exec /bin/sleep 10\n")
        let store = CodexMonitoringStore(defaults: defaults, root: root, authenticate: { operation, action, directory in
            try operation.run(action, executable: cli, timeout: 2, profileDirectory: directory)
        })
        let profile = store.add(label: "Independent")
        store.signIn(profile)
        XCTAssertEqual(store.authenticatingID, profile.id)
        store.cancelAuthentication()
        for _ in 0..<200 where store.authenticatingID != nil || store.refreshing { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNil(store.authenticatingID)
        XCTAssertNotNil(store.error)
        let directory = try store.directory(for: profile)
        let permissions = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o700)
        let auth = outside.appendingPathComponent("auth.json")
        try Data("untouched native credential fixture".utf8).write(to: auth)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("auth.json"), withDestinationURL: auth)
        XCTAssertThrowsError(try store.directory(for: profile))
        store.signIn(profile)
        XCTAssertNil(store.authenticatingID)
        XCTAssertEqual(try String(contentsOf: auth), "untouched native credential fixture")
    }

    @MainActor
    func testAccountsPanelFitsSettingsAndStatisticsInBothAppearances() async throws {
        let root = try root()
        let suite = "monitor-ui-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CodexMonitoringStore(defaults: defaults, root: root, measure: { _ in
            CodexMonitoringResult(status: ProviderStatus(id: "codex", name: "Codex", state: .ok,
                detail: "Measured", lastUpdated: Date(), remainingPercent: 25,
                limitWindows: [ProviderLimitWindow(id: "primary", label: "5h", remainingPercent: 90, resetAt: Date()),
                               ProviderLimitWindow(id: "secondary", label: "7d", remainingPercent: 25, resetAt: Date())],
                account: ProviderAccountIdentity(email: "developer@example.test", organizationID: "fixture",
                    organizationName: nil, subscriptionType: "pro")), usage: self.usage(11_803_044_372), usageError: nil)
        })
        for name in ["Personal", "Work", "Secondary"] {
            let profile = store.add(label: name)
            if name != "Secondary" {
                let directory = try store.directory(for: profile)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data("fixture".utf8).write(to: directory.appendingPathComponent("auth.json"))
            }
        }
        store.refresh(force: true)
        for _ in 0..<200 where store.refreshing { try await Task.sleep(nanoseconds: 10_000_000) }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for width: CGFloat in [460, 860] {
                let host = NSHostingController(rootView: ScrollView {
                    CodexProfilesView(store: store, managesProfiles: true)
                }.frame(width: width, height: 550)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 550),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: appearance)
                window.contentViewController = host
                window.orderFrontRegardless()
                host.view.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                try await Task.sleep(nanoseconds: 100_000_000)
                XCTAssertEqual(host.view.fittingSize.width, width, accuracy: 1)
                XCTAssertEqual(host.view.fittingSize.height, 550, accuracy: 1)
                if let capture = ProcessInfo.processInfo.environment["FLEET_UI_CAPTURE_DIR"],
                   let bitmap = host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds) {
                    host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?.write(to:
                        URL(fileURLWithPath: capture).appendingPathComponent("profiles-\(Int(width))-\(appearance.rawValue).png"))
                }
                window.orderOut(nil)
                window.contentViewController = nil
            }
        }
    }
}
