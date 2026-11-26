import XCTest
@testable import AIFleet

final class WeeklyQuotaPacingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 86_400

    private func report(remaining: Int = 60, label: String = "7d", resetIn: TimeInterval? = 4 * 86_400,
                        observedAgo: TimeInterval? = 60, quotaState: ProviderStatus.QuotaState = .available,
                        auth: ProviderStatus.Authentication = .signedIn, provider: String = "codex",
                        accountID: String = "a") -> StatisticsProviderReport {
        let window = ProviderLimitWindow(id: "secondary", label: label, remainingPercent: remaining,
                                         resetAt: resetIn.map { now.addingTimeInterval($0) })
        let fiveHour = ProviderLimitWindow(id: "primary", label: "5h", remainingPercent: 1, resetAt: now.addingTimeInterval(3600))
        return StatisticsProviderReport(provider: provider, accountID: accountID,
            identity: ConnectionIdentity(email: "one@example.test", organizationID: nil),
            fetchedAt: observedAgo.map { now.addingTimeInterval(-$0) }, accountUsage: nil,
            limits: [fiveHour, window], quotaAuthentication: auth, quotaState: quotaState)
    }

    func testCurrentWeeklyWindowUsesObservedResetAndIgnoresShorterWindows() throws {
        // Reset in 4 days: the window began 3 days before now; the observation is one minute old.
        let pace = WeeklyQuotaPace.make(report: report(remaining: 60, observedAgo: 60), now: now)
        XCTAssertEqual(pace.state, .current)
        XCTAssertEqual(pace.usedPercent, 40, "The 5h window at 1% left must not stand in for the weekly one")
        XCTAssertEqual(pace.timeToReset, 4 * day)
        let budget = try XCTUnwrap(pace.dailyBudgetPercent)
        XCTAssertEqual(budget, 300.0 / 7, accuracy: 1e-9, "The third day uses three sevenths of the quota")
        XCTAssertEqual(try XCTUnwrap(pace.headroomPoints), budget - 40, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(pace.sustainablePercentPerDay), 15, accuracy: 1e-9)
    }

    func testPlanAllowsTheFullQuotaThroughoutTheSeventhDay() {
        let milestones = (0...7).map { index in
            WeeklyQuotaPace.budget(at: now.addingTimeInterval(Double(index) * day), cycleStart: now)
        }
        XCTAssertEqual(milestones, (1...7).map { Double($0) * 100 / 7 } + [100])
        XCTAssertEqual(WeeklyQuotaPace.budget(at: now.addingTimeInterval(day - 1), cycleStart: now), 100.0 / 7)
        XCTAssertEqual(WeeklyQuotaPace.budget(at: now.addingTimeInterval(7 * day - 1), cycleStart: now), 100)
    }

    func testOverBudgetHasNegativeHeadroomAndExhaustedStillPaces() throws {
        let over = WeeklyQuotaPace.make(report: report(remaining: 20, resetIn: 6 * day), now: now)
        XCTAssertLessThan(try XCTUnwrap(over.headroomPoints), 0)
        let exhausted = WeeklyQuotaPace.make(report: report(remaining: 0, quotaState: .exhausted), now: now)
        XCTAssertEqual(exhausted.state, .current)
        XCTAssertEqual(exhausted.sustainablePercentPerDay, 0)
    }

    func testFreshnessBoundary() {
        let limit = WeeklyQuotaPace.maximumObservationAge
        XCTAssertEqual(WeeklyQuotaPace.make(report: report(observedAgo: limit), now: now).state, .current)
        let stale = WeeklyQuotaPace.make(report: report(observedAgo: limit + 1), now: now)
        XCTAssertEqual(stale.state, .stale)
        XCTAssertEqual(stale.usedPercent, 40, "Stale keeps the observed percentage for display")
        XCTAssertNil(stale.headroomPoints)
        XCTAssertNil(stale.sustainablePercentPerDay)
        XCTAssertEqual(WeeklyQuotaPace.make(report: report(quotaState: .stale), now: now).state, .stale)
        XCTAssertEqual(WeeklyQuotaPace.make(report: report(observedAgo: nil), now: now).state, .stale)
        XCTAssertEqual(WeeklyQuotaPace.make(report: report(observedAgo: -600), now: now).state, .stale,
                       "An observation from the future is not trusted")
    }

    func testResetBoundaryNeverImpliesReplenishment() {
        XCTAssertEqual(WeeklyQuotaPace.make(report: report(resetIn: 1), now: now).state, .current)
        for resetIn in [0, -1, -3 * day] {
            let pace = WeeklyQuotaPace.make(report: report(remaining: 5, resetIn: resetIn), now: now)
            XCTAssertEqual(pace.state, .resetPending)
            XCTAssertEqual(pace.usedPercent, 95, "The old value stays labelled, not reset to 0% used")
            XCTAssertNil(pace.sustainablePercentPerDay)
        }
    }

    func testMissingOrInconsistentResetIsPartial() {
        let missing = WeeklyQuotaPace.make(report: report(resetIn: nil), now: now)
        XCTAssertEqual(missing.state, .partial)
        XCTAssertEqual(missing.usedPercent, 40)
        XCTAssertNil(missing.dailyBudgetPercent)
        XCTAssertEqual(WeeklyQuotaPace.make(report: report(resetIn: 7 * day), now: now).state, .current,
                       "A reset exactly one window after the observation is a window start")
        XCTAssertEqual(WeeklyQuotaPace.make(report: report(resetIn: 7 * day + 61, observedAgo: 0), now: now).state, .partial)
    }

    func testUnavailableWithoutTrustedWeeklyWindow() {
        for candidate in [report(label: "30d"), report(label: "7d (Opus)"), report(auth: .unknown),
                          report(auth: .signInRequired), report(quotaState: .unavailable), report(quotaState: .unknown),
                          report(remaining: 120)] {
            let pace = WeeklyQuotaPace.make(report: candidate, now: now)
            XCTAssertEqual(pace.state, .unavailable)
            XCTAssertNil(pace.usedPercent)
        }
    }

    func testIdentityMismatchProducesNoBorrowedWeeklyQuota() {
        let account = FleetAccount(id: "a", badgeIndex: 0, name: "", email: "one@example.test", connections: [])
        let connection = ProviderConnection(id: "c", providerID: "claude", configDirectory: "/fixture")
        let other = ProviderStatus(id: "claude", name: "Claude", state: .ok, detail: "", lastUpdated: now,
            remainingPercent: 50, limitWindows: [ProviderLimitWindow(id: "seven_day", label: "7d", remainingPercent: 50, resetAt: now.addingTimeInterval(day))],
            account: ProviderAccountIdentity(email: "two@example.test", organizationID: nil, organizationName: nil, subscriptionType: nil))
        XCTAssertNil(StatisticsProviderReport.make(account: account, connection: connection, status: other))
    }

    func testCompactCountdownFormatting() {
        XCTAssertEqual(WeeklyQuotaPace.countdownText(4 * day), "4d 0h")
        XCTAssertEqual(WeeklyQuotaPace.countdownText(5 * 3600 + 11 * 60 + 1), "5h 12m")
        XCTAssertEqual(WeeklyQuotaPace.countdownText(1), "1m")
    }
}
