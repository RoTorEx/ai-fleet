import Foundation
import XCTest
@testable import AIFleet

final class AgentSessionContractTests: XCTestCase {
    func contract(state: String, linked: Bool = true, stale: Bool = false, extras: [String: Any] = [:]) throws -> AgentSessionContract {
        var row: [String: Any] = ["id": "7-100", "provider": "codex", "project": "/work/project", "title": "Original title",
            "state": state, "explanation": "Observed", "updatedAt": 80]
        if linked { row["location"] = ["id": "pane", "window": "Work", "tab_index": 0, "pane_index": 0] }
        row.merge(extras) { _, new in new }
        let session = try JSONDecoder().decode(AgentSession.self, from: JSONSerialization.data(withJSONObject: row))
        return AgentSessionContract(session: session, observedAt: Date(timeIntervalSince1970: 100), stale: stale)
    }
    func testActualEngineLabelsKeepReadyDistinctFromOpenedWithoutClaimingRead() throws {
        XCTAssertEqual(try contract(state: "New reply").state, .ready)
        XCTAssertEqual(try contract(state: "Opened").state, .idle)
        XCTAssertEqual(try contract(state: "Untracked").state, .idle)
        XCTAssertEqual(try contract(state: "Approval").state, .approval)
        XCTAssertEqual(try contract(state: "Question").state, .question)
        XCTAssertEqual(try contract(state: "Blocked").state, .error)
        XCTAssertEqual(try contract(state: "FutureState").state, .unknown)
        XCTAssertEqual(try contract(state: "Working", linked: false).state, .unlinked)
    }
    func testPollingTimeNeverBecomesLastMessageTime() throws {
        XCTAssertNil(try contract(state: "Working").lastMessageAt)
        let result = try contract(state: "Working", extras: ["lastMessageAt": 55, "activityObservedAt": 90])
        XCTAssertEqual(result.lastMessageAt, Date(timeIntervalSince1970: 55))
        XCTAssertEqual(result.activityObservedAt, Date(timeIntervalSince1970: 90))
        XCTAssertNil(try contract(state: "Working", extras: ["lastMessageAt": 101]).lastMessageAt)
        XCTAssertNil(try contract(state: "Working", extras: ["lastMessageAt": -1]).lastMessageAt)
    }
    func testElapsedTimeRequiresExplicitBasisAndStopsOnStaleIdleOrUnlinked() throws {
        let extras: [String: Any] = ["workStartedAt": 60, "workTimeSource": "observed"]
        let active = try contract(state: "Working", extras: extras)
        XCTAssertEqual(active.workingDuration(at: Date(timeIntervalSince1970: 110)), 50)
        XCTAssertEqual(active.workTimeSource, .observed)
        XCTAssertNil(try contract(state: "Working", extras: ["workStartedAt": 60]).workStartedAt)
        XCTAssertNil(try contract(state: "Opened", extras: extras).workingDuration(at: Date()))
        let stale = try contract(state: "Working", stale: true, extras: extras)
        XCTAssertEqual(stale.state, .stale)
        XCTAssertNil(stale.workingDuration(at: Date()))
        XCTAssertNil(try contract(state: "Working", linked: false, extras: extras).workStartedAt)
    }
    func testIdentityAndRawSourceSurviveWithoutTakingAccountFromGlobalSelection() throws {
        let result = try contract(state: "Working", extras: ["pid": 7, "processStarted": 100, "cwd": "/work/project/subdir", "stateSource": "terminalHeuristic"])
        XCTAssertEqual(result.pid, 7)
        XCTAssertEqual(result.processStarted, 100)
        XCTAssertEqual(result.originalTitle, "Original title")
        XCTAssertEqual(result.workingDirectory, "/work/project/subdir")
        XCTAssertEqual(result.stateSource, "terminalHeuristic")
    }
}
