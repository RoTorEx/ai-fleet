import AppKit
import SwiftUI

@MainActor
final class MenuQuotaHistory: ObservableObject {
    static let windowIdentifier = NSUserInterfaceItemIdentifier("ai-fleet-quota-history")
    @Published private(set) var presented: String?
    private var pinned = false
    private var pending: DispatchWorkItem?

    func hoverIcon(_ inside: Bool, id: String) {
        if inside {
            guard !pinned else { return }
            pending?.cancel()
            guard presented != id else { return }
            schedule(after: 0.2) { $0.presented = id }
        } else if !pinned {
            pending?.cancel()
            if presented == id { leave(id: id) }
        }
    }

    func hoverPanel(_ inside: Bool, id: String) {
        guard presented == id, !pinned else { return }
        if inside { pending?.cancel() }
        else { leave(id: id) }
    }

    func toggle(_ id: String) {
        pending?.cancel()
        if presented == id, pinned {
            dismiss()
        } else {
            pinned = true
            presented = id
        }
    }

    func dismiss(id: String? = nil) {
        guard id == nil || presented == id else { return }
        pending?.cancel()
        pinned = false
        presented = nil
    }

    private func leave(id: String) {
        schedule(after: 0.24) { $0.dismiss(id: id) }
    }

    private func schedule(after delay: TimeInterval, _ action: @escaping (MenuQuotaHistory) -> Void) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            if let self { action(self) }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
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
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(presentation.presented == target.id ? Color.primary : Color.secondary)
                .frame(width: 23, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(target.label) quota history")
        .accessibilityIdentifier("quota-history-\(target.id)")
        .onHover { presentation.hoverIcon($0, id: target.id) }
        .popover(isPresented: Binding(get: { presentation.presented == target.id },
            set: { if !$0 { presentation.dismiss(id: target.id) } }), arrowEdge: .leading) {
            let visible = NSApp.keyWindow?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ScrollView {
                QuotaHistoryView(targets: [target], openInStatistics: { request in
                    presentation.dismiss()
                    QuotaHistoryNavigation.shared.request = request
                    openStatistics()
                })
                .padding(14)
            }
            .frame(width: min(655, (visible?.width ?? 690) - 30),
                   height: min(545, (visible?.height ?? 600) - 50))
            .background(Color(nsColor: .windowBackgroundColor))
            .background(QuotaPopoverWindowMarker())
            .onHover { presentation.hoverPanel($0, id: target.id) }
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
