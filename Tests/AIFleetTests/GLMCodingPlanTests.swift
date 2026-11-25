import XCTest
@testable import AIFleet

final class GLMCodingPlanTests: XCTestCase {
    func testPlanUsesReportedCreditAndTokenWindows() throws {
        let data = Data(#"""
        {"code":200,"success":true,"data":{"level":"pro","limits":[
          {"type":"CREDIT_LIMIT","unit":3,"number":5,"percentage":37,"nextResetTime":1793830124999},
          {"type":"TOKENS_LIMIT","unit":6,"number":1,"percentage":100},
          {"type":"TIME_LIMIT","unit":6,"number":1,"percentage":0},
          {"type":"CREDIT_LIMIT","unit":3,"number":5,"percentage":-1},
          {"type":"CREDIT_LIMIT","unit":3,"number":5}
        ]}}
        """#.utf8)
        let status = try GLMCodingPlan.decode(data)
        XCTAssertEqual(status.limitWindows.map(\.label), ["5h", "7d"])
        XCTAssertEqual(status.limitWindows.map(\.remainingPercent), [63, 0])
        XCTAssertEqual(status.limitWindows[0].resetAt, Date(timeIntervalSince1970: 1793830124.999))
        XCTAssertNil(status.limitWindows[1].resetAt)
        XCTAssertEqual(status.account?.planLabel, "Pro")
        XCTAssertNil(status.account?.email)
        XCTAssertTrue(status.hasCurrentQuota)
        XCTAssertEqual(status.remainingPercent, 0)
    }

    func testRejectedOrMissingQuotaNeverBecomesAMeasurement() throws {
        let rejected = try GLMCodingPlan.decode(Data(#"{"code":403,"success":false}"#.utf8))
        let empty = try GLMCodingPlan.decode(Data(#"{"code":200,"success":true,"data":{"limits":[]}}"#.utf8))
        XCTAssertEqual(rejected.authentication, .accessDenied)
        XCTAssertEqual(empty.authentication, .signedIn)
        XCTAssertFalse(rejected.hasCurrentQuota)
        XCTAssertFalse(empty.hasCurrentQuota)
    }

    @MainActor func testAccountScopedQuotaNeverBecomesAnotherAccountsQuota() throws {
        let suite = "GLMCodingPlanTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AccountStore(defaults: defaults)
        let first = store.add(name: "First", email: "first@example.test")
        let second = store.add(name: "Second", email: "second@example.test")
        for account in [first, second] { store.attachGlobal(GLMCodingPlan.providerID, to: account.id) }
        let links = store.visibleAccounts.compactMap { $0.connection(for: GLMCodingPlan.providerID) }
        XCTAssertEqual(links.count, 2)
        XCTAssertFalse(links[0].isNativeDefault)
        let result = try GLMCodingPlan.decode(Data(#"{"code":200,"data":{"limits":[{"type":"CREDIT_LIMIT","unit":3,"number":5,"percentage":10}]}}"#.utf8))
        let service = StatusService(session: .shared)
        service.applyGlobalStatuses([links[0].status(from: result), links[1].status(from: GLMCodingPlan.setup)], accounts: store)

        XCTAssertEqual(service.subscriptions.first { $0.id == links[0].statusID }?.remainingPercent, 90)
        XCTAssertNil(service.subscriptions.first { $0.id == links[1].statusID }?.remainingPercent)
        XCTAssertNil(service.globalAccountIDs[GLMCodingPlan.providerID])
    }
}
