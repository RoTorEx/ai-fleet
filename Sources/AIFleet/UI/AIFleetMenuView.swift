import AppKit
import SwiftUI

struct AIFleetMenuView: View {
    let openSettings: () -> Void
    let openStatistics: () -> Void
    var openAgents: () -> Void = {}

    @EnvironmentObject var service: StatusService
    @EnvironmentObject var settings: AppSettings
    @ObservedObject private var updater = UpdateService.shared
    @ObservedObject private var accounts = AccountStore.shared
    @ObservedObject private var codexProfiles = CodexMonitoringStore.shared

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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summarySection

            FleetDivider()
                .padding(.top, 11)
                .padding(.bottom, 8)

            if connections.count > 3 || connections.reduce(0, { $0 + max(1, $1.status.limitWindows.count) }) > 6 {
                MenuRowsViewport(maxHeight: min(340, max(180, (NSScreen.main?.visibleFrame.height ?? 700) - 350))) {
                    providerRows
                }
            } else {
                providerRows
            }

            LegendSection()
                .padding(.horizontal, 16)
                .padding(.top, 11)

            FleetDivider()
                .padding(.top, 12)
                .padding(.bottom, 9)

            VStack(alignment: .leading, spacing: 0) {
                ActionButton(title: "Refresh now", shortcut: "⌘R", keyEquivalent: "r", modifiers: .command) {
                    service.refresh(); codexProfiles.refresh(force: true)
                }

                ActionButton(title: "Agents", shortcut: "⌘A", keyEquivalent: nil) {
                    openAgents()
                }

                ActionButton(title: "Statistics…", shortcut: "", keyEquivalent: nil) {
                    openStatistics()
                }

                ActionButton(title: "Settings…", shortcut: "", keyEquivalent: nil) {
                    openSettings()
                }

                ActionButton(title: updater.actionTitle, shortcut: "", keyEquivalent: nil) {
                    updater.update()
                }.disabled(updater.isBusy)

                ActionButton(title: "Quit", shortcut: "⌘Q", keyEquivalent: "q", modifiers: .command) {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(.horizontal, 16)

        }
        .padding(.vertical, 14)
        .frame(width: 354)
        .background(FleetPalette.background)
    }

    private var providerRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(connections) { entry in
                ProviderLimitRow(entry: entry, isLowest: entry.isSelected && entry.status.id == lowestProvider?.id, openSettings: openSettings)
            }

        }
        .padding(.horizontal, 16)
    }

    private var summarySection: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 6, verticalSpacing: 7) {
            GridRow {
                summaryLabel("Status")
                VStack(alignment: .leading, spacing: 3) {
                    summaryValue(operationStatus.title, color: operationStatus.failed ? FleetPalette.warning : FleetPalette.value)
                    if let detail = operationStatus.detail {
                        Text(detail).font(.system(size: 11))
                            .foregroundColor(operationStatus.failed ? FleetPalette.warning : FleetPalette.muted)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                }
            }
            GridRow {
                summaryLabel("Checked")
                summaryValue(lastUpdateText)
            }
            GridRow {
                summaryLabel("Lowest")
                summaryValue(
                    lowestRemainingText,
                    color: lowestProvider.map(rowColor(for:)) ?? FleetPalette.value
                )
            }
            GridRow {
                summaryLabel("Limits")
                summaryValue(quotaAvailabilityText(providers))
            }
            GridRow {
                summaryLabel("Version")
                summaryValue(versionText)
            }
        }
        .padding(.horizontal, 16)
    }

    private func summaryLabel(_ text: String) -> some View {
        Text("\(text):")
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundColor(FleetPalette.label)
    }

    private func summaryValue(_ text: String, color: Color = FleetPalette.value) -> some View {
        Text(text)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundColor(color)
            .lineLimit(1)
            .minimumScaleFactor(0.78)
    }

    private var operationStatus: MenuOperationStatus {
        let active = codexProfiles.profiles.first { $0.id == codexProfiles.authenticatingID }
        let badge = accounts.accounts.first { $0.id == active?.accountID }?.badge
        let signing = badge.map { "\(codexProfiles.authenticationAction == .logout ? "Signing out" : "Signing in") Codex (\($0))…" } ?? service.signingOutProvider.map {
            "Signing out \(ProviderCatalog.definition(for: $0)?.name ?? $0)…"
        } ?? (accounts.codexSigningIn ? "Signing in Codex…" : nil)
        return MenuOperationStatus.resolve(update: updater.state, refreshing: service.isRefreshing || codexProfiles.refreshing,
                                            signingIn: signing, monitoring: service.isMonitoring)
    }

    private var lastUpdateText: String {
        guard let updated = providers.compactMap(\.lastUpdated).max() else {
            return "waiting"
        }
        return updated.formatted(date: .omitted, time: .standard)
    }

    private var lowestRemainingText: String {
        if let provider = lowestProvider {
            let badge = connections.first { $0.status.id == provider.id }?.account.badge ?? "?"
            return "\(provider.name) (\(badge)) · \(limitText(for: provider))"
        }
        let hasData = providers.contains { $0.remainingPercent != nil }
        return hasData ? "-" : "waiting"
    }

    private var versionText: String {
        guard let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String else {
            return "development build"
        }
        return version
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
    @State private var isBadgeHovered = false
    private var status: ProviderStatus { entry.status }
    private var presentation: MenuConnectionState { MenuConnectionState(status: status) }
    private var color: Color { presentation.available ? rowColor(for: status) : FleetPalette.muted }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    FleetMark(kind: .current)
                        .opacity((entry.isCurrentCLI ?? entry.isSelected) ? 1 : 0)
                        .foregroundColor(color)
                        .accessibilityLabel((entry.isCurrentCLI ?? entry.isSelected) ? "\(status.name) account \(entry.account.badge), current" : "")
                    FleetMark(kind: .lowest).opacity(isLowest ? 1 : 0)
                        .foregroundColor(color)
                    Text(presentation.marker)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundColor(color).frame(width: 14)
                }
                Text(status.name)
                    .font(.system(size: 13, weight: .semibold)).foregroundColor(color)
                if !entry.account.badge.isEmpty {
                Text("(\(entry.account.badge))")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(color)
                    .onHover { isBadgeHovered = $0 }
                    .accessibilityHint(Text(entry.account.tooltip(for: entry.connection, status: status)))
                    .accessibilityLabel("\(status.name) account \(entry.account.badge)")
                }
                Spacer(minLength: 8)
                Menu {
                    Button("Sign in…") {
                        if entry.usesAccountLogin {
                            if entry.account.badge.isEmpty {
                                SettingsNavigation.shared.addAccount(for: "codex")
                                openSettings()
                            } else { codexProfiles.signIn(codexProfiles.ensureProfile(for: entry.account)) }
                        }
                        else { accounts.signInGlobally(status.providerID, accountID: entry.account.id) }
                    }
                    .help("Sign in to this account. Existing Codex terminal sessions keep their current login.")
                    if entry.usesAccountLogin {
                        if let profile = codexProfiles.profile(for: entry.account), status.authentication == .signedIn {
                            Button("Sign out", role: .destructive) { codexProfiles.signOut(profile) }
                        }
                    } else if entry.isSelected || (service.signOutFailedProvider == status.providerID && service.globalAccountIDs[status.providerID] == entry.account.id) {
                        Button(service.signOutFailedProvider == status.providerID ? "Retry sign out" : "Sign out", role: .destructive) {
                            Task { await service.signOutGlobally(status.providerID) }
                        }
                    }
                } label: { Image(systemName: "ellipsis").frame(width: 18, height: 20) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .disabled(service.signingOutProvider != nil || accounts.codexSigningIn || codexProfiles.authenticatingID != nil || (entry.usesAccountLogin && codexProfiles.refreshing))
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
                .padding(.leading, 52)
            } else {
                Text(presentation.detail)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(color).fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 52)
            }
            if let notice = status.quotaNotice {
                Text(notice).font(.system(size: 10.5))
                    .foregroundColor(entry.isSelected ? FleetPalette.warning : FleetPalette.muted)
                    .lineLimit(2).padding(.leading, 52)
            }
            if entry.usesAccountLogin {
                CodexAccountAuthenticationStatus(store: codexProfiles, accounts: accounts, accountID: entry.account.id)
                    .padding(.leading, 52)
            }
            if accounts.launchProviderID == status.providerID &&
                (accounts.launchAccountID == entry.account.id || (accounts.launchAccountID == nil && entry.isCurrentCLI == true)) {
                if accounts.codexSigningIn && status.providerID == "codex" && entry.isCurrentCLI == true {
                    CodexSignInProgress(accounts: accounts).padding(.leading, 52)
                }
                if let error = accounts.launchError {
                    Text("Sign-in: \(error)").font(.caption).foregroundColor(FleetPalette.danger)
                        .fixedSize(horizontal: false, vertical: true).padding(.leading, 52)
                }
            }
        }
        .overlay(alignment: .topLeading) {
            if isBadgeHovered {
                let tooltip = entry.account.tooltip(for: entry.connection, status: status)
                if !tooltip.isEmpty {
                    Text(tooltip)
                        .font(.system(size: 11))
                        .foregroundColor(FleetPalette.value)
                        .frame(maxWidth: 240, alignment: .leading)
                        .fixedSize(horizontal: true, vertical: true)
                        .padding(8)
                        .background(FleetPalette.background, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(FleetPalette.border))
                        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                        .offset(x: 52, y: 22)
                        .allowsHitTesting(false)
                }
            }
        }
        .zIndex(isBadgeHovered ? 1 : 0)
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

            Text(resetText)
                .font(limitWindowFont)
                .foregroundColor(resetColor)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            Spacer(minLength: 0)
        }
    }

    private var limitWindowFont: Font {
        .system(size: 11, weight: .medium, design: .monospaced)
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
        return "↻ \(window.resetAt.map(formatResetTime) ?? "unknown")"
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
    var body: some View {
        Image(systemName: "arrow.right")
            .font(.system(size: 13, weight: .medium))
            .rotationEffect(.degrees(kind == .lowest ? 90 : 0))
            .frame(width: 14, height: 14)
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
                    FleetMark(kind: .current)
                    Text("current")
                    Spacer().frame(width: 8)
                    FleetMark(kind: .lowest)
                    Text("lowest remaining")
                }.foregroundColor(FleetPalette.value)
            }
        }
        .font(.system(size: 10.5, weight: .medium))
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}

struct FleetDivider: View {
    var body: some View {
        Rectangle()
            .fill(FleetPalette.divider)
            .frame(height: 1)
            .padding(.horizontal, 16)
    }
}

struct ActionButton: View {
    let title: String
    let shortcut: String
    let keyEquivalent: KeyEquivalent?
    let modifiers: EventModifiers
    let action: () -> Void
    @State private var isHovered = false

    init(
        title: String,
        shortcut: String,
        keyEquivalent: KeyEquivalent? = nil,
        modifiers: EventModifiers = [],
        action: @escaping () -> Void
    ) {
        self.title = title
        self.shortcut = shortcut
        self.keyEquivalent = keyEquivalent
        self.modifiers = modifiers
        self.action = action
    }

    var body: some View {
        if let keyEquivalent {
            button
                .keyboardShortcut(keyEquivalent, modifiers: modifiers)
        } else {
            button
        }
    }

    private var button: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(isHovered ? FleetPalette.hoverCommand : FleetPalette.command)
                Spacer()
                Text(shortcut)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(FleetPalette.muted)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(isHovered ? 0.10 : 0))
        )
        .padding(.horizontal, -8)
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
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
