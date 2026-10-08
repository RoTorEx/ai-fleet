import AppKit
import SwiftUI
import XCTest
@testable import AIFleet

final class MenuLayoutTests: XCTestCase {
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
