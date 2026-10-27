import AppKit
import SwiftUI
import XCTest
@testable import AIFleet

final class AgentSessionsTests: XCTestCase {
    private static let rows = #"""
    [
      {"id":"7-10","provider":"codex","project":"/work/client/project","title":"Review authentication","state":"Working","explanation":"Working","location":{"id":"pane-7","window":"Client","tab_index":1,"pane_index":0}},
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
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let host = NSHostingController(rootView: AgentsView(service: service, back: {}))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 700),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentViewController = host
            host.view.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.view.fittingSize.width, 520, accuracy: 1)
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
