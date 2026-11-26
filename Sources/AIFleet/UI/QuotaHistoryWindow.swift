import AppKit
import SwiftUI

@MainActor
final class QuotaHistoryWindowController: NSWindowController, NSWindowDelegate {
    static let shared = QuotaHistoryWindowController()

    private let selection = QuotaWindowSelection()

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 530, height: 570),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "AI Fleet Quota Charts"
        window.minSize = NSSize(width: 400, height: 300)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        let frameName = "AIFleet.QuotaCharts"
        if !window.setFrameUsingName(frameName) { window.center() }
        window.setFrameAutosaveName(frameName)
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show(_ request: QuotaHistoryRequest) {
        guard let window else { return }
        selection.request = request
        if window.contentViewController == nil {
            let host = NSHostingController(rootView: QuotaHistoryWindowContent(selection: selection))
            host.sizingOptions = []
            setContentController(host, in: window)
        }
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        if let window { setContentController(nil, in: window) }
        selection.request = nil
    }

    private func setContentController(_ controller: NSViewController?, in window: NSWindow) {
        let frame = window.frame
        window.contentViewController = controller
        window.setFrame(frame, display: false)
    }
}

@MainActor
private final class QuotaWindowSelection: ObservableObject {
    @Published var request: QuotaHistoryRequest?
}

private struct QuotaHistoryWindowContent: View {
    @ObservedObject var selection: QuotaWindowSelection
    @ObservedObject private var service = StatusService.shared
    @ObservedObject private var accounts = AccountStore.shared
    @ObservedObject private var codex = CodexMonitoringStore.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        let rows = menuProviderRows(accounts: accounts.accounts, enabled: settings.isEnabled,
                                    global: service.status(for:), statusForConnection: service.status(for:), codex: codex)
        let targets = menuRowsAvailableFirst(rows).compactMap { QuotaHistoryTarget(row: $0, codex: codex) }
        ScrollView {
            if targets.isEmpty {
                Text("Enable a provider with statistics in Settings.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 100)
            } else {
                QuotaHistoryView(targets: targets, selection: $selection.request, presentation: .window)
                    .frame(maxWidth: 740)
                    .frame(maxWidth: .infinity)
                    .padding(12)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
