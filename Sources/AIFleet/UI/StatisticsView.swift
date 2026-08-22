import SwiftUI

struct StatisticsView: View {
    @ObservedObject var service = StatusService.shared
    @ObservedObject var settings = AppSettings.shared
    @State private var mode: StatisticsMode = .mixed

    private var providers: [ProviderStatus] {
        service.providerStatuses.filter { provider in
            settings.isEnabled(provider.id) && provider.isInstalled
        }
    }

    private var rows: [StatisticsRow] {
        providers.flatMap { provider in
            provider.limitWindows.map { window in
                StatisticsRow(provider: provider, window: window)
            }
        }
    }

    private var rowsWithCounts: [StatisticsRow] {
        rows.filter { $0.hasCounts }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("", selection: $mode) {
                ForEach(StatisticsMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch mode {
            case .mixed:
                mixedView
            case .byProvider:
                providerView
            }
        }
        .padding(18)
        .frame(width: 460)
        .frame(minHeight: 320)
    }

    private var mixedView: some View {
        VStack(alignment: .leading, spacing: 12) {
            summaryGrid

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("All windows")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)

                if rows.isEmpty {
                    emptyLine("No usage windows")
                } else {
                    ForEach(rows.sorted(by: statisticsSort)) { row in
                        statisticsLine(row)
                    }
                }
            }
        }
    }

    private var providerView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(providers) { provider in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(provider.name)
                                .font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Text(provider.detail)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.secondary)
                        }

                        Text(usageSummaryText(for: provider.limitWindows.map { StatisticsRow(provider: provider, window: $0) }))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)

                        if provider.limitWindows.isEmpty {
                            emptyLine("No usage windows")
                        } else {
                            ForEach(provider.limitWindows.map { StatisticsRow(provider: provider, window: $0) }) { row in
                                statisticsLine(row)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxHeight: 260)
    }

    private var summaryGrid: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 6) {
            GridRow {
                statLabel("Providers")
                statValue(providers.isEmpty ? "none installed" : "\(activeProviderCount)/\(providers.count) active")
            }
            GridRow {
                statLabel("Lowest")
                statValue(lowestText)
            }
            GridRow {
                statLabel("Known tokens")
                statValue(usageSummaryText(for: rowsWithCounts))
            }
            GridRow {
                statLabel("Percent-only")
                statValue(percentOnlyProvidersText)
            }
        }
    }

    private func statisticsLine(_ row: StatisticsRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(row.provider.name)
                .font(statFont)
                .frame(width: 48, alignment: .leading)
            Text(row.window.label)
                .font(statFont)
                .foregroundColor(.secondary)
                .frame(width: 28, alignment: .leading)
            Text("\(row.window.remainingPercent)% left")
                .font(statFont)
                .foregroundColor(color(for: row.window.remainingPercent))
                .frame(width: 64, alignment: .leading)
            Text(burnedText(for: row.window))
                .font(statFont)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            Text(row.window.resetAt.map(formatStatsResetTime) ?? "unknown")
                .font(statFont)
                .foregroundColor(.secondary)
        }
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.secondary)
    }

    private var statFont: Font {
        .system(size: 11, weight: .medium, design: .monospaced)
    }

    private var activeProviderCount: Int {
        providers.filter { $0.state != .offline && $0.state != .noKey && $0.state != .notInstalled }.count
    }

    private var lowestText: String {
        guard let row = rows.min(by: statisticsSort) else {
            return "waiting"
        }
        return "\(row.provider.name) \(row.window.label) \(row.window.remainingPercent)%"
    }

    private var percentOnlyProvidersText: String {
        let names = providers
            .filter { provider in
                provider.limitWindows.contains { $0.usedCount == nil || $0.limitCount == nil }
            }
            .map(\.name)
        return names.isEmpty ? "none" : names.joined(separator: ", ")
    }

    private func statLabel(_ text: String) -> some View {
        Text("\(text):")
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundColor(.secondary)
    }

    private func statValue(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    private func statisticsSort(_ lhs: StatisticsRow, _ rhs: StatisticsRow) -> Bool {
        if lhs.window.remainingPercent != rhs.window.remainingPercent {
            return lhs.window.remainingPercent < rhs.window.remainingPercent
        }
        return lhs.provider.name < rhs.provider.name
    }

    private func color(for remaining: Int) -> Color {
        if remaining <= 10 { return .red }
        if remaining < 20 { return .orange }
        return .primary
    }

    private func burnedText(for window: ProviderLimitWindow) -> String {
        if let used = window.usedCount, let limit = window.limitCount {
            return "used \(compactStatCount(used))/\(compactStatCount(limit)) \(window.unit ?? "")"
        }
        return "used \(max(0, min(100, 100 - window.remainingPercent)))%"
    }

    private func usageSummaryText(for rows: [StatisticsRow]) -> String {
        let rowsWithCounts = rows.filter(\.hasCounts)
        guard !rowsWithCounts.isEmpty else {
            return "token counts unavailable"
        }

        let used = rowsWithCounts.compactMap(\.window.usedCount).reduce(0, +)
        let limit = rowsWithCounts.compactMap(\.window.limitCount).reduce(0, +)
        let units = Set(rowsWithCounts.compactMap(\.window.unit))
        let unit = units.count == 1 ? (units.first ?? "") : "mixed units"
        return "used \(compactStatCount(used))/\(compactStatCount(limit)) \(unit)"
    }
}

private enum StatisticsMode: String, CaseIterable, Identifiable {
    case mixed = "Mixed"
    case byProvider = "By provider"

    var id: String { rawValue }
}

private struct StatisticsRow: Identifiable {
    let provider: ProviderStatus
    let window: ProviderLimitWindow

    var id: String {
        "\(provider.id)-\(window.id)"
    }

    var hasCounts: Bool {
        window.usedCount != nil && window.limitCount != nil
    }
}

private func formatStatsResetTime(_ date: Date) -> String {
    date.formatted(.dateTime.month(.abbreviated).day().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
}

private func compactStatCount(_ value: Int) -> String {
    let absolute = abs(value)
    if absolute >= 1_000_000 {
        return String(format: "%.1fM", Double(value) / 1_000_000)
    }
    if absolute >= 1_000 {
        return String(format: "%.1fK", Double(value) / 1_000)
    }
    return "\(value)"
}
