import AppKit
import SwiftUI

enum FleetUI {
    static let spacing: CGFloat = 16
    static let title = Font.system(size: 15, weight: .semibold)
    static let body = Font.system(size: 13)
    static let caption = Font.system(size: 11)
}

extension View {
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
            .disabled(isCodex && codex.profile(for: account) == nil)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: hovered && resetAt != nil ? "clock" : "arrow.clockwise")
                .font(.system(size: 10)).frame(width: 11).opacity(dateText == "-" ? 0 : 1)
            ZStack(alignment: .leading) {
                Text(dateText).opacity(hovered && resetAt != nil ? 0 : 1)
                    .rotation3DEffect(.degrees(hovered && resetAt != nil && !reduceMotion ? -90 : 0), axis: (x: 1, y: 0, z: 0))
                if hovered, let resetAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(Self.remaining(until: resetAt, now: context.date)).monospacedDigit()
                    }.transition(.opacity)
                }
            }
        }

        .frame(width: 144, height: 18, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { value in
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) { hovered = value }
        }
        .accessibilityLabel(resetAt.map { "\(dateText), \(Self.remaining(until: $0))" } ?? dateText)
    }

    static func remaining(until date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(ceil(date.timeIntervalSince(now))))
        guard seconds > 0 else { return "Reset due" }
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
    }
}
