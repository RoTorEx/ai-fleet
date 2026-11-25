import AppKit
import SwiftUI

@MainActor
final class MenuQuotaHistory: ObservableObject {
    static let windowIdentifier = NSUserInterfaceItemIdentifier("ai-fleet-quota-history")
    @Published private(set) var presented: String?

    func toggle(_ id: String) {
        presented = presented == id ? nil : id
    }

    func dismiss(id: String? = nil) {
        guard id == nil || presented == id else { return }
        presented = nil
    }
}

struct MenuQuotaHistoryButton: View {
    let target: QuotaHistoryTarget
    @ObservedObject var presentation: MenuQuotaHistory
    let openStatistics: () -> Void

    var body: some View {
        Button {
            presentation.toggle(target.id)
        } label: {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(presentation.presented == target.id ? Color.primary : Color.secondary)
                .frame(width: 23, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(target.label) quota history")
        .accessibilityIdentifier("quota-history-\(target.id)")
        .popover(isPresented: Binding(get: { presentation.presented == target.id },
            set: { if !$0 { presentation.dismiss(id: target.id) } }), arrowEdge: .leading) {
            let visible = NSApp.keyWindow?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            let history = QuotaHistoryView(targets: [target], openInStatistics: { request in
                presentation.dismiss()
                QuotaHistoryNavigation.shared.request = request
                openStatistics()
            })
            .padding(10)
            ViewThatFits(in: .vertical) {
                history.fixedSize(horizontal: false, vertical: true)
                ScrollView { history }
            }
            .frame(width: min(500, (visible?.width ?? 530) - 30))
            .frame(maxHeight: min(420, (visible?.height ?? 470) - 50))
            .background(Color(nsColor: .windowBackgroundColor))
            .background(QuotaPopoverWindowMarker())
        }
        .onDisappear { presentation.dismiss(id: target.id) }
    }
}

private struct QuotaPopoverWindowMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> Marker { Marker() }
    func updateNSView(_ view: Marker, context: Context) {}

    final class Marker: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.identifier = MenuQuotaHistory.windowIdentifier
        }
    }
}
