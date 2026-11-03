import AppKit
import SwiftUI

enum FleetUI {
    static let spacing: CGFloat = 16
    static let title = Font.system(size: 15, weight: .semibold)
    static let body = Font.system(size: 13)
    static let caption = Font.system(size: 11)
    // Compact menu typography: one family, three roles, shared control geometry.
    static let menuHeading = Font.system(size: 12, weight: .medium)
    static let menuBody = Font.system(size: 11)
    static let menuSecondary = Font.system(size: 10)
    static let menuIcon = Font.system(size: 11)
    static let menuControlSize: CGFloat = 28
}

/// Fit the symbol independently of font baselines, then center it in its hit area.
struct FleetMenuIcon: View {
    let systemName: String
    var body: some View {
        FleetInlineSymbol(systemName: systemName)
            .frame(width: FleetUI.menuControlSize, height: FleetUI.menuControlSize, alignment: .center)
            .contentShape(Rectangle())
    }
}

struct FleetInlineSymbol: View {
    let systemName: String
    var body: some View {
        Image(systemName: systemName).resizable().scaledToFit()
            .frame(width: 12, height: 12, alignment: .center)
    }
}

extension View {
    @ViewBuilder
    func quietMenuFocus() -> some View {
        if #available(macOS 14, *) { focusEffectDisabled() }
        else { focusable(false) }
    }

    func instantPopover<Content: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) -> some View {
        popover(isPresented: isPresented, arrowEdge: .top) {
            content().background(Color(nsColor: .windowBackgroundColor))
                .background(FleetPopoverWindowConfiguration().allowsHitTesting(false))
        }
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }
}

/// Configure the system-owned child window without introducing another anchor.
private struct FleetPopoverWindowConfiguration: NSViewRepresentable {
    private final class WindowProbe: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.identifier = NSUserInterfaceItemIdentifier("ai-fleet-child-popover")
            window?.animationBehavior = .none
            if let popover = window?.delegate as AnyObject? as? NSPopover { popover.animates = false }
        }
    }
    func makeNSView(context: Context) -> NSView { WindowProbe() }
    func updateNSView(_ view: NSView, context: Context) {}
}

/// Shared by the account menu and Settings so authentication actions cannot contradict each other.
struct AccountConnectionActions: View {
    let account: FleetAccount
    let connection: ProviderConnection
    let status: ProviderStatus?
    var isCurrentCLI = false
    var openSettings: () -> Void = {}
    @ObservedObject private var codex = CodexMonitoringStore.shared
    @ObservedObject private var launch = ProviderLaunchStore.shared
    @ObservedObject private var service = StatusService.shared

    private var isCodex: Bool { connection.providerID == "codex" }

    var body: some View {
        Group {
            if status?.authentication == .signedIn {
                Button("Sign out", role: .destructive) {
                    if isCodex {
                        if let profile = codex.profile(for: account) { codex.signOut(profile) }
                        else { Task { await service.signOutGlobally("codex") } }
                    } else { launch.signOut(account, providerID: connection.providerID) }
                }
            } else {
                Button("Sign in…") {
                    if account.badge.isEmpty {
                        SettingsNavigation.shared.addAccount(for: connection.providerID); openSettings()
                    } else if isCodex { codex.signIn(codex.ensureProfile(for: account)) }
                    else { launch.signIn(account, providerID: connection.providerID) }
                }
            }
            Button("Switch") {
                if isCodex { codex.switchAccount(account) }
                else if account.badge.isEmpty {
                    SettingsNavigation.shared.addAccount(for: connection.providerID); openSettings()
                } else { launch.switchAccount(account, providerID: connection.providerID,
                                              global: service.status(for: connection.providerID)) }
            }
            .disabled((isCodex && codex.profile(for: account) == nil) ||
                AccountIdentityMatch.assess(expected: account.email, observed: status?.account?.email) != .verified)
            .help("Choose this account for the next command. Running agents keep their accounts.")
            if isCodex, codex.profile(for: account) == nil, isCurrentCLI {
                Button("Save current login") { codex.saveCurrentLogin(account) }
            }
        }
        .disabled(launch.busy || codex.authenticatingID != nil || service.signingOutProvider != nil ||
                  (isCodex && codex.refreshing))
    }
}

struct ResetCountdownView: View {
    let resetAt: Date?
    let dateText: String
    @State private var hovered = false
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            ResetTimeCell(dateText: dateText, countdown: resetAt.map { Self.remaining(until: $0, now: context.date) }, hovered: hovered)
        }
        .frame(width: 160, height: 18, alignment: .leading)
        .alignmentGuide(.firstTextBaseline) { _ in 13 }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .accessibilityLabel(resetAt.map { "\(dateText), \(Self.remaining(until: $0))" } ?? dateText)
    }

    static func remaining(until date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(ceil(date.timeIntervalSince(now))))
        guard seconds > 0 else { return "Reset due" }
        let parts = [(seconds / 86400, "d"), ((seconds % 86400) / 3600, "h"),
                     ((seconds % 3600) / 60, "m"), (seconds % 60, "s")]
        return parts.filter { $0.0 > 0 }.map { "\($0.0)\($0.1)" }.joined(separator: " ")
    }
}

struct ResetTimeCell: View {
    let dateText: String
    let countdown: String?
    let hovered: Bool
    var body: some View {
        HStack(spacing: 5) {
            FleetInlineSymbol(systemName: hovered && countdown != nil ? "clock" : "arrow.clockwise").opacity(dateText == "-" ? 0 : 1)
            Text(hovered ? (countdown ?? dateText) : dateText).monospacedDigit().lineLimit(1)
        }.frame(width: 160, height: 18, alignment: .leading)
            .alignmentGuide(.firstTextBaseline) { _ in 13 }
    }
}
