import AppKit
import SwiftUI
import UserNotifications
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

    private func alert(_ reason: AgentNotificationReason, title: String = "⠂ Fix sign-in (codex)", tab: String? = "Authentication",
                       pane: Int = 0, text: String = "", namesWindow: Bool = false) throws -> AgentAlert {
        let tabField = tab.map { #""tab":"\#($0)","# } ?? ""
        let row = #"{"id":"7-10","provider":"codex","project":"/work/Thira","title":"\#(title)","state":"Opened","explanation":"",\#(text)"location":{"id":"pane","window":"Work",\#(tabField)"tab_index":2,"pane_index":\#(pane)}}"#
        let session = try JSONDecoder().decode(AgentSession.self, from: Data(row.utf8))
        return AgentAlert(id: "a", session: session, reason: reason, namesWindow: namesWindow, date: Date())
    }

    func testAlertTitleIsGlyphAndNameAndTheMetaLineLeadsWithTheType() throws {
        let text = try alert(.replyReady).text(showText: false)
        XCTAssertEqual(text.title, "✅ Fix sign-in")
        XCTAssertEqual(text.subtitle, "")
        XCTAssertEqual(text.body, "Done · Thira · tab 3 · Codex", "Without message text the meta line is the body")
    }

    func testAlertNameFallsBackToTabThenProjectAndMetaAddsPaneAndWindowOnlyWhenNeeded() throws {
        XCTAssertEqual(try alert(.approval, title: "(codex)", tab: "Investigate sign-in").text(showText: false).title,
                       "✋ Investigate sign-in")
        let unnamed = try alert(.approval, title: "(codex)", tab: nil, pane: 1)
        XCTAssertEqual(unnamed.text(showText: false).title, "✋ Thira")
        XCTAssertEqual(unnamed.meta, "Approval · tab 3 · pane 2 · Codex", "The project is not repeated once it is the name")
        XCTAssertEqual(try alert(.question, namesWindow: true).meta, "Question · Thira · tab 3 · Work · Codex")
    }

    func testAlertNameDropsCodexStatusPrefixAndProjectFolderSuffix() throws {
        XCTAssertEqual(try alert(.approval, title: "[ ! ] Action Required | Check BMW documents | Thira (codex)").name,
                       "Check BMW documents")
        XCTAssertEqual(try alert(.replyReady, title: "Check BMW documents | Thira").name, "Check BMW documents")
        XCTAssertEqual(try alert(.replyReady, title: "Compare A | B").name, "Compare A | B", "Only the project folder is dropped")
        XCTAssertEqual(try alert(.replyReady, title: "[draft] notes").name, "[draft] notes")
    }

    func testMessageTextIsOptInOrderedByWhatNeedsActionAndClipped() throws {
        let request = Array(repeating: "refactor", count: 20).joined(separator: " ")
        let reply = "## Result\\n**Done** with `make check`. " + Array(repeating: "detail", count: 60).joined(separator: " ")
        let fields = #""request":"\#(request)","answer":"\#(reply)","#
        let done = try alert(.replyReady, text: fields)
        XCTAssertEqual(done.text(showText: false).body, done.meta, "Session text stays out unless enabled")
        XCTAssertEqual(done.text(showText: true).subtitle, done.meta)

        let lines = done.text(showText: true).body.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasPrefix("› refactor refactor") && lines[0].hasSuffix("…"))
        XCTAssertLessThanOrEqual(lines[0].count, AgentAlert.requestLimit + 3)
        XCTAssertTrue(lines[1].hasPrefix("Result Done with make check. detail"), lines[1])
        XCTAssertLessThanOrEqual(lines[1].count, AgentAlert.replyLimit + 1)

        let question = try alert(.question, text: fields).text(showText: true).body
        XCTAssertTrue(question.hasPrefix("Result Done"), "A question leads with the agent's text")
        XCTAssertTrue(question.components(separatedBy: "\n").last?.hasPrefix("› ") == true)
        XCTAssertEqual(try alert(.approval).text(showText: true).body, "Approval · Thira · tab 3 · Codex",
                       "No bound transcript leaves only the meta line")
    }

    func testAlertStaysUntilItsSessionIsOpenedMovesOnOrEnds() throws {
        func state(_ state: String, id: String = "7-10") throws -> [AgentSession] {
            let row = #"{"id":"\#(id)","provider":"codex","project":"/work","title":"Codex","state":"\#(state)","explanation":"","location":null}"#
            return [try JSONDecoder().decode(AgentSession.self, from: Data(row.utf8))]
        }
        let done = try alert(.replyReady), question = try alert(.question)
        XCTAssertTrue(done.isCurrent(in: try state("New reply")))
        XCTAssertFalse(done.isCurrent(in: try state("Opened")), "Viewing the pane ends a Done alert")
        XCTAssertFalse(done.isCurrent(in: try state("Working")), "So does new work")
        XCTAssertFalse(done.isCurrent(in: try state("New reply", id: "9-1")), "And the session ending")
        XCTAssertTrue(question.isCurrent(in: try state("Question")), "A question waits however often it is viewed")
        XCTAssertFalse(question.isCurrent(in: try state("Working")))
        for unproven in ["Unknown", "Untracked"] {
            XCTAssertTrue(question.isCurrent(in: try state(unproven)), "\(unproven) is no evidence the user acted")
        }
    }

    func testNotificationClicksRouteToPaneHistoryOrProviders() {
        let route = StatusService.notificationAction
        let banner = UNNotificationDefaultActionIdentifier
        XCTAssertEqual(route(banner, "agent", "7-10", "a"), .openSession("7-10"))
        XCTAssertEqual(route(StatusService.openAction, "agent", "7-10", "a"), .openSession("7-10"))
        XCTAssertEqual(route(StatusService.historyAction, "agent", "7-10", "a"), .history("a"))
        XCTAssertEqual(route(banner, nil, "7-10", nil), .openSession("7-10"), "Alerts delivered before this layout still jump")
        XCTAssertEqual(route(banner, "quota", nil, nil), .providers)
        XCTAssertEqual(route(banner, "test", nil, nil), .menu)
        XCTAssertNil(route(UNNotificationDismissActionIdentifier, "agent", "7-10", "a"))
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
        IFS= read -r request || exit 1
        snapshot 4 Working Working
        while IFS= read -r request; do :; done
        touch "$(dirname "$0")/stopped"
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let service = AgentSessionsService(executableURL: executable)
        var alerts: [AgentNotificationReason] = []
        var retired: [String] = []
        service.onAlertsRetired = { retired += $0 }
        service.setNotificationsEnabled(true) { alerts.append($0.reason) }
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
        XCTAssertEqual(service.alerts.map(\.reason), [.approval], "A session keeps only its newest alert")
        XCTAssertTrue(retired.isEmpty, "A replaced alert reuses its notification instead of withdrawing it")
        service.start()
        service.showHistory(highlighting: service.alerts.first?.id)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let host = NSHostingController(rootView: MenuAgentsSection(service: service).frame(width: 354))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 354, height: 700),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentViewController = host
            host.view.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(host.view.fittingSize.height, 80, "The chip row, the alert and the footer are laid out")
            if let capture = ProcessInfo.processInfo.environment["FLEET_UI_CAPTURE_DIR"],
               let bitmap = host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds) {
                host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to:
                    URL(fileURLWithPath: capture).appendingPathComponent("history-\(appearance.rawValue).png"))
            }
            window.contentViewController = nil
        }
        service.stop()
        XCTAssertNil(service.highlightedAlertID, "Closing the menu drops the highlight")
        service.refresh(force: true)
        for _ in 0..<100 where retired.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(retired, ["7-10"], "New work withdraws the delivered notification")
        XCTAssertTrue(service.alerts.isEmpty)
        service.setNotificationsEnabled(false)
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: stopped.path) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: stopped.path))
    }

    @MainActor
    func testNotificationJumpResolvesExactSessionWithMenuClosed() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("engine")
        let rows = try JSONSerialization.jsonObject(with: Data(Self.rows.utf8))
        let rowJSON = String(decoding: try JSONSerialization.data(withJSONObject: rows), as: UTF8.self)
        let script = #"""
        #!/bin/sh
        IFS= read -r request || exit 1
        printf '%s\n' '{"protocol":1,"requestID":1,"kind":"snapshot","sessions":\#(rowJSON)}'
        IFS= read -r request || exit 0
        case "$request" in
            *'"sessionId":"7-10"'*) printf '%s\n' '{"protocol":1,"requestID":2,"kind":"jump","sessionID":"7-10"}' ;;
            *) printf '%s\n' '{"protocol":1,"requestID":2,"kind":"jump","error":"Wrong session"}' ;;
        esac
        while IFS= read -r request; do :; done
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let live = AgentSessionsService(executableURL: executable)
        var didOpen = false
        live.jumpFromNotification("7-10") { error in
            XCTAssertNil(error)
            didOpen = true
        }
        for _ in 0..<100 where !didOpen { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(didOpen)
        XCTAssertFalse(live.isVisible)
        XCTAssertNil(live.jumpingID)

        let expired = AgentSessionsService(executableURL: executable)
        var error: String?
        expired.jumpFromNotification("7-09") { error = $0 }
        for _ in 0..<100 where error == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(error, "This session has ended or its iTerm2 pane could not be found.")
        XCTAssertNil(expired.selectedID)
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
