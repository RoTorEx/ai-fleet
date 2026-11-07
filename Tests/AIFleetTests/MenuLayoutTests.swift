import AppKit
import SwiftUI
import XCTest
@testable import AIFleet

final class MenuLayoutTests: XCTestCase {
    func testMenuPanelHangsBelowStatusItemAndStaysOnScreen() {
        let screen = NSRect(x: 0, y: 0, width: 1512, height: 944)
        let item = NSRect(x: 1200, y: 945, width: 18, height: 24)

        let centered = FleetMenuPanel.frame(contentSize: NSSize(width: 354, height: 500), below: item, in: screen)
        XCTAssertEqual(centered.midX, item.midX, accuracy: 1)
        XCTAssertEqual(centered.maxY, item.minY - FleetMenuPanel.gap, accuracy: 1)

        let edge = NSRect(x: 1490, y: 945, width: 18, height: 24)
        let clamped = FleetMenuPanel.frame(contentSize: NSSize(width: 520, height: 500), below: edge, in: screen)
        XCTAssertEqual(clamped.maxX, screen.maxX - FleetMenuPanel.screenMargin, accuracy: 1)
        XCTAssertEqual(clamped.width, 520)

        let tall = FleetMenuPanel.frame(contentSize: NSSize(width: 354, height: 2000), below: item, in: screen)
        XCTAssertGreaterThanOrEqual(tall.minY, screen.minY + FleetMenuPanel.screenMargin - 1)
    }

    @MainActor
    func testClosedMenuHoldsNoContentAndOpensAtFullSizeInOneLayout() {
        let screen = FleetMenuScreen()
        let service = StatusService(session: URLSession(configuration: .ephemeral))
        let host = NSHostingController(rootView: FleetMenuRoot(screen: screen, agents: AgentSessionsService(), service: service,
            openSettings: {}, openStatistics: {}))
        host.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 354, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = host
        defer { window.contentViewController = nil }
        host.view.layoutSubtreeIfNeeded()
        XCTAssertLessThan(host.view.fittingSize.height, 2)
        // showPanel measures right after opening; the first layout must already be the menu.
        screen.isOpen = true
        host.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.view.fittingSize.width, FleetMenuLayout.width, accuracy: 1)
        XCTAssertGreaterThan(host.view.fittingSize.height, 250)
        screen.isOpen = false
        host.view.layoutSubtreeIfNeeded()
        XCTAssertLessThan(host.view.fittingSize.height, 2)
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
    func testLeadingMarksShareOneVisualSize() throws {
        func ink(_ mark: String) throws -> CGRect {
            let renderer = ImageRenderer(content: RowMark(mark: mark).foregroundColor(.black)
                .frame(width: FleetRowMetrics.markWidth))
            renderer.scale = 4
            let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
            var minX = bitmap.pixelsWide, minY = bitmap.pixelsHigh, maxX = -1, maxY = -1
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.2 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            XCTAssertGreaterThan(maxX, minX, mark)
            return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
                .applying(CGAffineTransform(scaleX: 0.25, y: 0.25))
        }
        let cross = try ink("×")
        let right = try ink("→"), down = try ink("↓")
        XCTAssertEqual(right.width, down.height, accuracy: 0.5, "→ must be as long as ↓")
        for mark in ["→", "↓", "•", "?"] {
            let box = try ink(mark)
            XCTAssertEqual(box.midY, cross.midY, accuracy: 0.5, "\(mark) must share the × optical center")
        }
    }

    @MainActor
    func testMenuFitsNativePopoverInBothAppearances() async throws {
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
                AIFleetMenuView(openSettings: {}, openStatistics: {}, screen: FleetMenuScreen(), agents: AgentSessionsService())
                    .environmentObject(service).environmentObject(AppSettings.shared)
                    .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light))
            host.sizingOptions = [.preferredContentSize]
            host.view.appearance = NSAppearance(named: appearance)
            let popover = NSPopover()
            popover.animates = false
            popover.appearance = NSAppearance(named: appearance)
            popover.contentViewController = host
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
            defer { popover.performClose(nil) }
            for _ in 0..<30 {
                host.view.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertTrue(popover.isShown)
            XCTAssertEqual(host.view.fittingSize.width, FleetMenuLayout.width, accuracy: 1)
            XCTAssertGreaterThan(host.view.fittingSize.height, 250)
            if let directory = ProcessInfo.processInfo.environment["FLEET_UI_CAPTURE_DIR"],
               let bitmap = host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds) {
                // Preview menu content without depending on screen-recording access or display geometry.
                host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to:
                    URL(fileURLWithPath: directory).appendingPathComponent("native-menu-\(appearance.rawValue).png"))
            }
            popover.performClose(nil)
        }
    }

    @MainActor
    func testArrowsCycleThroughTabsAndTheLastTabIsRemembered() {
        let saved = UserDefaults.standard.string(forKey: "menu.tab")
        defer { UserDefaults.standard.set(saved, forKey: "menu.tab") }
        let screen = FleetMenuScreen()
        screen.tab = .providers
        screen.step(-1)
        XCTAssertEqual(screen.tab, .processes, "← on the first tab wraps to the last")
        screen.step(1)
        XCTAssertEqual(screen.tab, .providers, "→ on the last tab wraps to the first")
        screen.step(1)
        XCTAssertEqual(FleetMenuScreen().tab, .agents)
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
