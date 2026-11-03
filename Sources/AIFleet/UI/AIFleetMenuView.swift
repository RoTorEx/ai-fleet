import AppKit
import SwiftUI

struct AIFleetMenuView: View {
    let openSettings: () -> Void
    let openStatistics: () -> Void
    var openAgents: () -> Void = {}
    var openProcesses: () -> Void = {}
    var agents: AgentSessionsService? = nil

    @EnvironmentObject var service: StatusService
    @EnvironmentObject var settings: AppSettings
    @ObservedObject private var updater = UpdateService.shared
    @ObservedObject private var accounts = AccountStore.shared
    @ObservedObject private var codexProfiles = CodexMonitoringStore.shared
    @ObservedObject private var providerLaunch = ProviderLaunchStore.shared

    private var connections: [MenuAccountConnection] {
        sortedAccountProviderRows(ProviderCatalog.all.flatMap { provider -> [MenuAccountConnection] in
            guard settings.isEnabled(provider.id), ProviderCatalog.isInstalled(provider) else { return [] }
            return accountProviderRows(accounts: accounts.accounts, providerID: provider.id,
                global: service.status(for: provider.id), statusForConnection: service.status(for:), codex: codexProfiles)
        })
    }

    private var providers: [ProviderStatus] { connections.map(\.status) }

    private var lowestProvider: ProviderStatus? {
        providers
            .filter(\.hasCurrentQuota)
            .filter { ($0.remainingPercent ?? 0) > 0 }
            .min { ($0.remainingPercent ?? 101) < ($1.remainingPercent ?? 101) }
    }

    @State private var showsLegend = false
    @State private var showsOptions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summarySection
            Divider().padding(.top, 6).padding(.bottom, 10)
            if connections.count > 3 || connections.reduce(0, { $0 + max(1, $1.status.limitWindows.count) }) > 6 {
                MenuRowsViewport(maxHeight: min(340, max(180, (NSScreen.main?.visibleFrame.height ?? 700) - 240))) {
                    providerRows
                }
            } else { providerRows }
            if let agents {
                Divider().padding(.top, 10).padding(.bottom, 4)
                AgentsView(service: agents, back: {}, embedded: true)
            }

        }
        .font(FleetUI.body)
        .padding(FleetUI.spacing)
        .frame(width: 400)
        .background(FleetPalette.background)
    }

    private var applicationMenu: some View {
        Button { showsOptions.toggle() } label: {
            Image(systemName: "ellipsis").font(.system(size: 14, weight: .semibold)).frame(width: 30, height: 30).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("Application options")
            .instantPopover(isPresented: $showsOptions) {
                VStack(alignment: .leading, spacing: 2) {
                    option("Statistics…", icon: "chart.bar", action: openStatistics)
                    option("Settings…", icon: "gearshape", action: openSettings)
                    option("Processes", icon: "cpu", action: openProcesses)
                    Divider().padding(.vertical, 6)
                    option("Quit", icon: "power") { NSApplication.shared.terminate(nil) }
                    Divider().padding(.vertical, 6)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(lastCheckText)
                        Text("AI Fleet \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development")")
                    }.font(FleetUI.caption).foregroundStyle(.secondary).padding(.top, 4)
                }.padding(FleetUI.spacing).frame(width: 250)

            }
    }

    private func option(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button { showsOptions = false; action() } label: {
            Label(title, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 7).contentShape(Rectangle())
        }.buttonStyle(.plain).font(FleetUI.body).focusable(false)
    }

    private var lastCheckText: String {
        guard let date = providers.compactMap(\.lastUpdated).max() else { return "Last checked · waiting" }
        return "Last checked · " + date.formatted(date: .omitted, time: .standard)
    }

    private var providerRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(connections) { entry in
                ProviderLimitRow(entry: entry, isLowest: entry.isSelected && entry.status.id == lowestProvider?.id, openSettings: openSettings)
            }

        }
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Circle().fill(operationStatus.failed ? Color.orange : service.isMonitoring ? Color.green : Color.secondary)
                    .frame(width: 6, height: 6)
                Text(operationStatus.title).font(FleetUI.caption).foregroundStyle(.secondary).lineLimit(1)
                Text("(\(providers.filter(\.hasCurrentQuota).count)/\(providers.count))")
                    .font(FleetUI.caption).foregroundStyle(.secondary).monospacedDigit()
                Button { showsLegend.toggle() } label: {
                    Image(systemName: "info.circle").font(.system(size: 12)).frame(width: 28, height: 28)
                }.buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("Legend for status, accounts, limits and agents")
                    .onHover { showsLegend = $0 }
                    .instantPopover(isPresented: $showsLegend) { completeLegend }
                Spacer(minLength: 3)
                Button {
                    service.refresh(); codexProfiles.refresh(force: true); agents?.refresh(force: true)
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 13)).frame(width: 30, height: 30)
                }.buttonStyle(.plain).help("Refresh providers and agents (⌘R)").accessibilityLabel("Refresh (Command-R)")
                applicationMenu
            }
            if let detail = operationStatus.detail {
                Text(detail).font(FleetUI.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var completeLegend: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Menu guide").font(FleetUI.title)
            Text("Status & quota measurements").font(FleetUI.body).bold()
            Text("Green means monitoring is active; gray means paused; orange means an action needs attention. (3/3) means limits were measured for 3 of 3 provider-account connections. It does not count running sessions or signed-in accounts. A measured 0% still counts.")
            LegendSection().fixedSize(horizontal: false, vertical: true)
            Text("Accounts").font(FleetUI.body).bold()
            ForEach(accounts.visibleAccounts) { account in
                Text("\(account.badge) · \(account.name)\n\(account.email)")
            }
            Text("The account name beside a provider identifies its login. → selects the next command's account; existing agents keep theirs. ↓ is the lowest positive measured quota. The account button opens Sign in or Sign out, then Switch.")
            Text("Reset time & live agents").font(FleetUI.body).bold()
            Text("Hover a reset date: ↻ changes to a clock and shows total hours:minutes:seconds. Agents are live local iTerm2 sessions, grouped by location. Click a location to collapse it, or a session to jump. Moving rings/stripes mean working, not percent complete. Orange needs your attention; gray is idle or unknown. Use the filter icon for All, Needs you, Working, Idle or Unknown. ⌘R refreshes; ⌘A returns here from Processes.")
        }.font(FleetUI.caption).foregroundStyle(.secondary)
            .frame(width: 330, alignment: .leading).padding(FleetUI.spacing)
    }

    private var operationStatus: MenuOperationStatus {
        let active = codexProfiles.profiles.first { $0.id == codexProfiles.authenticatingID }
        let badge = accounts.accounts.first { $0.id == active?.accountID }?.badge
        let signing: String?
        if let badge {
            let verb = codexProfiles.authenticationAction == .logout ? "Signing out" : "Signing in"
            signing = "\(verb) Codex (\(badge))…"
        } else if let provider = service.signingOutProvider {
            signing = "Signing out \(ProviderCatalog.definition(for: provider)?.name ?? provider)…"
        } else if let provider = accounts.signingInProviderID {
            signing = "Signing in \(ProviderCatalog.definition(for: provider)?.name ?? provider)…"
        } else {
            signing = accounts.codexSigningIn ? "Signing in Codex…" : nil
        }
        return MenuOperationStatus.resolve(update: updater.state, refreshing: false,
                                            signingIn: signing, monitoring: service.isMonitoring)
    }


}

struct MenuRowsViewport<Content: View>: View {
    let maxHeight: CGFloat
    let content: Content
    @State private var contentHeight: CGFloat = 1

    init(maxHeight: CGFloat, @ViewBuilder content: () -> Content) {
        self.maxHeight = maxHeight
        self.content = content()
    }

    var body: some View {
        ScrollView {
            content
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: MenuRowsHeightKey.self, value: geometry.size.height)
                })
        }
        .frame(height: min(maxHeight, contentHeight))
        .onPreferenceChange(MenuRowsHeightKey.self) { contentHeight = max(1, $0) }
    }
}

private struct MenuRowsHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct MenuAccountConnection: Identifiable {
    let account: FleetAccount
    let connection: ProviderConnection
    let status: ProviderStatus
    let isSelected: Bool
    var isCurrentCLI: Bool? = nil
    var usesAccountLogin = false
    var id: String { connection.statusID }
}

struct ProviderLimitRow: View {
    let entry: MenuAccountConnection
    let isLowest: Bool
    let openSettings: () -> Void
    @ObservedObject private var accounts = AccountStore.shared
    @ObservedObject private var service = StatusService.shared
    @ObservedObject private var codexProfiles = CodexMonitoringStore.shared
    @ObservedObject private var providerLaunch = ProviderLaunchStore.shared
    @State private var isBadgeHovered = false
    private var status: ProviderStatus { entry.status }
    private var presentation: MenuConnectionState { MenuConnectionState(status: status) }
    private var color: Color { presentation.available ? rowColor(for: status) : FleetPalette.muted }

    private var actionIcon: String {
        switch status.providerID {
        case "claude": return "key.horizontal"
        case "codex": return entry.account.badge == "α" ? "rectangle.3.group" : "switch.2"
        case "kimi": return "person.crop.square"
        case "qwen": return "square.stack"
        default: return "slider.horizontal.3"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    FleetMark(kind: .current, size: 11)
                        .opacity((entry.isCurrentCLI ?? entry.isSelected) ? 1 : 0)
                        .foregroundColor(color)
                        .accessibilityLabel((entry.isCurrentCLI ?? entry.isSelected) ? "\(status.name) account \(entry.account.badge), current" : "")
                    FleetMark(kind: .lowest, size: 11).opacity(isLowest ? 1 : 0)
                        .foregroundColor(color)
                    Text(presentation.marker)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(color).frame(width: 11)
                }
                Text(status.name)
                    .font(.system(size: 13, weight: .semibold)).foregroundColor(color)
                if !entry.account.badge.isEmpty {
                Text(entry.account.name)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(color)
                    .onHover { isBadgeHovered = $0 }
                    .instantPopover(isPresented: $isBadgeHovered) {
                        Text(entry.account.tooltip(for: entry.connection, status: status))
                            .font(FleetUI.caption).foregroundStyle(.primary)
                            .frame(width: 240, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true).padding(FleetUI.spacing)
                    }
                    .accessibilityHint(Text(entry.account.tooltip(for: entry.connection, status: status)))
                    .accessibilityLabel("\(status.name) account \(entry.account.badge)")
                }
                Spacer(minLength: 8)
                Menu {
                    AccountConnectionActions(account: entry.account, connection: entry.connection, status: status,
                                             isCurrentCLI: entry.isCurrentCLI == true, openSettings: openSettings)
                } label: { Image(systemName: actionIcon).font(.system(size: 11)).frame(width: 28, height: 28) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .disabled(providerLaunch.busy || service.signingOutProvider != nil || accounts.codexSigningIn || accounts.signingInProviderID != nil || codexProfiles.authenticatingID != nil)
                .accessibilityLabel("\(entry.account.badge) \(status.name) actions")
            }
            if !status.limitWindows.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(status.limitWindows) { window in
                        if status.providerID == "gemini" {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(window.label).font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundColor(color).lineLimit(1)
                                LimitWindowLine(window: window, status: status, isActive: presentation.available, showsLabel: false)
                            }
                        } else {
                            LimitWindowLine(window: window, status: status, isActive: presentation.available)
                        }
                    }
                }
                .padding(.leading, 39)
            } else {
                Text(presentation.detail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(color).fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 39)
            }
            if let notice = status.quotaNotice {
                Text(notice).font(.system(size: 10.5))
                    .foregroundColor(entry.isSelected ? FleetPalette.warning : FleetPalette.muted)
                    .lineLimit(2).padding(.leading, 39)
            }
            if entry.usesAccountLogin {
                CodexAccountAuthenticationStatus(store: codexProfiles, accounts: accounts, accountID: entry.account.id)
                    .padding(.leading, 39)
            }
            if providerLaunch.messageAccountID == entry.account.id, providerLaunch.messageProviderID == status.providerID,
               let message = providerLaunch.message {
                HStack(alignment: .top, spacing: 5) {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !providerLaunch.busy {
                        Button { providerLaunch.dismissMessage() } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).font(.caption2)
                            .accessibilityLabel("Dismiss account message")
                    }
                }.padding(.leading, 39)
            }
            if accounts.launchProviderID == status.providerID &&
                (accounts.launchAccountID == entry.account.id || (accounts.launchAccountID == nil && entry.isCurrentCLI == true)) {
                if accounts.codexSigningIn && status.providerID == "codex" && entry.isCurrentCLI == true {
                    CodexSignInProgress(accounts: accounts).padding(.leading, 39)
                }
                if let error = accounts.launchError {
                    Text("Sign-in: \(error)").font(.caption).foregroundColor(FleetPalette.danger)
                        .fixedSize(horizontal: false, vertical: true).padding(.leading, 39)
                }
            }
        }
    }
}

struct LimitWindowLine: View {
    let window: ProviderLimitWindow
    let status: ProviderStatus
    var isActive = true
    var showsLabel = true

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            if showsLabel {
                Text(window.label)
                    .font(limitWindowFont)
                    .foregroundColor(windowColor)
                    .frame(width: 26, alignment: .leading)
            }

            Text(windowValueText)
                .font(limitWindowFont)
                .foregroundColor(windowColor)
                .frame(width: 40, alignment: .leading)

            ResetCountdownView(resetAt: blockingWindow == nil ? window.resetAt : nil,
                               dateText: resetText)
                .font(limitWindowFont).foregroundColor(resetColor)

            Spacer(minLength: 0)
        }
    }

    private var limitWindowFont: Font {
        .system(size: 11, weight: .medium)
    }

    private var blockingWindow: ProviderLimitWindow? {
        guard let windowDuration = durationSeconds(for: window.label) else {
            return nil
        }

        return status.limitWindows
            .filter { candidate in
                guard candidate.id != window.id,
                      candidate.remainingPercent <= 0,
                      let candidateDuration = durationSeconds(for: candidate.label) else {
                    return false
                }
                return candidateDuration > windowDuration
            }
            .min {
                let lhs = durationSeconds(for: $0.label) ?? .greatestFiniteMagnitude
                let rhs = durationSeconds(for: $1.label) ?? .greatestFiniteMagnitude
                return lhs < rhs
            }
    }

    private var windowValueText: String {
        if blockingWindow != nil {
            return "-"
        }
        return "\(window.remainingPercent)%"
    }

    private var resetText: String {
        if blockingWindow != nil {
            return "-"
        }
        return window.resetAt.map(formatResetTime) ?? "unknown"
    }

    private var resetColor: Color {
        if !isActive { return FleetPalette.muted }
        return blockingWindow == nil ? FleetPalette.muted : FleetPalette.faint
    }

    private var windowColor: Color {
        if !isActive { return FleetPalette.muted }
        if blockingWindow != nil {
            return FleetPalette.faint
        }
        if window.remainingPercent <= 10 {
            return FleetPalette.danger
        }
        if window.remainingPercent <= 25 {
            return FleetPalette.warning
        }
        return FleetPalette.value
    }
}

/// Both marks use one vector rotated in a square, so their arrow lengths match.
struct FleetMark: View {
    enum Kind { case current, lowest }
    let kind: Kind
    var size: CGFloat = 14
    var body: some View {
        Image(systemName: "arrow.right")
            .font(.system(size: size * 0.7, weight: .medium))
            .rotationEffect(.degrees(kind == .lowest ? 90 : 0))
            .frame(width: size, height: size)
    }
}

struct LegendSection: View {
    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 4, verticalSpacing: 4) {
            GridRow {
                Text("Capacity:")
                    .foregroundColor(FleetPalette.label)
                HStack(spacing: 4) {
                    Text("Enough ≥26%")
                        .foregroundColor(FleetPalette.value)
                    Text("·")
                        .foregroundColor(FleetPalette.muted)
                    Text("Low 11–25%")
                        .foregroundColor(FleetPalette.warning)
                    Text("·")
                        .foregroundColor(FleetPalette.muted)
                    Text("Critical ≤10%")
                        .foregroundColor(FleetPalette.danger)
                }
            }

            GridRow {
                Text("Access:").foregroundColor(FleetPalette.label)
                HStack(spacing: 4) {
                    Text("○ ready").foregroundColor(FleetPalette.value)
                    Text("· × sign in ·").foregroundColor(FleetPalette.value)
                    Text("? unavailable").foregroundColor(FleetPalette.muted)
                }
            }
            GridRow {
                Text("Marks:").foregroundColor(FleetPalette.label)
                HStack(spacing: 6) {
                    FleetMark(kind: .current, size: 10.5)
                    Text("default")
                    Spacer().frame(width: 8)
                    FleetMark(kind: .lowest, size: 10.5)
                    Text("lowest remaining")
                }.foregroundColor(FleetPalette.value)
            }
        }
        .font(.system(size: 10.5, weight: .medium))
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}

private enum FleetPalette {
    static let background = Color(nsColor: .windowBackgroundColor)
    static let border = Color(nsColor: .separatorColor)
    static let divider = Color(nsColor: .separatorColor)
    static let label = Color.secondary
    static let value = Color.primary
    static let command = Color.primary
    static let hoverCommand = Color.primary
    static let muted = Color.secondary
    static let faint = Color(nsColor: .tertiaryLabelColor)
    static let ready = Color(nsColor: .systemGreen)
    static let warning = Color(nsColor: .systemOrange)
    static let danger = Color(nsColor: .systemRed)
}

private func limitText(for status: ProviderStatus) -> String {
    if let remaining = status.remainingPercent {
        if let windowLabel = status.windowLabel {
            return "\(windowLabel) \(remaining)%"
        }
        return "\(remaining)%"
    }
    return status.detail
}

private func rowColor(for status: ProviderStatus) -> Color {
    if status.authentication.needsAccess || status.authentication == .notInstalled { return FleetPalette.faint }
    if status.authentication == .unknown { return FleetPalette.muted }
    if let remaining = status.remainingPercent {
        if remaining <= 10 { return FleetPalette.danger }
        if remaining <= 25 { return FleetPalette.warning }
    }
    return FleetPalette.value
}

private func formatResetTime(_ date: Date) -> String {
    date.formatted(.dateTime.month(.abbreviated).day().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
}
