import AppKit
import SwiftUI

struct AIFleetMenuView: View {
    let openSettings: () -> Void

    @EnvironmentObject var service: StatusService
    @EnvironmentObject var settings: AppSettings

    private var providers: [ProviderStatus] {
        var list: [ProviderStatus] = []
        if settings.codexEnabled { list.append(service.codex) }
        if settings.kimiEnabled { list.append(service.kimi) }
        return list
    }

    private var lowestProvider: ProviderStatus? {
        providers
            .filter { ($0.remainingPercent ?? 0) > 0 }
            .min { ($0.remainingPercent ?? 101) < ($1.remainingPercent ?? 101) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summarySection

            FleetDivider()
                .padding(.top, 11)
                .padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(providers) { provider in
                    ProviderLimitRow(
                        status: provider,
                        isLowest: provider.id == lowestProvider?.id
                    )
                }
            }
            .padding(.horizontal, 16)

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

                ActionButton(title: "Settings…", shortcut: "", keyEquivalent: nil) {
                    openSettings()
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
        .preferredColorScheme(.dark)
    }

    private var summarySection: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 6, verticalSpacing: 7) {
            GridRow {
                summaryLabel("Server")
                summaryValue(fleetStateLabel, color: fleetStateColor)
            }
            GridRow {
                summaryLabel("Refresh")
                summaryValue(lastUpdateText)
            }
            GridRow {
                summaryLabel("Drain")
                summaryValue("earliest reset first · fence ≤1%")
            }
            GridRow {
                summaryLabel("Lowest")
                summaryValue(
                    lowestRemainingText,
                    color: lowestProvider.map(rowColor(for:)) ?? FleetPalette.value
                )
            }
            GridRow {
                summaryLabel("Bridge")
                summaryValue("\(activeProviderCount)/\(providers.count) lanes")
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
        if providers.contains(where: { $0.state == .offline }) {
            return "degraded"
        }
        if providers.contains(where: { $0.state == .noKey }) {
            return "needs auth"
        }
        return "ready"
    }

    private var fleetStateColor: Color {
        switch fleetStateLabel {
        case "ready":
            return FleetPalette.ready
        case "needs auth":
            return FleetPalette.warning
        default:
            return FleetPalette.muted
        }
    }

    private var activeProviderCount: Int {
        providers.filter { $0.state != .offline && $0.state != .noKey }.count
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
}

struct ProviderLimitRow: View {
    let status: ProviderStatus
    let isLowest: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(isLowest ? "↓" : " ")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(rowColor(for: status))
                    .frame(width: 14, alignment: .center)

                Text(profileMarker(for: status))
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundColor(rowColor(for: status))
                    .frame(width: 14, alignment: .center)

                Text("\(status.name):")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(rowColor(for: status))

                Spacer(minLength: 0)
            }

            if !status.limitWindows.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(status.limitWindows) { window in
                        LimitWindowLine(window: window, status: status)
                    }
                }
                .padding(.leading, 40)
            }
        }
    }
}

struct LimitWindowLine: View {
    let window: ProviderLimitWindow
    let status: ProviderStatus

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
        blockingWindow == nil ? FleetPalette.muted : FleetPalette.faint
    }

    private var windowColor: Color {
        if blockingWindow != nil {
            return FleetPalette.faint
        }
        if window.remainingPercent <= 10 {
            return FleetPalette.danger
        }
        if window.remainingPercent < 20 {
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
                    Text("normal ≥20%")
                        .foregroundColor(FleetPalette.value)
                    Text("·")
                        .foregroundColor(FleetPalette.muted)
                    Text("orange 11-19%")
                        .foregroundColor(FleetPalette.warning)
                    Text("·")
                        .foregroundColor(FleetPalette.muted)
                    Text("red ≤10%")
                        .foregroundColor(FleetPalette.danger)
                }
            }

            GridRow {
                Text("Profiles:")
                    .foregroundColor(FleetPalette.label)
                HStack(spacing: 4) {
                    Text("○ ordinary")
                        .foregroundColor(FleetPalette.value)
                    Text("·")
                        .foregroundColor(FleetPalette.muted)
                    Text("△ drain fallback")
                        .foregroundColor(FleetPalette.value)
                    Text("·")
                        .foregroundColor(FleetPalette.muted)
                    Text("× unavailable")
                        .foregroundColor(FleetPalette.value)
                }
            }

            GridRow {
                Text("Routing:")
                    .foregroundColor(FleetPalette.label)
                HStack(spacing: 4) {
                    Text("→ active")
                        .foregroundColor(FleetPalette.value)
                    Text("·")
                        .foregroundColor(FleetPalette.muted)
                    Text("↓ lowest")
                        .foregroundColor(FleetPalette.value)
                }
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
                .fill(Color.white.opacity(isHovered ? 0.10 : 0))
        )
        .padding(.horizontal, -8)
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

private enum FleetPalette {
    static let background = Color(red: 0.055, green: 0.062, blue: 0.064)
    static let border = Color.white.opacity(0.13)
    static let divider = Color.white.opacity(0.12)
    static let label = Color(red: 0.55, green: 0.57, blue: 0.59)
    static let value = Color(red: 0.78, green: 0.80, blue: 0.82)
    static let command = Color(red: 0.84, green: 0.86, blue: 0.88)
    static let hoverCommand = Color.white
    static let muted = Color(red: 0.48, green: 0.50, blue: 0.52)
    static let faint = Color(red: 0.35, green: 0.37, blue: 0.39)
    static let ready = Color(red: 0.48, green: 0.79, blue: 0.60)
    static let warning = Color(red: 0.91, green: 0.58, blue: 0.28)
    static let danger = Color(red: 0.93, green: 0.33, blue: 0.38)
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
    switch status.state {
    case .ok:
        if let remaining = status.remainingPercent, remaining < 20 {
            return FleetPalette.warning
        }
        return FleetPalette.value
    case .limited:
        return FleetPalette.danger
    case .offline, .noKey:
        return FleetPalette.value
    }
}

private func profileMarker(for status: ProviderStatus) -> String {
    switch status.state {
    case .offline, .noKey:
        return "×"
    default:
        return "○"
    }
}

private func formatResetTime(_ date: Date) -> String {
    date.formatted(.dateTime.month(.abbreviated).day().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
}
