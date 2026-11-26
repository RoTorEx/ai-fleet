import AppKit
import SwiftUI

@MainActor
final class MenuQuotaHistory: ObservableObject {
    static let windowIdentifier = NSUserInterfaceItemIdentifier("ai-fleet-quota-history")

    @Published private(set) var presented: String?
    private var panel: QuotaPopoverPanel?
    private var content: QuotaPopoverTarget?
    private var contentHeight: CGFloat?
    private weak var anchor: NSView?
    private let chartAnchors = NSHashTable<NSView>.weakObjects()
    private var windowObservers: [NSObjectProtocol] = []
    private var outsideClickMonitor: Any?

    func toggle(_ target: QuotaHistoryTarget, anchoredTo anchor: NSView, openStatistics: @escaping () -> Void) {
        if presented == target.id {
            dismiss()
            return
        }
        guard let owner = anchor.window, let visible = owner.screen?.visibleFrame ?? NSScreen.main?.visibleFrame,
              let source = sourceRect(for: anchor),
              let placement = QuotaPopoverPlacement(anchor: source, screen: visible, contentHeight: visible.height,
                                                    preferredTop: owner.frame.maxY) else { return }
        if let panel, panel.parent === owner, let content {
            self.anchor = anchor
            content.selection = nil
            content.target = target
            presented = target.id
            reposition()
            return
        }
        dismiss()

        let content = QuotaPopoverTarget(target, viewport: placement.viewport)
        let host = NSHostingView(rootView: QuotaPopoverContent(
            content: content,
            openInStatistics: { [weak self] request in
                self?.dismiss()
                QuotaHistoryNavigation.shared.request = request
                openStatistics()
            },
            onContentHeightChange: { [weak self, weak content] height in
                Task { @MainActor in
                    guard let self, let content, self.content === content, height > 1 else { return }
                    self.contentHeight = height
                    self.reposition()
                    self.panel?.alphaValue = 1
                }
            }
        ))
        host.sizingOptions = []
        let panel = QuotaPopoverPanel(content: host)
        panel.identifier = Self.windowIdentifier
        panel.level = owner.level
        panel.alphaValue = 0
        self.panel = panel
        self.content = content
        self.anchor = anchor
        presented = target.id

        monitorWindow(owner)
        monitorClicks(in: owner)
        // Lay out the hosted view invisibly until SwiftUI measures the chart stack.
        panel.layout(placement)
        owner.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
    }

    func register(_ chartAnchor: NSView) { chartAnchors.add(chartAnchor) }

    func unregister(_ chartAnchor: NSView) { chartAnchors.remove(chartAnchor) }

    func update(_ target: QuotaHistoryTarget) {
        guard presented == target.id else { return }
        content?.target = target
    }

    func reposition(id: String? = nil) {
        guard id == nil || presented == id, let panel, let content else { return }
        guard let anchor, let owner = anchor.window, let source = sourceRect(for: anchor),
              let visible = owner.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else {
            dismiss()
            return
        }
        guard let placement = QuotaPopoverPlacement(anchor: source, screen: visible,
                                                    contentHeight: contentHeight ?? visible.height,
                                                    preferredTop: owner.frame.maxY) else {
            dismiss()
            return
        }
        if content.viewport != placement.viewport { content.viewport = placement.viewport }
        panel.layout(placement)
    }

    func dismiss(id: String? = nil) {
        guard id == nil || presented == id else { return }
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        windowObservers.removeAll()
        let closing = panel
        panel = nil
        content = nil
        contentHeight = nil
        anchor = nil
        presented = nil
        if let closing {
            closing.parent?.removeChildWindow(closing)
            closing.close()
        }
    }

    private func sourceRect(for anchor: NSView) -> NSRect? {
        guard let owner = anchor.window, owner.isVisible || panel == nil,
              anchor.visibleRect.contains(NSPoint(x: anchor.bounds.midX, y: anchor.bounds.midY)) else { return nil }
        return owner.convertToScreen(anchor.convert(anchor.bounds, to: nil))
    }

    private func monitorWindow(_ owner: NSWindow) {
        windowObservers = [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification]
            .map { name in
                NotificationCenter.default.addObserver(forName: name, object: owner, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.reposition() }
                }
            }
    }

    private func monitorClicks(in window: NSWindow) {
        outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) {
            [weak self, weak window] event in
            if let self, let window, event.window === window {
                let switchesChart = self.chartAnchors.allObjects.contains { anchor in
                    anchor.window === window && anchor.visibleRect.contains(anchor.convert(event.locationInWindow, from: nil))
                }
                if !switchesChart { self.dismiss() }
            }
            return event
        }
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
        .background {
            GeometryReader { geometry in
                QuotaPopoverAnchor(view: anchor)
                    .onChange(of: geometry.frame(in: .global)) { _ in presentation.reposition(id: target.id) }
            }
            .allowsHitTesting(false)
        }
        .onChange(of: target) { presentation.update($0) }
        .onAppear { presentation.register(anchor) }
        .onDisappear {
            presentation.unregister(anchor)
            presentation.dismiss(id: target.id)
        }
    }
}

@MainActor
private final class QuotaPopoverTarget: ObservableObject {
    @Published var target: QuotaHistoryTarget
    @Published var viewport: CGSize
    @Published var selection: QuotaHistoryRequest?

    init(_ target: QuotaHistoryTarget, viewport: CGSize) {
        self.target = target
        self.viewport = viewport
    }
}

private struct QuotaPopoverContent: View {
    @ObservedObject var content: QuotaPopoverTarget
    let openInStatistics: (QuotaHistoryRequest) -> Void
    let onContentHeightChange: (CGFloat) -> Void

    var body: some View {
        MenuRowsViewport(maxHeight: content.viewport.height, onContentHeightChange: onContentHeightChange) {
            QuotaHistoryView(targets: [content.target], selection: $content.selection, openInStatistics: openInStatistics)
                .padding(10)
                .frame(width: content.viewport.width)
        }
        .frame(width: content.viewport.width)
    }
}

private struct QuotaPopoverAnchor: NSViewRepresentable {
    let view: NSView

    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
