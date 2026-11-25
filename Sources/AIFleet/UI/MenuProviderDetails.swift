import AppKit
import SwiftUI

struct MenuProviderDetail: Identifiable, Equatable {
    enum Section: Equatable {
        case quotaHistory
        case tokenSpend(TokenSpendSummary, StatisticsPeriod)
    }

    let target: QuotaHistoryTarget
    let section: Section

    var showsQuota: Bool { section == .quotaHistory }
    var id: String { (showsQuota ? "quota-history-" : "token-spend-") + target.id }
    var width: CGFloat { showsQuota ? 500 : 320 }
}

@MainActor
final class MenuProviderDetails: ObservableObject {
    static let windowIdentifier = NSUserInterfaceItemIdentifier("ai-fleet-provider-details")

    @Published private(set) var presented: String?
    private var panel: QuotaPopoverPanel?
    private var content: MenuProviderDetailContent?
    private var contentHeight: CGFloat?
    private weak var anchor: NSView?
    private var windowObservers: [NSObjectProtocol] = []
    private var outsideClickMonitor: Any?

    func toggle(_ detail: MenuProviderDetail, anchoredTo anchor: NSView, openStatistics: @escaping () -> Void) {
        if presented == detail.id {
            dismiss()
            return
        }
        guard let owner = anchor.window, let visible = owner.screen?.visibleFrame ?? NSScreen.main?.visibleFrame,
              let source = sourceRect(for: anchor),
              let placement = QuotaPopoverPlacement(anchor: source, screen: visible,
                contentHeight: detail.showsQuota ? visible.height : 154, preferredWidth: detail.width) else { return }
        dismiss()

        let content = MenuProviderDetailContent(detail, viewport: placement.viewport)
        let host = NSHostingView(rootView: MenuProviderDetailPopover(
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
                }
            }
        ))
        host.sizingOptions = []
        let panel = QuotaPopoverPanel(content: host)
        panel.identifier = Self.windowIdentifier
        panel.level = owner.level
        self.panel = panel
        self.content = content
        self.anchor = anchor
        presented = detail.id

        monitorWindow(owner)
        monitorClicks(in: owner, outside: anchor)
        // SwiftUI can report its measured height after the window is on screen.
        panel.layout(placement)
        owner.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
    }

    func update(_ detail: MenuProviderDetail) {
        guard presented == detail.id else { return }
        content?.detail = detail
    }

    func reposition(id: String? = nil) {
        guard id == nil || presented == id, let panel, let content else { return }
        guard let anchor, let owner = anchor.window, let source = sourceRect(for: anchor),
              let visible = owner.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else {
            dismiss()
            return
        }
        let initialHeight = content.detail.showsQuota ? visible.height : 154
        guard let placement = QuotaPopoverPlacement(anchor: source, screen: visible,
                contentHeight: contentHeight ?? initialHeight, preferredWidth: content.detail.width) else {
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
}

struct MenuProviderDetailButtons: View {
    let target: QuotaHistoryTarget
    let spend: TokenSpendSummary?
    let period: StatisticsPeriod
    let presentation: MenuProviderDetails
    let openStatistics: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            if let spend {
                MenuProviderDetailButton(detail: MenuProviderDetail(target: target, section: .tokenSpend(spend, period)),
                    presentation: presentation, openStatistics: openStatistics)
            }
            MenuProviderDetailButton(detail: MenuProviderDetail(target: target, section: .quotaHistory),
                presentation: presentation, openStatistics: openStatistics)
        }
    }
}

private struct MenuProviderDetailButton: View {
    let detail: MenuProviderDetail
    @ObservedObject var presentation: MenuProviderDetails
    let openStatistics: () -> Void
    @State private var anchor = NSView()

    var body: some View {
        Button {
            presentation.toggle(detail, anchoredTo: anchor, openStatistics: openStatistics)
        } label: {
            Image(systemName: detail.showsQuota ? "chart.xyaxis.line" : "chart.bar")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(presentation.presented == detail.id ? Color.primary : Color.secondary)
                .frame(width: 23, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(detail.showsQuota ? "Quota History" : "Token Spend")
        .accessibilityLabel("\(detail.target.label) \(detail.showsQuota ? "quota history" : "token spend")")
        .accessibilityIdentifier(detail.id)
        .background {
            GeometryReader { geometry in
                QuotaPopoverAnchor(view: anchor)
                    .onChange(of: geometry.frame(in: .global)) { _ in presentation.reposition(id: detail.id) }
            }
            .allowsHitTesting(false)
        }
        .onChange(of: detail) { presentation.update($0) }
        .onDisappear { presentation.dismiss(id: detail.id) }
    }
}

@MainActor
private final class MenuProviderDetailContent: ObservableObject {
    @Published var detail: MenuProviderDetail
    @Published var viewport: CGSize

    init(_ detail: MenuProviderDetail, viewport: CGSize) {
        self.detail = detail
        self.viewport = viewport
    }
}

private struct MenuProviderDetailPopover: View {
    @ObservedObject var content: MenuProviderDetailContent
    @State private var selection: QuotaHistoryRequest?
    let openInStatistics: (QuotaHistoryRequest) -> Void
    let onContentHeightChange: (CGFloat) -> Void

    var body: some View {
        MenuRowsViewport(maxHeight: content.viewport.height, onContentHeightChange: onContentHeightChange) {
            Group {
                switch content.detail.section {
                case .quotaHistory:
                    QuotaHistoryView(targets: [content.detail.target], selection: $selection, openInStatistics: openInStatistics)
                case let .tokenSpend(spend, period):
                    MenuTokenSpend(provider: content.detail.target.provider, spend: spend, period: period)
                }
            }
            .padding(10)
            .frame(width: content.viewport.width)
        }
        .frame(width: content.viewport.width)
    }
}

private struct MenuTokenSpend: View {
    let provider: StatisticsProvider
    let spend: TokenSpendSummary
    let period: StatisticsPeriod

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(provider.title) · Token Spend").font(.system(size: 13, weight: .semibold))
            Text("\(period.title) · On this Mac").font(.system(size: 11)).foregroundStyle(.secondary)
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 9) {
                GridRow {
                    metric("Total tokens", compactCount(spend.totals.totalTokens))
                    metric("API estimate", spend.cost.formattedEstimate)
                }
                GridRow {
                    metric("Input", compactCount(spend.totals.inputTokens))
                    metric("Output", compactCount(spend.totals.outputTokens))
                }
            }
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 17, weight: .semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct QuotaPopoverAnchor: NSViewRepresentable {
    let view: NSView

    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
