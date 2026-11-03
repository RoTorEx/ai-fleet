import AppKit
import SwiftUI
import XCTest
@testable import AIFleet

final class MenuLayoutTests: XCTestCase {
    @MainActor
    func testResetHoverKeepsBaselineAndFollowingRowStable() throws {
        for scheme in [ColorScheme.light, .dark] {
            var sizes: [CGSize] = []
            for hovered in [false, true, false] {
                let view = VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("5h  100%")
                        ResetTimeCell(dateText: "9 Nov at 18:54", countdown: "6d 03h 04m 05s", hovered: hovered)
                    }
                    Text("Following provider")
                }.font(.system(size: 11)).environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: view)
                let image = try XCTUnwrap(renderer.cgImage)
                sizes.append(CGSize(width: image.width, height: image.height))
            }
            XCTAssertEqual(sizes[0], sizes[1])
            XCTAssertEqual(sizes[0], sizes[2])
        }
    }

    func testSessionTitleRemovesAnnotationsButPreservesTaskWords() {
        XCTAssertEqual(agentSessionDisplayTitle("Codex · Fix login (codex)", provider: "codex"), "Fix login")
        XCTAssertEqual(agentSessionDisplayTitle("Fix Codex login", provider: "codex"), "Fix Codex login")
        XCTAssertEqual(agentSessionDisplayTitle("Claude Code | Review", provider: "claude"), "Review")
    }

    @MainActor
    func testNativeHelpOpensWithoutWindowAnimationAndClosesInBothAppearances() async throws {
        let previous = NSApplication.shared.appearance
        defer { NSApplication.shared.appearance = previous }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            NSApplication.shared.appearance = NSAppearance(named: appearance)
            let state = HelpPopoverState()
            let host = NSHostingController(rootView: LiveHelpPopover(state: state))
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 100, height: 50),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentViewController = host
            window.orderFrontRegardless()
            defer { state.shown = false; window.orderOut(nil); window.contentViewController = nil }
            for _ in 0..<10 { try await Task.sleep(nanoseconds: 10_000_000) }
            state.shown = true
            for _ in 0..<15 { try await Task.sleep(nanoseconds: 10_000_000) }
            let child = try XCTUnwrap(NSApplication.shared.windows.first {
                $0.identifier?.rawValue == "ai-fleet-child-popover" && $0.isVisible
            })
            XCTAssertEqual(child.animationBehavior, .none)
            XCTAssertGreaterThan(child.frame.width, 200)
            state.shown = false
            for _ in 0..<15 { try await Task.sleep(nanoseconds: 10_000_000) }
            XCTAssertFalse(child.isVisible)
        }
    }

    @MainActor
    func testBlockedSwitchDetailsExpandAndCollapseInBothAppearances() async throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let state = SwitchNoticeState()
            let host = NSHostingController(rootView: LiveSwitchNotice(state: state)
                .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light))
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 280, height: 100),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentViewController = host
            window.orderFrontRegardless()
            defer { window.orderOut(nil); window.contentViewController = nil }
            var collapsedHeight: CGFloat = 0
            for expanded in [false, true, false] {
                state.expanded = expanded
                for _ in 0..<10 {
                    host.view.layoutSubtreeIfNeeded()
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                let size = host.view.fittingSize
                XCTAssertEqual(size.width, 280, accuracy: 1)
                if expanded {
                    XCTAssertGreaterThan(size.height, collapsedHeight + 60)
                } else if collapsedHeight == 0 {
                    collapsedHeight = size.height
                    XCTAssertLessThan(collapsedHeight, 100)
                } else {
                    XCTAssertEqual(size.height, collapsedHeight, accuracy: 1)
                }
                if let directory = ProcessInfo.processInfo.environment["FLEET_UI_CAPTURE_DIR"] {
                    window.setContentSize(size)
                    host.view.layoutSubtreeIfNeeded()
                    if let bitmap = host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds) {
                        host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
                        let name = "switch-notice-\(appearance.rawValue)-\(expanded ? "expanded" : "collapsed").png"
                        try bitmap.representation(using: .png, properties: [:])?.write(to:
                            URL(fileURLWithPath: directory).appendingPathComponent(name))
                    }
                }
            }
        }
    }

    @MainActor
    func testCurrentAndLowestMarksHaveEqualRenderedArrowLengths() throws {
        func inkSize(_ kind: FleetMark.Kind, size: CGFloat) throws -> CGSize {
            let renderer = ImageRenderer(content: FleetMark(kind: kind, size: size).foregroundColor(.black))
            renderer.scale = 4
            let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
            var minX = bitmap.pixelsWide, minY = bitmap.pixelsHigh, maxX = -1, maxY = -1
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.2 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            XCTAssertGreaterThan(maxX, minX)
            XCTAssertGreaterThan(maxY, minY)
            return CGSize(width: maxX - minX + 1, height: maxY - minY + 1)
        }
        for size: CGFloat in [10.5, 13] {
            let current = try inkSize(.current, size: size)
            let lowest = try inkSize(.lowest, size: size)
            XCTAssertEqual(current.width, lowest.height, accuracy: 1, "Arrow lengths must match after rotation")
            XCTAssertEqual(current.height, lowest.width, accuracy: 1, "Arrowhead spans must match after rotation")
        }
    }

    @MainActor
    func testMenuFitsCompactPanelInBothAppearances() async throws {
        let previousAppearance = NSApplication.shared.appearance
        defer { NSApplication.shared.appearance = previousAppearance }
        let anchor = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 100, height: 40),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let button = NSButton(frame: NSRect(x: 20, y: 10, width: 30, height: 20))
        anchor.contentView?.addSubview(button)
        anchor.orderFrontRegardless()
        defer { anchor.orderOut(nil) }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            NSApplication.shared.appearance = NSAppearance(named: appearance)
            anchor.appearance = NSAppearance(named: appearance)
            let service = StatusService(session: URLSession(configuration: .ephemeral))
            let host = NSHostingController(rootView:
                AIFleetMenuView(openSettings: {}, openStatistics: {})
                    .environmentObject(service).environmentObject(AppSettings.shared)
                    .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light))
            host.sizingOptions = [.preferredContentSize]
            host.view.appearance = NSAppearance(named: appearance)
            let panel = FleetMenuPanel()
            panel.appearance = NSAppearance(named: appearance)
            panel.contentViewController = host
            panel.setContentSize(host.view.fittingSize)
            panel.orderFrontRegardless()
            defer { panel.orderOut(nil) }
            for _ in 0..<30 {
                host.view.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertTrue(panel.isVisible)
            XCTAssertEqual(panel.animationBehavior, .none)
            XCTAssertTrue(panel.styleMask.contains(.borderless))
            XCTAssertEqual(host.view.fittingSize.width, 320, accuracy: 1)
            XCTAssertGreaterThan(host.view.fittingSize.height, 150)
            if let directory = ProcessInfo.processInfo.environment["FLEET_UI_CAPTURE_DIR"],
               let bitmap = host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds) {
                // Preview menu content without depending on screen-recording access or display geometry.
                host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to:
                    URL(fileURLWithPath: directory).appendingPathComponent("native-menu-\(appearance.rawValue).png"))
            }
            panel.orderOut(nil)
        }
    }

    @MainActor
    func testRowsFitContentAndScrollOnlyAfterReachingCap() {
        let rows = Rows()
        // Use observable content so the same open host reacts to additions/removals.
        let live = NSHostingController(rootView: LiveRows(rows: rows))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 354, height: 340),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = live
        defer { window.contentViewController = nil }
        func settle() {
            for _ in 0..<10 {
                live.view.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
        }
        settle()
        XCTAssertEqual(live.view.fittingSize.height, 184, accuracy: 1)
        rows.count = 12
        settle()
        XCTAssertEqual(live.view.fittingSize.height, 340, accuracy: 1)
        rows.count = 4
        settle()
        XCTAssertEqual(live.view.fittingSize.height, 184, accuracy: 1)
    }
}

private final class HelpPopoverState: ObservableObject {
    @Published var shown = false
}

private struct LiveHelpPopover: View {
    @ObservedObject var state: HelpPopoverState
    var body: some View {
        Text("Account").frame(width: 100, height: 50)
            .instantPopover(isPresented: $state.shown) {
                Text("Account subscription information").frame(width: 220).padding(16)
            }
    }
}

private final class SwitchNoticeState: ObservableObject {
    @Published var expanded = false
}

private struct LiveSwitchNotice: View {
    @ObservedObject var state: SwitchNoticeState
    var body: some View {
        CodexSwitchBlockedNotice(label: "Codex (α)", processIDs: [2158, 2184, 2902, 3457, 4331, 7834],
                                 isExpanded: $state.expanded)
            .padding(10).frame(width: 280)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}

private final class Rows: ObservableObject {
    @Published var count = 4
}

private struct LiveRows: View {
    @ObservedObject var rows: Rows
    var body: some View {
        MenuRowsViewport(maxHeight: 340) {
            VStack(spacing: 8) {
                ForEach(0..<rows.count, id: \.self) { _ in
                    Color.clear.frame(height: 40)
                }
            }
        }
        .frame(width: 354)
        .fixedSize(horizontal: false, vertical: true)
    }
}
