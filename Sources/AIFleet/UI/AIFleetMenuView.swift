import AppKit
import SwiftUI

struct AIFleetMenuView: View {
    let openSettings: () -> Void
    let openStatistics: () -> Void
    var openAgents: () -> Void = {}
    var openProcesses: () -> Void = {}
    var agents: AgentSessionsService? = nil
    var availableScreenHeight: CGFloat = NSScreen.main?.visibleFrame.height ?? 800

    @EnvironmentObject var service: StatusService
    @EnvironmentObject var settings: AppSettings
    @ObservedObject private var updater = UpdateService.shared
    @ObservedObject private var accounts = AccountStore.shared
    @ObservedObject private var codexProfiles = CodexMonitoringStore.shared
    @ObservedObject private var providerLaunch = ProviderLaunchStore.shared

    private var connections: [MenuAccountConnection] {
        sortedAccountProviderRows(ProviderCatalog.all.flatMap { provider -> [MenuAccountConnection] in
            guard settings.isEnabled(provider.id) else { return [] }
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
    @State private var chromeHeights: [String: CGFloat] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                summarySection
                Divider().padding(.top, 6).padding(.bottom, 10)
                if connections.count > 3 || connections.reduce(0, { $0 + max(1, $1.status.limitWindows.count) }) > 6 {
                    MenuRowsViewport(maxHeight: min(340, max(180, availableScreenHeight - 240))) {
                        providerRows
                    }
                } else { providerRows }
                if agents != nil { Divider().padding(.top, 10).padding(.bottom, 4) }
            }.background(GeometryReader { geometry in
                Color.clear.preference(key: MenuChromeHeightKey.self, value: ["top": geometry.size.height])
            })
            if let agents {
                AgentsView(service: agents, back: {}, embedded: true, maxListHeight: agentsListHeight)
            }

            HStack {
                Text(lastCheckText)
                Spacer(minLength: 4)
                Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development")
            }.font(FleetUI.menuSecondary).foregroundStyle(.secondary).padding(.top, 10)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: MenuChromeHeightKey.self, value: ["footer": geometry.size.height])
                })
        }
        .font(FleetUI.menuBody)
        .padding(FleetUI.spacing)
        .frame(width: 320)
        .background(Color.primary.opacity(0.025))
        .onPreferenceChange(MenuChromeHeightKey.self) { chromeHeights = $0 }
    }

    private var agentsListHeight: CGFloat {
        MenuHeightBudget.agentsViewport(screenHeight: availableScreenHeight,
            fixedHeight: (chromeHeights["top"] ?? 210) + (chromeHeights["footer"] ?? 22)
                + FleetUI.spacing * 2 + FleetUI.menuControlSize + 12)
    }

    private var applicationMenu: some View {
        Button { showsOptions.toggle() } label: {
            FleetMenuIcon(systemName: "ellipsis").contentShape(Rectangle())
        }.buttonStyle(.plain).focusable(false).accessibilityLabel("Application options")
            .instantPopover(isPresented: $showsOptions) {
                VStack(alignment: .leading, spacing: 2) {
                    option("Statistics…", icon: "chart.bar", action: openStatistics)
                    option("Settings…", icon: "gearshape", action: openSettings)
                    option("Processes", icon: "cpu", action: openProcesses)
                    Divider().padding(.vertical, 6)
                    option("Quit", icon: "power") { NSApplication.shared.terminate(nil) }
                }.padding(12).frame(width: 190)

            }
    }

    private func option(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button { showsOptions = false; action() } label: {
            Label(title, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 7).contentShape(Rectangle())
        }.buttonStyle(.plain).font(.system(size: 12)).focusable(false)
    }

    private var lastCheckText: String {
        guard let date = (providers.compactMap(\.lastUpdated) + [agents?.observedAt].compactMap { $0 }).max() else { return "Last refresh: —" }
        return "Last refresh: " + date.formatted(date: .omitted, time: .standard)
    }

    private var providerRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(connections) { entry in
                ProviderLimitRow(entry: entry, isLowest: entry.isSelected && entry.status.id == lowestProvider?.id, openSettings: openSettings)
            }

        }.overlay(alignment: .leading) {
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 0.5)
                .offset(x: 80).allowsHitTesting(false)
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
                    FleetMenuIcon(systemName: "info.circle")
                }.buttonStyle(.plain).focusable(false).foregroundStyle(.secondary)
                    .accessibilityLabel("Legend for status, accounts, limits and agents")
                    .onHover { showsLegend = $0 }
                    .instantPopover(isPresented: $showsLegend) { completeLegend }
                Spacer(minLength: 3)
                Button {
                    service.refresh(); codexProfiles.refresh(force: true); agents?.refresh(force: true)
                } label: {
                    FleetMenuIcon(systemName: "arrow.clockwise")
                }.buttonStyle(.plain).focusable(false).help("Refresh (⌘R)").accessibilityLabel("Refresh (Command-R)")
                applicationMenu
            }
            if let detail = operationStatus.detail {
                Text(detail).font(FleetUI.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var completeLegend: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Legend").font(FleetUI.menuHeading)
            Text("Monitoring").bold()
            Text("● Monitoring active").foregroundStyle(.green)
            Text("○ Monitoring paused")
            Text("● Needs attention").foregroundStyle(.orange)
            Text("\(providers.filter(\.hasCurrentQuota).count)/\(providers.count) — measured limits / connections")
            Divider()
            Text("Provider accounts").bold()
            Text("✓ Account selected for new sessions")
            Text("× Limits unavailable; dashes mean no measurement")
            Text("↓ Lowest positive remaining limit")
            Divider()
            Text("Remaining limits").bold()
            Text("26–100% — enough").foregroundStyle(.primary)
            Text("11–25% — low").foregroundStyle(.orange)
            Text("0–10% — critical").foregroundStyle(.red)
            ForEach(accounts.visibleAccounts) { account in
                VStack(alignment: .leading, spacing: 2) {
                    Text("(\(account.badge)) \(account.name)")
                    Text(account.email).foregroundStyle(.secondary)
                }
            }
            Divider()
            Text("Reset times").bold()
            Text("Hover a date to see time remaining.")
            Text("d — days    h — hours    m — minutes    s — seconds")
            Text("Not reported — no reset date from the provider")
            Divider()
            Text("Agents").bold()
            Text("Working — processing the current request")
            Text("Idle — waiting for input")
            Text("Ready — new reply, pane not opened since it arrived")
            Text("Question / Approval — needs your input")
            Text("Error — agent reported a blocker")
            Text("Unknown — no confirmed state")
            Text("Timer from the terminal or current request.")
            Text("≥ — observed duration only.")
            Text("Last message uses the provider log timestamp when available.")
        }.font(FleetUI.menuSecondary).foregroundStyle(.secondary)
            .frame(width: 300, alignment: .leading).padding(12)
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
    private var status: ProviderStatus { entry.status }
    private var presentation: MenuConnectionState { MenuConnectionState(status: status) }
    private var color: Color { presentation.available ? rowColor(for: status) : FleetPalette.muted }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .center, spacing: 8) {
                Text(status.name + (entry.account.badge.isEmpty ? "" : " (\(entry.account.badge))"))
                    .font(FleetUI.menuHeading).foregroundColor(color).lineLimit(1).frame(width: 80, alignment: .leading)
                if entry.isCurrentCLI ?? entry.isSelected {
                    FleetInlineSymbol(systemName: "checkmark").foregroundStyle(.secondary)
                        .accessibilityLabel("Selected account for new sessions")
                }
                if !presentation.available {
                    FleetInlineSymbol(systemName: "xmark").foregroundStyle(.secondary)
                        .accessibilityLabel("Limits unavailable")
                }
                if isLowest { FleetInlineSymbol(systemName: "arrow.down").foregroundColor(color) }
                Spacer(minLength: 0)
                Menu {
                    AccountConnectionActions(account: entry.account, connection: entry.connection, status: status,
                                             isCurrentCLI: entry.isCurrentCLI == true, openSettings: openSettings)
                } label: { FleetMenuIcon(systemName: "key.horizontal") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().quietMenuFocus()
                .disabled(providerLaunch.busy || service.signingOutProvider != nil || accounts.codexSigningIn || accounts.signingInProviderID != nil || codexProfiles.authenticatingID != nil)
                .accessibilityLabel("\(entry.account.badge) \(status.name) actions")
            }
            if presentation.available, !status.limitWindows.isEmpty {
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
                .padding(.leading, 0)
            } else {
                ForEach(quotaPlaceholderLabels(for: status), id: \.self) { label in
                    HStack(spacing: 15) {
                        HStack(spacing: 7) {
                            Text(label).frame(width: 26, alignment: .leading)
                            Text("—").frame(width: 40, alignment: .leading)
                        }.frame(width: 73, alignment: .leading)
                        HStack(spacing: 5) {
                            Image(systemName: "clock").frame(width: 12).hidden()
                            Text("—")
                        }
                        Spacer(minLength: 0)
                    }.font(FleetUI.menuBody).foregroundStyle(.secondary).frame(height: 18)
                }
            }
            if presentation.available, let notice = status.quotaNotice {
                Text(notice).font(.system(size: 10.5))
                    .foregroundColor(entry.isSelected ? FleetPalette.warning : FleetPalette.muted)
                    .lineLimit(2).padding(.leading, 88)
            }
            if entry.usesAccountLogin {
                CodexAccountAuthenticationStatus(store: codexProfiles, accounts: accounts, accountID: entry.account.id)
                    .padding(.leading, 88)
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
                }.padding(.leading, 88)
            }
            if accounts.launchProviderID == status.providerID &&
                (accounts.launchAccountID == entry.account.id || (accounts.launchAccountID == nil && entry.isCurrentCLI == true)) {
                if accounts.codexSigningIn && status.providerID == "codex" && entry.isCurrentCLI == true {
                    CodexSignInProgress(accounts: accounts).padding(.leading, 88)
                }
                if let error = accounts.launchError {
                    Text("Sign-in: \(error)").font(.caption).foregroundColor(FleetPalette.danger)
                        .fixedSize(horizontal: false, vertical: true).padding(.leading, 88)
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
        HStack(alignment: .firstTextBaseline, spacing: 15) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
            if showsLabel {
                Text(window.label)
                    .font(limitWindowFont)
                    .foregroundColor(windowColor)
                    .frame(width: 26, alignment: .leading)
            }

            Text(windowValueText)
                .font(limitWindowFont).monospacedDigit()
                .foregroundColor(windowColor)
                .frame(width: 40, alignment: .leading)

            }.frame(width: 73, alignment: .leading)
            ResetCountdownView(resetAt: blockingWindow == nil ? window.resetAt : nil,
                               dateText: resetText)
                .font(limitWindowFont).foregroundColor(resetColor)

            Spacer(minLength: 0)
        }
    }

    private var limitWindowFont: Font {
        FleetUI.menuBody
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
        return window.resetAt.map(formatResetTime) ?? "Not reported"
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

/// Total menu growth stops at three quarters of the available screen height.
enum MenuHeightBudget {
    static func agentsViewport(screenHeight: CGFloat, fixedHeight: CGFloat) -> CGFloat {
        max(0, screenHeight * 0.75 - fixedHeight)
    }
}

private struct MenuChromeHeightKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}
