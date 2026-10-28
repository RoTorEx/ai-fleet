import AppKit
import SwiftUI
import XCTest
@testable import AIFleet

final class MenuLayoutTests: XCTestCase {
    @MainActor
    func testCurrentAndLowestMarksHaveEqualRenderedArrowLengths() throws {
        func inkSize(_ kind: FleetMark.Kind) throws -> CGSize {
            let renderer = ImageRenderer(content: FleetMark(kind: kind).foregroundColor(.black))
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
        let current = try inkSize(.current)
        let lowest = try inkSize(.lowest)
        XCTAssertEqual(current.width, lowest.height, accuracy: 1, "Arrow lengths must match after rotation")
        XCTAssertEqual(current.height, lowest.width, accuracy: 1, "Arrowhead spans must match after rotation")
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
                AIFleetMenuView(openSettings: {}, openStatistics: {})
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
            XCTAssertEqual(host.view.fittingSize.width, 354, accuracy: 1)
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
