import SwiftUI

struct StatisticsView: View {
    @ObservedObject private var analytics = UsageAnalyticsService.shared
    @ObservedObject private var service = StatusService.shared
    @State private var tab: AnalyticsTab = .overview

    private var snapshot: UsageAnalyticsSnapshot {
        analytics.snapshot
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            loadProgressView
            content
        }
        .padding(18)
        .frame(width: 720, height: 520, alignment: .topLeading)
        .onAppear {
            analytics.refreshIfNeeded(kimi: service.kimi)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            AnalyticsTabControl(selection: $tab)

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

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .overview:
            overview
        case .codex:
            ScrollView {
                codexDetail
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.trailing, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .kimi:
            kimiDetail
        }
    }

    private var loadProgressView: some View {
        TimelineView(.periodic(from: Date(), by: 0.25)) { timeline in
            VStack(alignment: .leading, spacing: 4) {
                if analytics.progress.isLoading {
                    if let fraction = analytics.progress.fractionCompleted {
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                    }

                    HStack(spacing: 10) {
                        Text(loadStatusText(now: timeline.date))
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                } else if snapshot.refreshedAt == nil {
                    Text("No usage snapshot yet")
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
        }
        .frame(height: analytics.progress.isLoading || snapshot.refreshedAt == nil ? 28 : 0)
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                SimpleMetricCard(
                    title: "Today",
                    value: compactCount(snapshot.codex.today.totalTokens),
                    detail: money(snapshot.codex.today.estimatedCostUSD)
                )
                SimpleMetricCard(
                    title: "7 days",
                    value: compactCount(snapshot.codex.sevenDays.totalTokens),
                    detail: money(snapshot.codex.sevenDays.estimatedCostUSD)
                )
                SimpleMetricCard(
                    title: "30 days",
                    value: compactCount(snapshot.codex.thirtyDays.totalTokens),
                    detail: money(snapshot.codex.thirtyDays.estimatedCostUSD)
                )
                SimpleMetricCard(
                    title: "Kimi left",
                    value: kimiRemainingText,
                    detail: kimiResetText
                )
            }

            HeatmapSection(daily: snapshot.codex.daily)
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
        let duration = (snapshot.lastLoadDuration ?? analytics.progress.lastDuration)
            .map { " · \(durationText($0))" } ?? ""
        return "Updated \(dateTimeText(refreshedAt))" + duration
    }

    private func loadStatusText(now: Date) -> String {
        let progress = analytics.progress
        if progress.isLoading {
            let elapsed = progress.startedAt.map { now.timeIntervalSince($0) } ?? 0
            if progress.totalFiles > 0 {
                return "Updating Codex \(progress.processedFiles)/\(progress.totalFiles) · \(durationText(elapsed))"
            }
            return "Finding Codex logs · \(durationText(elapsed))"
        }

        guard let lastDuration = progress.lastDuration else {
            return "Usage analytics not loaded"
        }
        return "Last load \(durationText(lastDuration))"
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

    private var kimiRemainingText: String {
        guard let lowest = snapshot.kimi.windows.min(by: { $0.remainingPercent < $1.remainingPercent }) else {
            return "--"
        }
        return "\(lowest.remainingPercent)%"
    }

    private var kimiResetText: String {
        guard let lowest = snapshot.kimi.windows.min(by: { $0.remainingPercent < $1.remainingPercent }) else {
            return "no quota data"
        }
        return lowest.resetAt.map { "resets \(shortDateTime($0))" } ?? lowest.label
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

private struct AnalyticsTabControl: View {
    @Binding var selection: AnalyticsTab

    var body: some View {
        HStack(spacing: 1) {
            ForEach(AnalyticsTab.allCases) { tab in
                Button {
                    selection = tab
                } label: {
                    Text(tab.rawValue)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(selection == tab ? .white : .primary)
                        .frame(width: 88, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(selection == tab ? Color.accentColor : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

private struct SimpleMetricCard: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(.secondary)

            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            Text(detail)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.76)
        }
        .padding(11)
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
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

private func durationText(_ value: TimeInterval) -> String {
    if value < 1 {
        return String(format: "%.0fms", value * 1_000)
    }
    if value < 10 {
        return String(format: "%.2fs", value)
    }
    return String(format: "%.1fs", value)
}

private func shortDate(_ date: Date) -> String {
    date.formatted(.dateTime.month(.abbreviated).day())
}

private func dateTimeText(_ date: Date) -> String {
    date.formatted(.dateTime.month(.abbreviated).day().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
}

private func shortDateTime(_ date: Date) -> String {
    date.formatted(.dateTime.month(.abbreviated).day().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
}

private func formatResetDate(_ date: Date) -> String {
    date.formatted(.dateTime.month(.abbreviated).day().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
}
