import SwiftUI

struct StatisticsView: View {
    @ObservedObject private var analytics = UsageAnalyticsService.shared
    @ObservedObject private var service = StatusService.shared
    @State private var tab: AnalyticsTab = .overview

    private var snapshot: UsageAnalyticsSnapshot {
        analytics.snapshot
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            switch tab {
            case .overview:
                overview
            case .codex:
                codexDetail
            case .kimi:
                kimiDetail
            }
        }
        .padding(18)
        .frame(width: 720, height: 520, alignment: .topLeading)
        .onAppear {
            analytics.refresh(kimi: service.kimi)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Picker("", selection: $tab) {
                ForEach(AnalyticsTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 300)

            Spacer()

            Text(refreshText)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)

            Button {
                analytics.refresh(kimi: service.kimi)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(analytics.isRefreshing)
            .help("Refresh usage")
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                UsageMetricCard(title: "Today", totals: snapshot.codex.today, subtitle: "Codex local estimate")
                UsageMetricCard(title: "7 days", totals: snapshot.codex.sevenDays, subtitle: "Codex local estimate")
                UsageMetricCard(title: "30 days", totals: snapshot.codex.thirtyDays, subtitle: "Codex local estimate")
            }

            HeatmapSection(daily: snapshot.codex.daily)

            HStack(alignment: .top, spacing: 12) {
                ProviderSummaryPanel(
                    title: "Codex",
                    primary: "\(compactCount(snapshot.codex.thirtyDays.totalTokens)) tokens",
                    secondary: "\(money(snapshot.codex.thirtyDays.estimatedCostUSD)) API-equivalent · 30d",
                    footnote: "\(snapshot.codex.eventCount) usage events · \(snapshot.codex.fileCount) files"
                )

                ProviderSummaryPanel(
                    title: "Kimi",
                    primary: kimiPrimaryText,
                    secondary: "quota windows · no dollar estimate",
                    footnote: snapshot.kimi.source
                )
            }
        }
    }

    private var codexDetail: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                UsageMetricCard(title: "All time", totals: snapshot.codex.total, subtitle: "local session logs")
                UsageMetricCard(title: "Input", totals: snapshot.codex.total, subtitle: "uncached \(compactCount(snapshot.codex.total.billableInputTokens))", mode: .input)
                UsageMetricCard(title: "Output", totals: snapshot.codex.total, subtitle: "reasoning \(compactCount(snapshot.codex.total.reasoningOutputTokens))", mode: .output)
            }

            breakdownGrid

            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    sectionTitle("Top models")
                    ForEach(snapshot.codex.models.prefix(6)) { model in
                        ModelUsageRow(model: model)
                    }
                    if snapshot.codex.models.isEmpty {
                        emptyText("No Codex token usage found")
                    }
                }
                .frame(width: 324, alignment: .topLeading)

                VStack(alignment: .leading, spacing: 8) {
                    sectionTitle("Recent days")
                    ForEach(Array(snapshot.codex.daily.suffix(10).reversed())) { day in
                        DailyUsageRow(day: day)
                    }
                }
            }
        }
    }

    private var kimiDetail: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ProviderSummaryPanel(
                    title: "Kimi",
                    primary: kimiPrimaryText,
                    secondary: "quota only",
                    footnote: snapshot.kimi.source
                )

                ProviderSummaryPanel(
                    title: "Windows",
                    primary: "\(snapshot.kimi.windows.count)",
                    secondary: "active quota windows",
                    footnote: "usage counts are provider quota units"
                )
            }

            sectionTitle("Quota windows")

            if snapshot.kimi.windows.isEmpty {
                emptyText("No Kimi quota windows loaded")
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(snapshot.kimi.windows) { window in
                        KimiQuotaRow(window: window)
                    }
                }
            }
        }
    }

    private var breakdownGrid: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 6) {
            GridRow {
                statLabel("Source")
                statValue(snapshot.codex.source)
                statLabel("Events")
                statValue("\(snapshot.codex.eventCount)")
            }
            GridRow {
                statLabel("Uncached input")
                statValue(compactCount(snapshot.codex.total.billableInputTokens))
                statLabel("Cached input")
                statValue(compactCount(snapshot.codex.total.cachedInputTokens))
            }
            GridRow {
                statLabel("Cache writes")
                statValue(compactCount(snapshot.codex.total.cacheWriteInputTokens))
                statLabel("Output")
                statValue(compactCount(snapshot.codex.total.outputTokens))
            }
            GridRow {
                statLabel("Cost basis")
                statValue("API-equivalent estimate")
                statLabel("Estimate")
                statValue(money(snapshot.codex.total.estimatedCostUSD))
            }
        }
        .font(.system(size: 11.5, weight: .medium))
    }

    private var refreshText: String {
        guard let refreshedAt = snapshot.refreshedAt else {
            return analytics.isRefreshing ? "loading" : "not loaded"
        }
        return refreshedAt.formatted(date: .omitted, time: .standard)
    }

    private var kimiPrimaryText: String {
        guard let lowest = snapshot.kimi.windows.min(by: { $0.remainingPercent < $1.remainingPercent }) else {
            return "no quota data"
        }
        if let used = lowest.used, let limit = lowest.limit {
            return "\(lowest.label) \(used)/\(limit)"
        }
        return "\(lowest.label) \(lowest.remainingPercent)% left"
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.secondary)
    }

    private func statLabel(_ text: String) -> some View {
        Text("\(text):")
            .foregroundColor(.secondary)
    }

    private func statValue(_ text: String) -> some View {
        Text(text)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
    }

    private func emptyText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.secondary)
    }
}

private enum AnalyticsTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case codex = "Codex"
    case kimi = "Kimi"

    var id: String { rawValue }
}

private enum UsageMetricMode {
    case total
    case input
    case output
}

private struct UsageMetricCard: View {
    let title: String
    let totals: UsageTotals
    let subtitle: String
    var mode: UsageMetricMode = .total

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(.secondary)

            Text(primaryText)
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.78)

            Text(secondaryText)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 86, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private var primaryText: String {
        switch mode {
        case .total:
            return compactCount(totals.totalTokens)
        case .input:
            return compactCount(totals.inputTokens)
        case .output:
            return compactCount(totals.outputTokens)
        }
    }

    private var secondaryText: String {
        switch mode {
        case .total:
            return "\(money(totals.estimatedCostUSD)) · \(subtitle)"
        case .input, .output:
            return subtitle
        }
    }
}

private struct ProviderSummaryPanel: View {
    let title: String
    let primary: String
    let secondary: String
    let footnote: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text(primary)
                .font(.system(size: 16, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(secondary)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(footnote)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 98, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

private struct HeatmapSection: View {
    let daily: [DailyUsage]

    private var maxTokens: Int {
        max(1, daily.map(\.totals.totalTokens).max() ?? 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Codex 30-day heatmap")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Text("tokens · API-equivalent estimate")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(.secondary)
            }

            HStack(alignment: .bottom, spacing: 5) {
                ForEach(daily) { day in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.accentColor.opacity(opacity(for: day)))
                        .frame(width: 17, height: 36)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                        )
                        .help("\(shortDate(day.day)): \(compactCount(day.totals.totalTokens)) tokens · \(money(day.totals.estimatedCostUSD))")
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private func opacity(for day: DailyUsage) -> Double {
        guard day.totals.totalTokens > 0 else { return 0.12 }
        let ratio = Double(day.totals.totalTokens) / Double(maxTokens)
        return min(0.95, max(0.24, 0.18 + ratio * 0.77))
    }
}

private struct ModelUsageRow: View {
    let model: ModelUsage

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(model.model)
                .font(rowFont)
                .frame(width: 116, alignment: .leading)
            Text(compactCount(model.totals.totalTokens))
                .font(rowFont)
                .frame(width: 76, alignment: .trailing)
            Text(money(model.totals.estimatedCostUSD))
                .font(rowFont)
                .foregroundColor(.secondary)
                .frame(width: 70, alignment: .trailing)
            Text("\(model.events)x")
                .font(rowFont)
                .foregroundColor(.secondary)
        }
    }
}

private struct DailyUsageRow: View {
    let day: DailyUsage

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(shortDate(day.day))
                .font(rowFont)
                .frame(width: 54, alignment: .leading)
            Text(compactCount(day.totals.totalTokens))
                .font(rowFont)
                .frame(width: 82, alignment: .trailing)
            Text(money(day.totals.estimatedCostUSD))
                .font(rowFont)
                .foregroundColor(.secondary)
                .frame(width: 74, alignment: .trailing)
        }
    }
}

private struct KimiQuotaRow: View {
    let window: KimiQuotaWindow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(window.label)
                .font(rowFont)
                .frame(width: 42, alignment: .leading)
            Text(usageText)
                .font(rowFont)
                .frame(width: 120, alignment: .leading)
            Text("\(window.remainingPercent)% left")
                .font(rowFont)
                .foregroundColor(color)
                .frame(width: 86, alignment: .leading)
            Text(window.resetAt.map(formatResetDate) ?? "unknown reset")
                .font(rowFont)
                .foregroundColor(.secondary)
        }
    }

    private var usageText: String {
        guard let used = window.used, let limit = window.limit else {
            return "quota unknown"
        }
        return "\(used)/\(limit) quota"
    }

    private var color: Color {
        if window.remainingPercent <= 10 { return .red }
        if window.remainingPercent < 20 { return .orange }
        return .primary
    }
}

private var rowFont: Font {
    .system(size: 11.5, weight: .medium, design: .monospaced)
}

private func compactCount(_ value: Int) -> String {
    let absolute = abs(value)
    if absolute >= 1_000_000 {
        return String(format: "%.2fM", Double(value) / 1_000_000)
    }
    if absolute >= 1_000 {
        return String(format: "%.1fK", Double(value) / 1_000)
    }
    return "\(value)"
}

private func money(_ value: Double) -> String {
    if value >= 100 {
        return String(format: "$%.0f", value)
    }
    if value >= 10 {
        return String(format: "$%.1f", value)
    }
    return String(format: "$%.2f", value)
}

private func shortDate(_ date: Date) -> String {
    date.formatted(.dateTime.month(.abbreviated).day())
}

private func formatResetDate(_ date: Date) -> String {
    date.formatted(.dateTime.month(.abbreviated).day().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
}
