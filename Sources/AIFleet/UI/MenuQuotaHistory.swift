import AppKit
import SwiftUI

@MainActor
final class MenuQuotaHistory: NSObject, ObservableObject, NSPopoverDelegate {
    static let windowIdentifier = NSUserInterfaceItemIdentifier("ai-fleet-quota-history")

    @Published private(set) var presented: String?
    private var popover: NSPopover?
    private var content: QuotaPopoverTarget?
    private var sizeObservation: NSKeyValueObservation?
    private var outsideClickMonitor: Any?

    func toggle(_ target: QuotaHistoryTarget, anchoredTo anchor: NSView, openStatistics: @escaping () -> Void) {
        if presented == target.id {
            dismiss()
            return
        }
        guard let window = anchor.window else { return }
        dismiss()

        let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        let width = min(500, (visible?.width ?? 536) - 36)
        let maxHeight = min(440, (visible?.height ?? 484) - 44)
        let content = QuotaPopoverTarget(target)
        let host = NSHostingController(rootView: QuotaPopoverContent(target: content, width: width, maxHeight: maxHeight,
            openInStatistics: { [weak self] request in
                self?.dismiss()
                QuotaHistoryNavigation.shared.request = request
                openStatistics()
            }))
        host.sizingOptions = [.preferredContentSize]

        let popover = NSPopover()
        popover.animates = false
        popover.behavior = .applicationDefined
        popover.delegate = self
        popover.contentViewController = host
        popover.contentSize = NSSize(width: width, height: maxHeight)
        self.popover = popover
        self.content = content
        presented = target.id

        // The bounded scroll view measures the content at the given width, even
        // when the existing window is shorter than the newly selected chart.
        sizeObservation = host.observe(\.preferredContentSize) { [weak self, weak popover] host, _ in
            let height = ceil(host.preferredContentSize.height)
            Task { @MainActor in
                guard let self, let popover, self.popover === popover, height > 1 else { return }
                let size = NSSize(width: width, height: min(maxHeight, height))
                if popover.contentSize != size { popover.contentSize = size }
            }
        }
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minX)
        host.view.window?.identifier = Self.windowIdentifier
        monitorClicks(in: window, outside: anchor)
    }

    func update(_ target: QuotaHistoryTarget) {
        guard presented == target.id else { return }
        content?.target = target
    }

    func dismiss(id: String? = nil) {
        guard id == nil || presented == id else { return }
        let closing = popover
        clear()
        closing?.close()
    }

    func popoverDidClose(_ notification: Notification) {
        guard let closed = notification.object as? NSPopover, closed === popover else { return }
        clear()
    }

    private func monitorClicks(in window: NSWindow, outside anchor: NSView) {
        outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) {
            [weak self, weak window, weak anchor] event in
            if let window, let anchor, event.window === window,
               !anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil)) {
                self?.dismiss()
            }
            return event
        }
    }

    private func clear() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
        sizeObservation = nil
        popover = nil
        content = nil
        presented = nil
    }
}

struct MenuQuotaHistoryButton: View {
    let target: QuotaHistoryTarget
    @ObservedObject var presentation: MenuQuotaHistory
    let openStatistics: () -> Void
    @State private var anchor = NSView()

    var body: some View {
        Button {
            presentation.toggle(target, anchoredTo: anchor, openStatistics: openStatistics)
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
        .background(QuotaPopoverAnchor(view: anchor).allowsHitTesting(false))
        .onChange(of: target) { presentation.update($0) }
        .onDisappear { presentation.dismiss(id: target.id) }
    }
}

@MainActor
private final class QuotaPopoverTarget: ObservableObject {
    @Published var target: QuotaHistoryTarget

    init(_ target: QuotaHistoryTarget) { self.target = target }
}

private struct QuotaPopoverContent: View {
    @ObservedObject var target: QuotaPopoverTarget
    let width: CGFloat
    let maxHeight: CGFloat
    let openInStatistics: (QuotaHistoryRequest) -> Void

    var body: some View {
        MenuRowsViewport(maxHeight: maxHeight) {
            QuotaHistoryView(targets: [target.target], openInStatistics: openInStatistics)
                .padding(10)
                .frame(width: width)
        }
        .frame(width: width)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct QuotaPopoverAnchor: NSViewRepresentable {
    let view: NSView

    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
