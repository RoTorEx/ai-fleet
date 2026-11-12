import AppKit
import SwiftUI
import XCTest
@testable import AIFleet

final class AccountProviderPresentationTests: XCTestCase {
    func testMenuAvailabilityAndLoginAreDifferentStates() {
        let signedInWithoutLimits = ProviderStatus(id: "claude", name: "Claude", state: .offline,
            detail: "Limits access expired", lastUpdated: Date(), authentication: .signedIn, quotaFailure: .credentialsExpired)
        let unavailable = MenuConnectionState(status: signedInWithoutLimits)
        XCTAssertFalse(unavailable.available)
        XCTAssertEqual(unavailable.marker, "?")
        XCTAssertEqual(unavailable.detail, "Quota credentials expired")
        let signedOut = ProviderStatus(id: "codex", name: "Codex", state: .noKey, detail: "Sign in required", lastUpdated: nil)
        XCTAssertEqual(MenuConnectionState(status: signedOut).marker, "×")
        let exhausted = status("work@example.test", remaining: 0)
        XCTAssertTrue(MenuConnectionState(status: exhausted).available)
        XCTAssertEqual(MenuConnectionState(status: exhausted).marker, "○", "Zero is a loaded limit, not missing access")
        let stale = exhausted.withQuotaNotice("Retry later")
        XCTAssertFalse(MenuConnectionState(status: stale).available)
        XCTAssertEqual(MenuConnectionState(status: stale).marker, "?")
    }

    func testArrowsAndSwitchDistinguishSelectedAccountsFromOtherSavedLogins() {
        func row(_ id: String, provider: String = "codex", remaining: Int,
                 current: Bool?, auth: ProviderStatus.Authentication = .signedIn,
                 quota: ProviderStatus.QuotaState = .available) -> MenuAccountConnection {
            let connection = ProviderConnection.global(provider)
            let account = FleetAccount(id: id, badgeIndex: 0, name: id, email: id + "@example.test", connections: [connection])
            let measured = ProviderStatus(id: provider, name: provider, state: .ok, detail: "Fixture",
                lastUpdated: Date(), remainingPercent: remaining, authentication: auth, quotaState: quota)
            return MenuAccountConnection(account: account, connection: ProviderConnection(id: id, providerID: provider),
                status: measured, isSelected: auth == .signedIn, isCurrentCLI: current)
        }
        let personal = row("personal", remaining: 88, current: true)
        let work = row("work", remaining: 24, current: false)
        let claude = row("claude", provider: "claude", remaining: 71, current: true)
        let rows = [personal, work, claude]
        let lowest = lowestCurrentQuotaConnectionID(in: rows)
        XCTAssertEqual(lowest, claude.id, "A lower saved login must never displace an active account")
        XCTAssertEqual(rows.map { menuConnectionMark($0, lowestID: lowest) }, ["→", "", "↓"])
        XCTAssertFalse(personal.canSwitch)
        XCTAssertFalse(claude.canSwitch)
        XCTAssertTrue(work.canSwitch, "Another signed-in account must still be switchable")

        let selectedWork = row("work", remaining: 24, current: true)
        let oldPersonal = row("personal", remaining: 88, current: false)
        let switched = [oldPersonal, selectedWork, claude]
        XCTAssertEqual(switched.map { menuConnectionMark($0, lowestID: lowestCurrentQuotaConnectionID(in: switched)) }, ["", "↓", "→"])
        XCTAssertTrue(oldPersonal.canSwitch)
        XCTAssertFalse(selectedWork.canSwitch)

        for unavailable in [row("out", remaining: 1, current: true, auth: .signInRequired),
                            row("unknown", remaining: 1, current: true, auth: .unknown),
                            row("stale", remaining: 1, current: true, quota: .stale)] {
            XCTAssertNil(lowestCurrentQuotaConnectionID(in: [unavailable]))
            XCTAssertFalse(["→", "↓"].contains(menuConnectionMark(unavailable, lowestID: unavailable.id)))
        }
        let undetermined = row("undetermined", remaining: 1, current: nil)
        XCTAssertTrue(undetermined.canSwitch)
        XCTAssertEqual(menuConnectionMark(undetermined, lowestID: undetermined.id), "")
        let exhausted = row("zero", remaining: 0, current: true, quota: .exhausted)
        XCTAssertNil(lowestCurrentQuotaConnectionID(in: [exhausted]))
        XCTAssertEqual(menuConnectionMark(exhausted, lowestID: nil), "→")
        XCTAssertFalse(exhausted.canSwitch, "Exhausted quota does not change the selected login")
    }

    func testMenuStatusDescribesApplicationOperationsAndKeepsUpdateFailureVisible() {
        XCTAssertEqual(MenuOperationStatus.resolve(update: .idle, refreshing: false).title, "Active")
        XCTAssertEqual(MenuOperationStatus.resolve(update: .idle, refreshing: false, monitoring: false).title, "Paused")
        let checked = MenuOperationStatus.resolve(update: .upToDate("1.3.5"), refreshing: false)
        XCTAssertEqual(checked.title, "Active", "An update result must not replace the monitoring state")
        XCTAssertEqual(checked.detail, "Latest version installed")
        XCTAssertEqual(MenuOperationStatus.resolve(update: .idle, refreshing: true).title, "Updating limits…")
        XCTAssertEqual(MenuOperationStatus.resolve(update: .idle, refreshing: true, signingIn: "Signing in Codex (β)…").title,
                       "Signing in Codex (β)…")
        let failed = MenuOperationStatus.resolve(update: .failed("Update check failed (HTTP 403)."), refreshing: true)
        XCTAssertTrue(failed.failed)
        XCTAssertEqual(failed.title, "Update failed")
        XCTAssertEqual(failed.detail, "Update check failed (HTTP 403).")
        XCTAssertEqual(MenuOperationStatus.resolve(update: .checking, refreshing: false).title, "Checking for updates…")
    }

    func testQuotaAvailabilityRequiresCurrentMeasurementRatherThanLogin() {
        func measured(_ remaining: Int?, auth: ProviderStatus.Authentication = .signedIn,
                      quota: ProviderStatus.QuotaState) -> ProviderStatus {
            ProviderStatus(id: "fixture", name: "Fixture", state: .ok, detail: "Fixture", lastUpdated: Date(),
                remainingPercent: remaining, authentication: auth, quotaState: quota)
        }
        let available = measured(74, quota: .available)
        let noClaudeQuota = measured(nil, quota: .unavailable)
        XCTAssertEqual(quotaAvailabilityText([available, available, noClaudeQuota]), "2/3 loaded")
        XCTAssertEqual(quotaAvailabilityText([available, measured(0, quota: .exhausted),
            noClaudeQuota, measured(70, quota: .stale), measured(99, auth: .unknown, quota: .available)]), "2/5 loaded")
        XCTAssertEqual(quotaAvailabilityText([]), "none installed")
    }

    private func status(_ email: String, remaining: Int) -> ProviderStatus {
        ProviderStatus(id: "codex", name: "Codex", state: .ok, detail: "Measured", lastUpdated: Date(),
            remainingPercent: remaining,
            limitWindows: [ProviderLimitWindow(id: "secondary", label: "7d", remainingPercent: remaining, resetAt: nil)],
            account: ProviderAccountIdentity(email: email, organizationID: "test", organizationName: nil, subscriptionType: "pro"))
    }

    @MainActor
    func testProviderWithoutIdentityMarksItsOnlyAccountCurrent() throws {
        let suite = "account-rows-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let accounts = AccountStore(defaults: defaults, homeDirectory: root)
        let first = accounts.add(name: "Personal", email: "personal@example.test")
        accounts.attachGlobal("kimi", to: first.id)
        let codex = CodexMonitoringStore(defaults: defaults, root: root)
        let kimi = ProviderStatus(id: "kimi", name: "Kimi", state: .ok, detail: "98% left", lastUpdated: Date(), remainingPercent: 98)
        let rows = { accountProviderRows(accounts: accounts.accounts, providerID: "kimi", global: kimi,
                                         statusForConnection: { $0.status(from: kimi) }, codex: codex) }
        XCTAssertEqual(rows().map(\.isCurrentCLI), [true])

        let second = accounts.add(name: "Work", email: "work@example.test")
        accounts.attachGlobal("kimi", to: second.id)
        XCTAssertEqual(rows().map(\.isCurrentCLI), [false, false], "Without an identity, two accounts stay undetermined")
    }

    @MainActor
    func testTwoCodexAccountsKeepTheirBadgesAndLimitsWhenWorkingAccountChanges() async throws {
        let suite = "account-rows-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let accounts = AccountStore(defaults: defaults, homeDirectory: root)
        let personal = accounts.add(name: "Personal", email: "personal@example.test")
        let work = accounts.add(name: "Company", email: "work@example.test")
        let third = accounts.add(name: "Other company", email: "third@example.test")
        accounts.attachGlobal("codex", to: personal.id)
        accounts.attachGlobal("codex", to: work.id)
        accounts.attachGlobal("claude", to: third.id)
        let measure: (URL) async -> CodexMonitoringResult = { directory in
            let email = try! String(contentsOf: directory.appendingPathComponent("auth.json"))
            return CodexMonitoringResult(status: self.status(email, remaining: email == personal.email ? 87 : 24),
                                         usage: nil, usageError: nil)
        }
        let codex = CodexMonitoringStore(defaults: defaults, root: root, measure: measure)
        for account in [personal, work] {
            let profile = codex.ensureProfile(for: account)
            XCTAssertEqual(codex.ensureProfile(for: account).id, profile.id, "One Codex per account")
            let directory = try codex.directory(for: profile)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(account.email.utf8).write(to: directory.appendingPathComponent("auth.json"))
        }
        codex.refresh(force: true)
        for _ in 0..<200 where codex.refreshing { try await Task.sleep(nanoseconds: 10_000_000) }
        for current in [personal, work] {
            let rows = accountProviderRows(accounts: accounts.accounts, providerID: "codex",
                global: status(current.email, remaining: 1), statusForConnection: { _ in nil }, codex: codex)
            XCTAssertEqual(rows.map(\.account.badge), ["α", "β"])
            XCTAssertEqual(rows.map(\.status.remainingPercent), [87, 24])
            XCTAssertTrue(rows.allSatisfy(\.isSelected), "Both independently authenticated accounts remain available")
            XCTAssertEqual(rows.filter { $0.isCurrentCLI == true }.map(\.account.id), [current.id])
            XCTAssertEqual(rows.filter { !$0.canSwitch }.map(\.account.id), [current.id])
            XCTAssertEqual(rows.filter { !menuConnectionMark($0, lowestID: lowestCurrentQuotaConnectionID(in: rows)).isEmpty }
                .map(\.account.id), [current.id])
        }
        defaults.set(work.id, forKey: CodexTerminalLaunch.selectionKey)
        let selectedCodex = CodexMonitoringStore(defaults: defaults, root: root, measure: measure)
        selectedCodex.refresh(force: true)
        for _ in 0..<200 where selectedCodex.refreshing { try await Task.sleep(nanoseconds: 10_000_000) }
        let selectedRows = accountProviderRows(accounts: accounts.accounts, providerID: "codex",
            global: status(personal.email, remaining: 1), statusForConnection: { _ in nil }, codex: selectedCodex)
        XCTAssertEqual(selectedRows.filter(\.isCurrentAccount).map(\.account.id), [work.id],
                       "A saved next-launch selection wins over the old native login")
        XCTAssertEqual(selectedRows.filter { !$0.canSwitch }.map(\.account.id), [work.id])
        XCTAssertEqual(selectedRows.map { menuConnectionMark($0, lowestID: lowestCurrentQuotaConnectionID(in: selectedRows)) }, ["", "↓"])
        XCTAssertEqual(accounts.visibleAccounts.map(\.badge), ["α", "β", "γ"])
        XCTAssertEqual(codex.profiles.count, 2)
        let claude = ProviderStatus(id: "claude", name: "Claude", state: .ok, detail: "Measured", lastUpdated: Date(),
            remainingPercent: 8,
            limitWindows: [ProviderLimitWindow(id: "primary", label: "5h", remainingPercent: 8, resetAt: nil)],
            account: ProviderAccountIdentity(email: third.email, organizationID: nil, organizationName: nil, subscriptionType: "team"))
        let claudeRows = accountProviderRows(accounts: accounts.accounts, providerID: "claude", global: claude,
            statusForConnection: { $0.status(from: claude) }, codex: codex)
        XCTAssertEqual(claudeRows.map(\.account.badge), ["γ"])
        let displayed = accountProviderRows(accounts: accounts.accounts, providerID: "codex",
            global: status(work.email, remaining: 1), statusForConnection: { _ in nil }, codex: codex) + claudeRows
        let sorted = sortedAccountProviderRows(Array(displayed.reversed()))
        XCTAssertEqual(sorted.map(\.status.name), ["Claude", "Codex", "Codex"])
        XCTAssertEqual(sorted.map(\.account.badge), ["γ", "α", "β"], "Greek badge order is stable when terminal identity changes")
        let personalCurrent = accountProviderRows(accounts: accounts.accounts, providerID: "codex",
            global: status(personal.email, remaining: 1), statusForConnection: { _ in nil }, codex: codex)
        XCTAssertEqual(sortedAccountProviderRows(Array(personalCurrent.reversed())).map(\.account.badge), ["α", "β"])
        let noCurrent = accountProviderRows(accounts: accounts.accounts, providerID: "codex",
            global: status("unlinked@example.test", remaining: 1), statusForConnection: { _ in nil }, codex: codex)
        XCTAssertEqual(sortedAccountProviderRows(Array(noCurrent.reversed())).map(\.account.badge), ["α", "β"],
                       "Independent sign-in does not displace Greek badge order")
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let host = NSHostingController(rootView: VStack(alignment: .leading, spacing: 8) {
                ForEach(sorted) { entry in
                    ProviderLimitRow(entry: entry, mark: menuConnectionMark(entry, lowestID: lowestCurrentQuotaConnectionID(in: sorted)), openSettings: {})
                }
            }.padding(16).frame(width: 354).background(Color(nsColor: NSColor(white: appearance == .darkAqua ? 0.18 : 0.56, alpha: 1)))
                .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 354, height: 300),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentViewController = host
            window.orderFrontRegardless()
            host.view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertEqual(host.view.fittingSize.width, 354, accuracy: 1)
            if let capture = ProcessInfo.processInfo.environment["FLEET_UI_CAPTURE_DIR"],
               let bitmap = host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds) {
                host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to:
                    URL(fileURLWithPath: capture).appendingPathComponent("account-rows-\(appearance.rawValue).png"))
            }
            window.orderOut(nil)
            window.contentViewController = nil
        }
    }

    @MainActor
    func testAccountMismatchNeverBorrowsAnotherAccountsQuota() throws {
        let suite = "account-mismatch-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let accounts = AccountStore(defaults: defaults)
        let personal = accounts.add(email: "personal@example.test")
        let work = accounts.add(email: "work@example.test")
        accounts.attachGlobal("codex", to: personal.id)
        accounts.attachGlobal("codex", to: work.id)
        let codex = CodexMonitoringStore(defaults: defaults)
        let rows = accountProviderRows(accounts: accounts.accounts, providerID: "codex",
            global: status(personal.email, remaining: 87), statusForConnection: { _ in nil }, codex: codex)
        XCTAssertEqual(rows[0].status.remainingPercent, 87)
        XCTAssertNil(rows[1].status.remainingPercent)
        XCTAssertEqual(rows[1].status.authentication, .unknown)
        let anotherWorkspace = accounts.add(name: "Another workspace", email: personal.email)
        accounts.attachGlobal("codex", to: anotherWorkspace.id)
        let ambiguous = accountProviderRows(accounts: accounts.accounts, providerID: "codex",
            global: status(personal.email, remaining: 87), statusForConnection: { _ in nil }, codex: codex)
        XCTAssertTrue(ambiguous.allSatisfy { $0.status.remainingPercent == nil }, "An ambiguous shared login cannot be assigned to two badges")
        accounts.attachGlobal("codex", to: personal.id)
        XCTAssertEqual(accounts.accounts.first { $0.id == personal.id }?.connections.filter { $0.providerID == "codex" }.count, 1)
    }

    @MainActor
    func testLegacySavedLoginAdoptsExistingAccountWithoutMovingCredentialsOrBadge() throws {
        let suite = "account-adoption-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let accounts = AccountStore(defaults: defaults)
        let account = accounts.add(name: "Work", email: "work@example.test")
        let codex = CodexMonitoringStore(defaults: defaults)
        let old = codex.add(label: account.email)
        let originalPath = try codex.directory(for: old)
        codex.synchronizeAccounts(accounts)
        let adopted = try XCTUnwrap(codex.profile(for: account))
        XCTAssertEqual(adopted.id, old.id)
        XCTAssertEqual(try codex.directory(for: adopted), originalPath)
        XCTAssertEqual(accounts.visibleAccounts.count, 1)
        XCTAssertEqual(accounts.visibleAccounts[0].badge, "α")
        XCTAssertEqual(CodexMonitoringStore(defaults: defaults).profile(for: account)?.id, old.id)
    }

    @MainActor
    func testWrongBrowserAccountDoesNotExposeItsQuotaOrTokenTotalUnderWorkBadge() async throws {
        let suite = "bound-account-mismatch-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let accounts = AccountStore(defaults: defaults)
        let account = accounts.add(email: "work@example.test")
        accounts.attachGlobal("codex", to: account.id)
        let codex = CodexMonitoringStore(defaults: defaults, root: root, measure: { _ in
            CodexMonitoringResult(status: self.status("personal@example.test", remaining: 99),
                usage: CodexAccountUsage(lifetimeTokens: 1234, peakDailyTokens: nil, longestRunningTurnSeconds: nil,
                    currentStreakDays: nil, longestStreakDays: nil, daily: [], fetchedAt: Date()), usageError: nil)
        })
        let profile = codex.ensureProfile(for: account)
        let directory = try codex.directory(for: profile)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: directory.appendingPathComponent("auth.json"))
        codex.refresh(force: true)
        for _ in 0..<200 where codex.refreshing { try await Task.sleep(nanoseconds: 10_000_000) }
        let displayed = codex.status(for: account, global: status("personal@example.test", remaining: 99), accounts: accounts.visibleAccounts)
        XCTAssertNil(displayed.remainingPercent)
        XCTAssertTrue(displayed.limitWindows.isEmpty)
        XCTAssertEqual(displayed.authentication, .unknown)
        XCTAssertNil(codex.usage(for: account, global: displayed, accounts: accounts.visibleAccounts))
    }
}
