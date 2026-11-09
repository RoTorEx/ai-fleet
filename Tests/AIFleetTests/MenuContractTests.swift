import XCTest
@testable import AIFleet

final class MenuContractTests: XCTestCase {
    @MainActor
    func testBadgesFollowOrderAcrossRemovalReorderAndRestart() throws {
        let suite = "stage5-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AccountStore(defaults: defaults, homeDirectory: root)
        let accounts = (0..<10).map { store.add(name: "Account \($0)", email: "a\($0)@example.test") }
        XCTAssertEqual(accounts.map(\.badge), Array("αβγδεζηθικ").map(String.init))
        store.remove(accounts[4].id)
        let restarted = AccountStore(defaults: defaults, homeDirectory: root)
        let remaining = accounts.filter { $0.id != accounts[4].id }.map(\.id)
        XCTAssertEqual(restarted.visibleAccounts.map(\.id), remaining, "Removal keeps the order")
        XCTAssertEqual(restarted.visibleAccounts.map(\.badge), Array("αβγδεζηθι").map(String.init), "and closes the gap")
        XCTAssertEqual(restarted.add().badge, "κ")

        // Dragging the last account to the top makes it α and shifts the rest down.
        let last = restarted.visibleAccounts.last!
        restarted.moveAccounts(from: IndexSet(integer: restarted.visibleAccounts.count - 1), to: 0)
        let reordered = AccountStore(defaults: defaults, homeDirectory: root)
        XCTAssertEqual(reordered.visibleAccounts.first?.id, last.id)
        XCTAssertEqual(reordered.visibleAccounts.first?.badge, "α")
        XCTAssertEqual(reordered.visibleAccounts.dropFirst().first?.id, remaining.first)
        XCTAssertEqual(reordered.visibleAccounts.dropFirst().first?.badge, "β")
    }

    func testUnavailableProviderRowsSinkAndEachHalfKeepsItsOrder() {
        func row(_ provider: String, _ state: ProviderStatus.State) -> MenuAccountConnection {
            let account = FleetAccount(id: provider, badgeIndex: 0, name: "", email: "", connections: [])
            return MenuAccountConnection(account: account, connection: .global(provider),
                                         status: ProviderStatus(id: provider, name: provider, state: state, detail: "", lastUpdated: Date(),
                                                                remainingPercent: state == .ok || state == .limited ? 50 : nil), isSelected: false)
        }
        let rows = [row("claude", .noKey), row("codex", .ok), row("gemini", .notInstalled), row("kimi", .limited)]
        XCTAssertEqual(menuRowsAvailableFirst(rows).map(\.connection.providerID), ["codex", "kimi", "claude", "gemini"])
    }

    @MainActor
    func testSetupRowsHaveNoSavedAccountAndDoNotCount() throws {
        let suite = "stage5-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let codex = CodexMonitoringStore(defaults: defaults)
        let rows = menuProviderRows(accounts: [], enabled: { $0 != "qwen" }, global: {
            LocalProviderAuth.unknown.status(for: ProviderCatalog.definition(for: $0)!)
        }, statusForConnection: { _ in nil }, codex: codex)
        XCTAssertEqual(rows.map { $0.status.name }, ["Claude", "Codex", "Gemini", "Kimi"])
        XCTAssertTrue(rows.allSatisfy { $0.isSetup && $0.account.badge.isEmpty })
        XCTAssertEqual(MonitoringSummary(rows: rows, monitoring: true).total, 0)
        let account = FleetAccount(id: "test", badgeIndex: 9, name: "Test", email: "", connections: [])
        let zero = ProviderStatus(id: "kimi", name: "Kimi", state: .limited, detail: "", lastUpdated: Date(), remainingPercent: 0)
        let saved = MenuAccountConnection(account: account, connection: .global("kimi"), status: zero, isSelected: false)
        let summary = MonitoringSummary(rows: rows + [saved], monitoring: false)
        XCTAssertEqual(summary.total, 1)
        XCTAssertEqual(summary.measured, 1)
    }

    func testResetBoundariesAndReasonSurviveAccountMapping() {
        let now = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(QuotaResetState(resetAt: nil, now: now).text(now: now), "Not reported")
        XCTAssertEqual(QuotaResetState(resetAt: now, now: now).text(now: now), "Reset due")
        XCTAssertEqual(QuotaResetState(resetAt: now.addingTimeInterval(0.1), now: now).text(now: now), "1s")
        XCTAssertEqual(QuotaResetState(resetAt: now.addingTimeInterval(90061), now: now).text(now: now), "1d 1h 1m 1s")
        XCTAssertEqual(QuotaResetState(resetAt: now.addingTimeInterval(7205), now: now).text(now: now), "2h 0m 5s")
        XCTAssertEqual(QuotaResetState(resetAt: now.addingTimeInterval(86400), now: now).text(now: now), "1d 0h 0m 0s")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Warsaw")!
        let morning = calendar.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 9))!
        let laterToday = calendar.date(byAdding: .hour, value: 2, to: morning)!
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: laterToday)!
        XCTAssertFalse(formatResetTime(laterToday, now: morning, calendar: calendar).contains("Nov"))
        XCTAssertTrue(formatResetTime(tomorrow, now: morning, calendar: calendar).contains("Nov"))
        let status = ClaudeQuota.unavailable("arbitrary provider text", reason: .rateLimited).withAuthentication(.signedIn)
        let mapped = ProviderConnection.global("claude").status(from: status).withAccount(nil)
        XCTAssertEqual(mapped.quotaFailureReason, .rateLimited)
        XCTAssertEqual(MenuConnectionState(status: mapped).detail, "Quota requests limited")
    }
}
