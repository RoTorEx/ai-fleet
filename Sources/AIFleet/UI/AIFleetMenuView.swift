import AppKit
import SwiftUI

struct AIFleetMenuView: View {
    let openSettings: () -> Void
    let openStatistics: () -> Void

    @EnvironmentObject var service: StatusService
    @EnvironmentObject var settings: AppSettings
    @ObservedObject private var updater = UpdateService.shared
    @ObservedObject private var accounts = AccountStore.shared

    private var connections: [MenuAccountConnection] {
        ProviderCatalog.all.flatMap { provider -> [MenuAccountConnection] in
            guard settings.isEnabled(provider.id), ProviderCatalog.isInstalled(provider) else { return [] }
            return accounts.linkedAccounts(for: provider.id).compactMap { account in
                guard let connection = account.connection(for: provider.id) else { return nil }
                let status = service.status(for: connection) ?? ProviderStatus(id: connection.statusID, name: provider.name,
                    state: .offline, detail: "Checking…", lastUpdated: nil, providerID: provider.id)
                return MenuAccountConnection(account: account, connection: connection, status: status,
                    isSelected: accounts.selections[provider.id] == account.id)
            }
        }
    }

    private var providers: [ProviderStatus] { connections.filter(\.isSelected).map(\.status) }

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

            if connections.count > 3 {
                ScrollView {
                    providerRows
                }
                .frame(height: min(340, max(180, (NSScreen.main?.visibleFrame.height ?? 700) - 350)))
            } else {
                providerRows
            }

            LegendSection()
                .padding(.horizontal, 16)
                .padding(.top, 11)

            FleetDivider()
                .padding(.top, 12)
                .padding(.bottom, 9)

            VStack(alignment: .leading, spacing: 7) {
                ActionButton(title: "Refresh now", shortcut: "⌘R", keyEquivalent: "r", modifiers: .command) {
                    service.refresh()
                }

                ActionButton(title: "Statistics…", shortcut: "", keyEquivalent: nil) {
                    openStatistics()
                }

                ActionButton(title: "Settings…", shortcut: "", keyEquivalent: nil) {
                    openSettings()
                }

                ActionButton(title: updater.actionTitle, shortcut: "", keyEquivalent: nil) {
                    updater.update()
                }

                if let detail = updater.detailText {
                    Text(detail)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(FleetPalette.muted)
                        .lineLimit(2)
                        .padding(.leading, 8)
                }

                ActionButton(title: "Quit", shortcut: "⌘Q", keyEquivalent: "q", modifiers: .command) {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(.horizontal, 16)

        }
        .padding(.vertical, 14)
        .frame(width: 354)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(FleetPalette.background.opacity(0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(FleetPalette.border, lineWidth: 1)
        )
    }

    private var providerRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(connections) { entry in
                ProviderLimitRow(entry: entry, isLowest: entry.id == lowestProvider?.id, openSettings: openSettings)
            }
        }
        .padding(.horizontal, 16)
    }

    private var summarySection: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 6, verticalSpacing: 7) {
            GridRow {
                summaryLabel("Status")
                summaryValue(fleetStateLabel, color: fleetStateColor)
            }
            GridRow {
                summaryLabel("Refresh")
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
                summaryLabel("Providers")
                summaryValue(providers.isEmpty ? "none installed" : "\(activeProviderCount)/\(providers.count) available")
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

    private var fleetStateLabel: String {
        if providers.isEmpty {
            return "no providers"
        }
        if providers.contains(where: { $0.authentication.needsAccess }) { return "needs access" }
        if providers.contains(where: { $0.authentication == .unknown }) { return "unknown" }
        if providers.contains(where: { $0.quotaState == .unavailable || $0.quotaState == .stale }) {
            return "quota unavailable"
        }
        return "ready"
    }

    private var fleetStateColor: Color {
        switch fleetStateLabel {
        case "ready":
            return FleetPalette.ready
        case "needs access", "quota unavailable":
            return FleetPalette.warning
        default:
            return FleetPalette.muted
        }
    }

    private var activeProviderCount: Int {
        providers.filter { $0.authentication == .signedIn }.count
    }

    private var lastUpdateText: String {
        guard let updated = providers.compactMap(\.lastUpdated).max() else {
            return "waiting"
        }
        return updated.formatted(date: .omitted, time: .standard)
    }

    private var lowestRemainingText: String {
        if let provider = lowestProvider {
            return "\(provider.name) · \(limitText(for: provider))"
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

struct MenuAccountConnection: Identifiable {
    let account: FleetAccount
    let connection: ProviderConnection
    let status: ProviderStatus
    let isSelected: Bool
    var id: String { connection.statusID }
}

struct ProviderLimitRow: View {
    let entry: MenuAccountConnection
    let isLowest: Bool
    let openSettings: () -> Void
    @ObservedObject private var accounts = AccountStore.shared
    @ObservedObject private var service = StatusService.shared
    @State private var isBadgeHovered = false
    private var status: ProviderStatus { entry.status }
    private var color: Color { entry.isSelected ? rowColor(for: status) : FleetPalette.muted }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(entry.isSelected ? "→" : " ")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(color).frame(width: 14)
                    .accessibilityLabel(entry.isSelected ? "\(status.name) account \(entry.account.badge), selected for next launch" : "")
                Text(isLowest ? "↓" : " ")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(color).frame(width: 14)
                Text(status.authentication.marker)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundColor(color).frame(width: 14)
                Text(status.name)
                    .font(.system(size: 13, weight: .semibold)).foregroundColor(color)
                Text("(\(entry.account.badge))")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(color)
                    .onHover { isBadgeHovered = $0 }
                    .accessibilityHint(Text(entry.account.tooltip(for: entry.connection, status: status)))
                    .accessibilityLabel("\(status.name) account \(entry.account.badge)")
                Spacer(minLength: 8)
                Menu {
                    if !entry.isSelected {
                        Button("Use this account") {
                            accounts.select(entry.account.id, for: status.providerID)
                            service.refresh()
                        }
                        Divider()
                    }
                    Button("Open \(status.name)…") { accounts.open(entry.connection, account: entry.account) }
                    Button("Sign in…") { accounts.open(entry.connection, account: entry.account, login: true) }
                    Divider()
                    Button("Add account…") {
                        SettingsNavigation.shared.addAccount(for: status.providerID)
                        openSettings()
                    }
                } label: { Image(systemName: "ellipsis").frame(width: 18, height: 20) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("\(entry.account.badge) \(status.name) actions")
            }
            if !status.limitWindows.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(status.limitWindows) { window in
                        LimitWindowLine(window: window, status: status, isActive: entry.isSelected)
                    }
                }
                .padding(.leading, 60)
            } else {
                Text(status.detail)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(color).lineLimit(1).minimumScaleFactor(0.8)
                    .padding(.leading, 60)
            }
            if let notice = status.quotaNotice {
                Text(notice).font(.system(size: 10.5))
                    .foregroundColor(entry.isSelected ? FleetPalette.warning : FleetPalette.muted)
                    .lineLimit(2).padding(.leading, 60)
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
                        .offset(x: 60, y: 22)
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

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(window.label)
                .font(limitWindowFont)
                .foregroundColor(windowColor)
                .frame(width: 26, alignment: .leading)

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

struct LegendSection: View {
    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 4, verticalSpacing: 4) {
            GridRow {
                Text("Color:")
                    .foregroundColor(FleetPalette.label)
                HStack(spacing: 4) {
                    Text("normal ≥26%")
                        .foregroundColor(FleetPalette.value)
                    Text("·")
                        .foregroundColor(FleetPalette.muted)
                    Text("orange 11-25%")
                        .foregroundColor(FleetPalette.warning)
                    Text("·")
                        .foregroundColor(FleetPalette.muted)
                    Text("red ≤10%")
                        .foregroundColor(FleetPalette.danger)
                }
            }

            GridRow {
                Text("Auth:").foregroundColor(FleetPalette.label)
                Text("○ signed in · × needs access · ? unknown")
                    .foregroundColor(FleetPalette.value)
            }
            GridRow {
                Text("Selection:").foregroundColor(FleetPalette.label)
                Text("→ selected · gray unselected").foregroundColor(FleetPalette.value)
            }
            GridRow {
                Text("Quota:").foregroundColor(FleetPalette.label)
                Text("↓ lowest remaining").foregroundColor(FleetPalette.value)
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
            .padding(.vertical, 5)
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
