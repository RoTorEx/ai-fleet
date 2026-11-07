import AppKit
import SwiftUI

struct AIFleetMenuView: View {
    let openSettings: () -> Void
    let openStatistics: () -> Void
    var openAgents: () -> Void = {}
    var openProcesses: () -> Void = {}

    @EnvironmentObject var service: StatusService
    @EnvironmentObject var settings: AppSettings
    @State private var isLegendShown = false
    @ObservedObject private var accounts = AccountStore.shared
    @ObservedObject private var codexProfiles = CodexMonitoringStore.shared
    @ObservedObject private var providerLaunch = ProviderLaunchStore.shared

    private var connections: [MenuAccountConnection] {
        menuProviderRows(accounts: accounts.accounts, enabled: settings.isEnabled,
            global: service.status(for:), statusForConnection: service.status(for:), codex: codexProfiles)
    }

    private var monitoringSummary: MonitoringSummary { MonitoringSummary(rows: connections, monitoring: service.isMonitoring) }

    private var providers: [ProviderStatus] { connections.map(\.status) }

    private var lowestProvider: ProviderStatus? {
        providers
            .filter(\.hasCurrentQuota)
            .filter { ($0.remainingPercent ?? 0) > 0 }
            .min { ($0.remainingPercent ?? 101) < ($1.remainingPercent ?? 101) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            FleetDivider()
                .padding(.top, 10)
                .padding(.bottom, 8)

            if connections.count > 3 || connections.reduce(0, { $0 + max(1, $1.status.limitWindows.count) }) > 6 {
                MenuRowsViewport(maxHeight: min(340, max(180, (NSScreen.main?.visibleFrame.height ?? 700) - 350))) {
                    providerRows
                }
            } else {
                providerRows
            }

            FleetDivider()
                .padding(.top, 11)
                .padding(.bottom, 8)

            footer
        }
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(width: 354)
        .overlay(alignment: .topLeading) {
            if isLegendShown {
                VStack(alignment: .leading, spacing: 9) {
                    if !statusNotes.isEmpty {
                        StatusNotesSection(notes: statusNotes)
                        Rectangle().fill(FleetPalette.divider).frame(height: 1)
                    }
                    LegendSection()
                }
                    .frame(maxWidth: 330, alignment: .leading)
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(FleetPalette.border))
                    .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
                    .padding(.horizontal, 10)
                    .padding(.top, 38)
                    .allowsHitTesting(false)
            }
        }
    }

    private var providerRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(connections) { entry in
                ProviderLimitRow(entry: entry, mark: mark(for: entry), openSettings: openSettings)
            }

        }
        .padding(.horizontal, 16)
    }

    /// One leading mark per row: ↓ lowest positive quota anywhere, → the current account of a
    /// provider with several accounts, • any other working connection, × / ? unavailable.
    private func mark(for entry: MenuAccountConnection) -> String {
        let state = MenuConnectionState(status: entry.status)
        guard state.available else { return state.marker }
        if entry.status.id == lowestProvider?.id { return "↓" }
        let siblings = connections.filter { $0.status.providerID == entry.status.providerID && !$0.isSetup }
        if siblings.count > 1, entry.isCurrentCLI ?? entry.isSelected { return "→" }
        return "•"
    }

    /// Account notes worth reading, shown at the top of the ⓘ card instead of under rows.
    private var statusNotes: [MenuStatusNote] {
        var notes: [MenuStatusNote] = []
        func label(_ entry: MenuAccountConnection) -> String {
            entry.account.badge.isEmpty ? entry.status.name : "\(entry.status.name) (\(entry.account.badge))"
        }
        for entry in connections {
            if let notice = entry.status.quotaNotice {
                notes.append(.init(label: label(entry), text: notice, warning: entry.isSelected))
            }
            if providerLaunch.messageIsError, let message = providerLaunch.message,
               providerLaunch.messageAccountID == entry.account.id, providerLaunch.messageProviderID == entry.status.providerID {
                notes.append(.init(label: label(entry), text: message, warning: true))
            }
            if entry.usesAccountLogin, let error = codexProfiles.error,
               codexProfiles.profiles.first(where: { $0.id == codexProfiles.errorProfileID })?.accountID == entry.account.id {
                let text = codexProfiles.switchBlockedProcessIDs == nil ? error
                    : "Switch blocked while Codex is running. Stop it in Processes, then retry."
                notes.append(.init(label: label(entry), text: text, warning: true))
            }
        }
        if let error = accounts.launchError {
            let provider = accounts.launchProviderID.flatMap { ProviderCatalog.definition(for: $0)?.name } ?? "Sign-in"
            notes.append(.init(label: provider, text: error, warning: true))
        }
        if codexProfiles.terminalSetupNotice {
            notes.append(.init(label: "Codex", text: "Terminals opened earlier: run rehash once.", warning: false))
        }
        return notes
    }

    /// One compact line: monitoring state and measured/saved count, then Refresh and Options.
    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 7, height: 7)
                Text(operationStatus.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(operationStatus.failed ? FleetPalette.warning : FleetPalette.value)
                    .lineLimit(1)
                Text("·").foregroundColor(FleetPalette.muted)
                Text("\(monitoringSummary.measured)/\(monitoringSummary.total)")
                    .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                    .foregroundColor(FleetPalette.muted)
                Image(systemName: "info.circle")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(isLegendShown ? FleetPalette.value : FleetPalette.muted)
                    .frame(width: 18, height: 18)
                    .overlay(alignment: .topTrailing) {
                        if !statusNotes.isEmpty {
                            Circle()
                                .fill(statusNotes.contains(where: \.warning) ? FleetPalette.warning : FleetPalette.muted)
                                .frame(width: 5, height: 5)
                                .offset(x: -1, y: 2)
                        }
                    }
                    .contentShape(Rectangle())
                    .onHover { isLegendShown = $0 }
                    .accessibilityLabel("Legend")
                Spacer(minLength: 8)
                HeaderIconButton(systemName: "arrow.clockwise", help: "Refresh (⌘R)", spinning: isRefreshing) {
                    refresh()
                }
                optionsMenu
            }
            if let detail = operationStatus.detail {
                HStack(spacing: 8) {
                    Text(detail).font(.system(size: 11))
                        .foregroundColor(operationStatus.failed ? FleetPalette.warning : FleetPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    if codexProfiles.authenticatingID != nil || accounts.codexSigningIn {
                        Button("Cancel") {
                            if codexProfiles.authenticatingID != nil { codexProfiles.cancelAuthentication() }
                            else { accounts.cancelCodexSignIn() }
                        }
                        .buttonStyle(.link).font(.system(size: 11))
                    }
                }
                .padding(.leading, 14)
            }
        }
        .padding(.horizontal, 16)
    }

    private var optionsMenu: some View {
        Menu {
            Button("Agents") { openAgents() }.keyboardShortcut("a")
            Button("Statistics") { openStatistics() }
            Button("Settings…") { openSettings() }.keyboardShortcut(",")
            Button("Processes") { openProcesses() }
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(FleetPalette.muted)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Options")
        .accessibilityLabel("Options")
    }

    private var footer: some View {
        HStack {
            Text("Last refresh: \(lastUpdateText)")
            Spacer()
            Text(versionText)
        }
        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
        .foregroundColor(FleetPalette.muted)
        .padding(.horizontal, 16)
    }

    private var isRefreshing: Bool { service.isRefreshing || codexProfiles.refreshing }

    private func refresh() {
        service.refresh(); codexProfiles.refresh(force: true)
    }

    private var statusDotColor: Color {
        if operationStatus.failed { return FleetPalette.warning }
        return service.isMonitoring ? FleetPalette.ready : FleetPalette.faint
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
        let status = MenuOperationStatus.resolve(update: .idle, refreshing: false,
                                                 signingIn: signing, monitoring: service.isMonitoring)
        // Sign-in progress belongs on the detail line; the header title stays Active/Paused.
        guard signing != nil else { return status }
        return MenuOperationStatus(title: service.isMonitoring ? "Active" : "Paused", detail: status.title)
    }

    private var lastUpdateText: String {
        guard let updated = providers.compactMap(\.lastUpdated).max() else {
            return "—"
        }
        return updated.formatted(date: .omitted, time: .standard)
    }

    private var versionText: String {
        guard let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String else {
            return "development build"
        }
        return "v\(version)"
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

/// Leading row mark. Every mark uses one monospaced font sharing the × optical center.
/// The font's → is shorter than its ↓, so → is the same ↓ glyph turned a quarter.
struct RowMark: View {
    let mark: String
    var size: CGFloat = 14

    var body: some View {
        if mark == "→" {
            glyph("↓").rotationEffect(.degrees(-90)).offset(y: size * 0.07)
        } else {
            glyph(mark)
        }
    }

    private func glyph(_ text: String) -> some View {
        Text(text).font(.system(size: size, weight: .medium, design: .monospaced))
    }
}

enum FleetRowMetrics {
    static let markWidth: CGFloat = 14
    static let markSpacing: CGFloat = 5
    /// Quota rows sit a little inside the provider name, like a nested list.
    static let detailIndent: CGFloat = markWidth + markSpacing + 10
}

struct MenuStatusNote: Hashable {
    let label: String
    let text: String
    let warning: Bool
}

struct StatusNotesSection: View {
    let notes: [MenuStatusNote]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Status")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(FleetPalette.label)
            ForEach(notes, id: \.self) { note in
                (Text(note.label + "  ").fontWeight(.semibold) + Text(note.text))
                    .font(.system(size: 10.5))
                    .foregroundColor(note.warning ? FleetPalette.warning : FleetPalette.value)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct ProviderLimitRow: View {
    let entry: MenuAccountConnection
    let mark: String
    let openSettings: () -> Void
    @ObservedObject private var accounts = AccountStore.shared
    @ObservedObject private var service = StatusService.shared
    @ObservedObject private var codexProfiles = CodexMonitoringStore.shared
    @ObservedObject private var providerLaunch = ProviderLaunchStore.shared
    @State private var isBadgeHovered = false
    private var status: ProviderStatus { entry.status }
    private var presentation: MenuConnectionState { MenuConnectionState(status: status) }
    private var color: Color { presentation.available ? rowColor(for: status) : FleetPalette.muted }
    private var markAccessibility: String {
        switch mark {
        case "↓": return "lowest remaining quota"
        case "→": return "current account"
        case "•": return "connected"
        case "×": return "sign in required"
        default: return "unavailable"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: FleetRowMetrics.markSpacing) {
                RowMark(mark: mark)
                    .foregroundColor(color)
                    .frame(width: FleetRowMetrics.markWidth, alignment: .center)
                    .accessibilityLabel(markAccessibility)
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
                    if entry.isSetup {
                        Button("Set up connection…") {
                            SettingsNavigation.shared.addAccount(for: status.providerID); openSettings()
                        }
                    } else {
                    if entry.usesAccountLogin, codexProfiles.profile(for: entry.account) == nil, entry.isCurrentCLI == true {
                        Button("Save current login") { codexProfiles.saveCurrentLogin(entry.account) }
                            .disabled(codexProfiles.refreshing)
                        Divider()
                    }
                    if entry.usesAccountLogin, codexProfiles.profile(for: entry.account) != nil {
                        Button("Switch") { codexProfiles.switchAccount(entry.account) }
                            .disabled(codexProfiles.refreshing)
                            .help("The next codex command uses this account. Running sessions keep their current accounts.")
                        Divider()
                    }
                    if !entry.usesAccountLogin {
                        Button("Switch") {
                            if entry.account.badge.isEmpty {
                                SettingsNavigation.shared.addAccount(for: status.providerID); openSettings()
                            } else {
                                providerLaunch.switchAccount(entry.account, providerID: status.providerID,
                                    global: service.status(for: status.providerID))
                            }
                        }.disabled(providerLaunch.busy)
                        .help("Applies to the next launch. Running agents keep their current accounts.")
                        Divider()
                    }
                    Button(entry.usesAccountLogin && codexProfiles.profile(for: entry.account) == nil ? "Connect separate login…" : "Sign in…") {
                        if entry.usesAccountLogin {
                            if entry.account.badge.isEmpty {
                                SettingsNavigation.shared.addAccount(for: "codex")
                                openSettings()
                            } else { codexProfiles.signIn(codexProfiles.ensureProfile(for: entry.account)) }
                        }
                        else { providerLaunch.signIn(entry.account, providerID: status.providerID) }
                    }
                    .disabled(entry.usesAccountLogin && codexProfiles.refreshing)
                    .help("Sign in to this account. Existing terminal sessions keep their current login.")
                    if entry.usesAccountLogin {
                        if let profile = codexProfiles.profile(for: entry.account), status.authentication == .signedIn {
                            Button("Sign out", role: .destructive) { codexProfiles.signOut(profile) }
                                .disabled(codexProfiles.refreshing)
                        }
                    } else if entry.isSelected || (service.signOutFailedProvider == status.providerID && service.globalAccountIDs[status.providerID] == entry.account.id) {
                        Button(service.signOutFailedProvider == status.providerID ? "Retry sign out" : "Sign out", role: .destructive) {
                            providerLaunch.signOut(entry.account, providerID: status.providerID)
                        }
                    }
                    }
                } label: { Image(systemName: "ellipsis").frame(width: 18, height: 20) }
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
                .padding(.leading, FleetRowMetrics.detailIndent)
            } else {
                Text(presentation.detail)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(color).fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, FleetRowMetrics.detailIndent)
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
            // Fixed columns keep periods, values and reset dates aligned across providers.
            Text(showsLabel ? window.label : "")
                .font(limitWindowFont)
                .foregroundColor(windowColor)
                .frame(width: 26, alignment: .leading)

            Text(windowValueText)
                .font(limitWindowFont)
                .foregroundColor(windowColor)
                .frame(width: 34, alignment: .trailing)

            Text(resetText)
                .font(limitWindowFont)
                .foregroundColor(resetColor)
                .padding(.leading, 8)
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
        switch QuotaResetState(resetAt: window.resetAt, now: Date()) {
        case .notReported: return "Not reported"
        case .due: return "Reset due"
        case .upcoming(let date): return "↻ \(formatResetTime(date))"
        }
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

/// Grouped legend: one titled row per topic, aligned in a shared column.
struct LegendSection: View {
    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
            GridRow {
                title("Monitoring")
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 9) {
                        dot(FleetPalette.ready, "Active")
                        dot(FleetPalette.faint, "Paused")
                        dot(FleetPalette.warning, "Error")
                    }
                    Text("1/6 — current limits / saved accounts")
                        .foregroundColor(FleetPalette.muted)
                }
            }
            GridRow {
                title("Quota")
                HStack(spacing: 4) {
                    Text("≥26%").foregroundColor(FleetPalette.value)
                    Text("·").foregroundColor(FleetPalette.muted)
                    Text("11–25% low").foregroundColor(FleetPalette.warning)
                    Text("·").foregroundColor(FleetPalette.muted)
                    Text("≤10% critical").foregroundColor(FleetPalette.danger)
                }
            }
            GridRow {
                title("Marks")
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 9) {
                        legendMark("•", "working")
                        legendMark("→", "current account")
                        legendMark("↓", "lowest")
                    }
                    HStack(spacing: 9) {
                        legendMark("×", "sign in")
                        legendMark("?", "unavailable")
                    }
                }
            }
            GridRow {
                title("Keys")
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 9) { legendKey("⌘R", "refresh"); legendKey("⌘A", "agents") }
                    HStack(spacing: 9) { legendKey("⌘,", "settings"); legendKey("Esc", "close") }
                }
            }
        }
        .font(.system(size: 10.5, weight: .medium))
        .lineLimit(1)
        .fixedSize()
    }

    private func legendMark(_ mark: String, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            RowMark(mark: mark, size: 11).frame(width: 10)
            Text(label)
        }
        .foregroundColor(FleetPalette.value)
    }

    private func legendKey(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key).foregroundColor(FleetPalette.value)
            Text(label).foregroundColor(FleetPalette.muted)
        }
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(FleetPalette.label)
            .gridColumnAlignment(.leading)
    }

    private func dot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).foregroundColor(FleetPalette.value)
        }
    }
}

struct HeaderIconButton: View {
    let systemName: String
    let help: String
    var spinning = false
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            icon
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(isHovered ? 0.10 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .help(help)
        .accessibilityLabel(help)
        .onHover { isHovered = $0 }
    }

    @ViewBuilder private var icon: some View {
        let image = Image(systemName: systemName)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundColor(FleetPalette.muted)
        if #available(macOS 15.0, *) {
            image.symbolEffect(.rotate.byLayer, options: .repeat(.continuous), isActive: spinning)
        } else if spinning {
            ProgressView().controlSize(.mini)
        } else {
            image
        }
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
