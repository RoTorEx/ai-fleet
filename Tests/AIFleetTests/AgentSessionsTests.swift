import AppKit
import SwiftUI
import XCTest
@testable import AIFleet

final class AgentSessionsTests: XCTestCase {
    private static let rows = #"""
    [
      {"id":"7-10","provider":"codex","project":"/work/client/project","title":"Review authentication","dataVersion":1,"pid":7,"processStarted":10,"lastMessageAt":1799999990,"workStartedAt":1799999980,"workTimeSource":"observed","stateSource":"terminalHeuristic","state":"Working","explanation":"Working","location":{"id":"pane-7","window":"Client","tab_index":1,"pane_index":0}},
      {"id":"8-10","provider":"claude","project":"/personal/project","title":"Check deployment","state":"Approval","explanation":"Needs approval","location":null,"linkReason":"Ambiguous pane linkage"}
    ]
    """#

    func testGroupingPreservesDuplicateProjectNamesAndIndependentSessionIdentities() throws {
        let sessions = try JSONDecoder().decode([AgentSession].self, from: Data(Self.rows.utf8))
        let groups = AgentGroup.make(sessions)
        XCTAssertEqual(Set(groups.map(\.name)), Set(["client/project", "personal/project"]))
        XCTAssertEqual(sessions[0].locationLabel, "Client · tab 2 · pane 1")
        XCTAssertTrue(sessions[0].isWorking)
        XCTAssertTrue(sessions[1].needsYou)
        XCTAssertNil(sessions[1].location)
    }

    func testFiltersSplitWorkingWaitingAndIdleSessions() throws {
        let sessions = try JSONDecoder().decode([AgentSession].self, from: Data(Self.rows.utf8))
        XCTAssertEqual(sessions.filter(AgentFilter.working.matches).map(\.id), ["7-10"])
        XCTAssertEqual(sessions.filter(AgentFilter.needsYou.matches).map(\.id), ["8-10"])
        XCTAssertTrue(sessions.filter(AgentFilter.idle.matches).isEmpty)
        XCTAssertEqual(sessions.filter(AgentFilter.all.matches).count, 2)
    }

    func testUnknownProviderActivityIsVisibleWithoutBeingLabelledIdle() throws {
        let rows = #"[{"id":"kimi-1","provider":"kimi","project":"/work","title":"Kimi","state":"Unknown","explanation":"No verified state markers","location":null}]"#
        let sessions = try JSONDecoder().decode([AgentSession].self, from: Data(rows.utf8))
        XCTAssertEqual(sessions.filter(AgentFilter.all.matches).count, 1)
        XCTAssertEqual(sessions.filter(AgentFilter.unknown.matches).count, 1)
        XCTAssertTrue(sessions.filter(AgentFilter.idle.matches).isEmpty)
        XCTAssertTrue(sessions.filter(AgentFilter.working.matches).isEmpty)
    }

    func testSessionAlertsUseFreshActivityAndRearmAfterKnownChanges() throws {
        let start = Date(timeIntervalSince1970: 100)
        var tracker = AgentNotificationTracker(startedAt: start)
        func sample(_ activity: String?, at seconds: Double, id: String = "7-10") throws -> [AgentNotificationReason] {
            var row: [String: Any] = [
                "id": id, "provider": "codex", "project": "/work/project", "title": "Codex",
                "state": "Opened", "explanation": "Idle", "activityObservedAt": seconds,
                "location": ["id": "pane", "window": "Client", "tab_index": 0, "pane_index": 0]
            ]
            row["activityState"] = activity
            let data = try JSONSerialization.data(withJSONObject: row)
            let session = try JSONDecoder().decode(AgentSession.self, from: data)
            return tracker.observe([session], now: Date(timeIntervalSince1970: seconds + 1)).map { $0.1 }
        }

        XCTAssertEqual(try sample("Working", at: 99), [])
        XCTAssertEqual(try sample("Working", at: 101), [])
        XCTAssertEqual(try sample(nil, at: 101), [])
        XCTAssertEqual(try sample("New reply", at: 106), [.replyReady])
        XCTAssertEqual(try sample("Approval", at: 111), [.approval])
        XCTAssertEqual(try sample("Unknown", at: 116), [])
        XCTAssertEqual(try sample("Approval", at: 121), [])
        XCTAssertEqual(try sample("Working", at: 126), [])
        XCTAssertEqual(try sample("Blocked", at: 131), [.blocked])
        XCTAssertEqual(try sample("Question", at: 151), [])
        XCTAssertEqual(try sample("Working", at: 156), [])
        XCTAssertEqual(try sample("Unknown", at: 161), [])
        XCTAssertEqual(try sample("New reply", at: 166), [])
        XCTAssertEqual(try sample("Approval", at: 171, id: "7-11"), [])
        XCTAssertEqual(try sample("Question", at: 176, id: "7-11"), [.question])
        XCTAssertEqual(try sample("Approval", at: 181, id: "7-11"), [.approval])
        XCTAssertEqual(try sample("New reply", at: 186, id: "7-11"), [.replyReady])
    }

    @MainActor
    func testSessionAlertsKeepReadingAfterMenuCloses() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("engine")
        let stopped = directory.appendingPathComponent("stopped")
        let script = #"""
        #!/bin/sh
        snapshot() {
            timestamp=$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%.6f", time')
            printf '{"protocol":1,"requestID":%s,"kind":"snapshot","observedAt":%s,"sessions":[{"id":"7-10","provider":"codex","project":"/work/project","title":"Codex","state":"%s","explanation":"","activityState":"%s","activityObservedAt":%s,"location":{"id":"pane","window":"Client","tab_index":0,"pane_index":0}}]}\n' "$1" "$timestamp" "$2" "$3" "$timestamp"
        }
        IFS= read -r request || exit 1
        snapshot 1 Working Working
        IFS= read -r request || exit 1
        snapshot 2 Opened 'New reply'
        IFS= read -r request || exit 1
        snapshot 3 Approval Approval
        while IFS= read -r request; do :; done
        touch "$(dirname "$0")/stopped"
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let service = AgentSessionsService(executableURL: executable)
        var alerts: [AgentNotificationReason] = []
        service.setNotificationsEnabled(true) { _, reason in alerts.append(reason) }
        defer { service.setNotificationsEnabled(false); service.stop() }
        for _ in 0..<100 where service.sessions.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(service.sessions.first?.state, "Working")
        XCTAssertTrue(alerts.isEmpty)
        service.start()
        service.stop()
        for _ in 0..<100 where alerts.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(service.isVisible)
        XCTAssertEqual(alerts, [.replyReady])
        service.refresh(force: true)
        for _ in 0..<100 where alerts.count < 2 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(alerts, [.replyReady, .approval])
        service.setNotificationsEnabled(false)
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: stopped.path) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: stopped.path))
    }

    @MainActor
    func testBundledProtocolRefreshJumpFailureAndClose() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("engine")
        // A real pipe consumer exercises framing, independent request IDs and graceful EOF.
        let compact = try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: Data(Self.rows.utf8)))
        let rowJSON = String(decoding: compact, as: UTF8.self)
        let script = """
        #!/bin/sh
        IFS= read -r first || exit 0
        printf '%s\\n' '{"protocol":1,"requestID":1,"kind":"snapshot","observedAt":1800000000,"sessions":\(rowJSON)}'
        IFS= read -r second || exit 0
        printf '%s\\n' '{"protocol":1,"requestID":2,"kind":"jump","error":"Session exited; refresh Agents"}'
        IFS= read -r third || exit 0
        printf '%s\\n' '{"protocol":1,"requestID":3,"kind":"snapshot","error":"iTerm2 unavailable"}'
        while IFS= read -r rest; do :; done
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let service = AgentSessionsService(executableURL: executable)
        defer { service.stop() }
        service.start()
        for _ in 0..<100 where service.sessions.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(service.sessions.count, 2)
        XCTAssertFalse(service.isLoading)
        let contract = try XCTUnwrap(service.contracts.first)
        XCTAssertEqual(contract.pid, 7)
        XCTAssertEqual(contract.workTimeSource, .observed)
        XCTAssertEqual(contract.lastMessageAt, Date(timeIntervalSince1970: 1799999990))
        XCTAssertEqual(contract.state, .working)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let host = NSHostingController(rootView: MenuAgentsSection(service: service).frame(width: 354))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 354, height: 700),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentViewController = host
            host.view.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.view.fittingSize.width, 354, accuracy: 1)
            XCTAssertLessThan(host.view.fittingSize.height, NSScreen.main?.visibleFrame.height ?? 1000)
            if let capture = ProcessInfo.processInfo.environment["FLEET_UI_CAPTURE_DIR"],
               let bitmap = host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds) {
                host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to:
                    URL(fileURLWithPath: capture).appendingPathComponent("agents-\(appearance.rawValue).png"))
            }
            window.contentViewController = nil
        }
        let session = try XCTUnwrap(service.sessions.first)
        service.jump(to: session)
        for _ in 0..<100 where service.jumpError == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(service.jumpError, "Session exited; refresh Agents")
        XCTAssertNil(service.jumpingID)
        XCTAssertTrue(service.isVisible, "Jump must keep the overview alive")
        service.refresh(force: true)
        for _ in 0..<100 where service.error == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(service.error, "iTerm2 unavailable")
        XCTAssertTrue(service.isStale)
        XCTAssertEqual(service.contracts.first?.state, .stale)
        XCTAssertNil(service.contracts.first?.workingDuration(at: Date()))
        XCTAssertEqual(service.sessions.count, 2, "An unavailable scan must retain the last snapshot")
        service.stop()
        XCTAssertFalse(service.isVisible)
        XCTAssertEqual(service.sessions.count, 2, "Keep the last snapshot for reopening")
    }

    @MainActor
    func testMissingEngineIsVisibleAndDoesNotInventEmptySuccess() {
        let service = AgentSessionsService(executableURL: URL(fileURLWithPath: "/missing/fleet-session-engine"))
        service.start()
        defer { service.stop() }
        XCTAssertNotNil(service.error)
        XCTAssertTrue(service.isStale)
        XCTAssertFalse(service.isLoading)
    }
}
