import SwiftUI

struct StatisticsView: View {
    @ObservedObject private var analytics = UsageAnalyticsService.shared
    @ObservedObject private var service = StatusService.shared
    @State private var tab: AnalyticsTab = .overview
    @State private var modelPage = 0
    @State private var dayPage = 0

    private let rowsPerPage = 5

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
        .frame(width: 780, height: 560, alignment: .topLeading)
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
            codexDetail
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
                    detail: money(snapshot.codex.today.estimatedCostUSD),
                    help: "Input plus output tokens recorded in local Codex session logs since midnight. Cost is an API-equivalent estimate, not a subscription charge."
                )
                SimpleMetricCard(
                    title: "7 days",
                    value: compactCount(snapshot.codex.sevenDays.totalTokens),
                    detail: money(snapshot.codex.sevenDays.estimatedCostUSD),
                    help: "Input plus output tokens from today and the previous 6 calendar days. Cost uses model-specific API-equivalent rates."
                )
                SimpleMetricCard(
                    title: "30 days",
                    value: compactCount(snapshot.codex.thirtyDays.totalTokens),
                    detail: money(snapshot.codex.thirtyDays.estimatedCostUSD),
                    help: "Input plus output tokens from today and the previous 29 calendar days. Cost uses model-specific API-equivalent rates."
                )
                SimpleMetricCard(
                    title: "Kimi left",
                    value: kimiRemainingText,
                    detail: kimiResetText,
                    help: "The lowest remaining percentage among active Kimi quota windows, with its next provider-reported reset time."
                )
            }

            HeatmapSection(daily: snapshot.codex.daily)
        }
    }

    private var codexDetail: some View {
        let models = snapshot.codex.models
        let days = Array(snapshot.codex.daily.reversed())
        let modelPages = pageCount(itemCount: models.count, pageSize: rowsPerPage)
        let dayPages = pageCount(itemCount: days.count, pageSize: rowsPerPage)
        let visibleModelPage = min(modelPage, max(0, modelPages - 1))
        let visibleDayPage = min(dayPage, max(0, dayPages - 1))

        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                UsageMetricCard(
                    title: "All time",
                    totals: snapshot.codex.total,
                    subtitle: "local session logs",
                    help: "All input plus output tokens found in ~/.codex/sessions. Cached input is included in the token total."
                )
                UsageMetricCard(
                    title: "Input",
                    totals: snapshot.codex.total,
                    subtitle: "uncached \(compactCount(snapshot.codex.total.billableInputTokens))",
                    help: "All reported input tokens. Uncached input equals input minus cached-input reads and cache writes.",
                    mode: .input
                )
                UsageMetricCard(
                    title: "Output",
                    totals: snapshot.codex.total,
                    subtitle: "reasoning \(compactCount(snapshot.codex.total.reasoningOutputTokens))",
                    help: "All reported output tokens. The subtitle shows the reasoning-token subset reported by Codex.",
                    mode: .output
                )
            }

            breakdownGrid

            HStack(alignment: .top, spacing: 14) {
                StatisticsSection(
                    title: "Top models",
                    help: "Models ranked by estimated API-equivalent cost, then by token count.",
                    page: visibleModelPage,
                    pageCount: modelPages,
                    previousPage: { modelPage = max(0, visibleModelPage - 1) },
                    nextPage: { modelPage = min(modelPages - 1, visibleModelPage + 1) }
                ) {
                    ModelUsageHeader()
                    ForEach(pageItems(models, page: visibleModelPage, pageSize: rowsPerPage)) { model in
                        ModelUsageRow(model: model)
                    }
                    if models.isEmpty {
                        emptyText("No Codex token usage found")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)

                StatisticsSection(
                    title: "Recent days",
                    help: "Calendar-day totals from the rolling 30-day local Codex history, newest first.",
                    page: visibleDayPage,
                    pageCount: dayPages,
                    previousPage: { dayPage = max(0, visibleDayPage - 1) },
                    nextPage: { dayPage = min(dayPages - 1, visibleDayPage + 1) }
                ) {
                    DailyUsageHeader()
                    ForEach(pageItems(days, page: visibleDayPage, pageSize: rowsPerPage)) { day in
                        DailyUsageRow(day: day)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
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
                    footnote: snapshot.kimi.source,
                    help: "The Kimi quota window with the lowest remaining percentage, read from the provider quota API."
                )

                ProviderSummaryPanel(
                    title: "Windows",
                    primary: "\(snapshot.kimi.windows.count)",
                    secondary: "active quota windows",
                    footnote: "usage counts are provider quota units",
                    help: "The number of quota windows returned by Kimi. Each window has its own duration, usage and reset time."
                )
            }

            InfoLabel(
                title: "Quota windows",
                help: "Provider-reported Kimi limits. Used/limit values are quota units; remaining is calculated by the provider."
            )

            if snapshot.kimi.windows.isEmpty {
                emptyText("No Kimi quota windows loaded")
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    KimiQuotaHeader()
                    ForEach(snapshot.kimi.windows) { window in
                        KimiQuotaRow(window: window)
                    }
                }
                .padding(12)
                .statisticsPanel()
            }
        }
    }

    private var breakdownGrid: some View {
        VStack(alignment: .leading, spacing: 9) {
            InfoLabel(
                title: "Dataset & accounting",
                help: "Where the Codex statistics come from and how token categories contribute to the estimate."
            )

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    statLabel("Source", help: "Local directory scanned for Codex session JSONL logs.")
                    statValue(snapshot.codex.source)
                    statLabel("Events", help: "Number of token-usage events parsed from all session logs.")
                    statValue("\(snapshot.codex.eventCount)")
                }
                GridRow {
                    statLabel("Uncached input", help: "Input tokens minus cached-input reads and cache-write tokens.")
                    statValue(compactCount(snapshot.codex.total.billableInputTokens))
                    statLabel("Cached input", help: "Input tokens served from a prompt cache, as reported in session logs.")
                    statValue(compactCount(snapshot.codex.total.cachedInputTokens))
                }
                GridRow {
                    statLabel("Cache writes", help: "Input tokens written into a prompt cache, as reported in session logs.")
                    statValue(compactCount(snapshot.codex.total.cacheWriteInputTokens))
                    statLabel("Output", help: "All generated output tokens, including the reported reasoning-token subset.")
                    statValue(compactCount(snapshot.codex.total.outputTokens))
                }
                GridRow {
                    statLabel("Cost basis", help: "Model-specific public API token rates applied to local usage; this is not your subscription bill.")
                    statValue("API-equivalent estimate")
                    statLabel("Estimate", help: "Uncached input, cached input, cache writes and output multiplied by their model-specific rates.")
                    statValue(money(snapshot.codex.total.estimatedCostUSD))
                }
            }
        }
        .font(.system(size: 11.5, weight: .medium))
        .padding(12)
        .statisticsPanel()
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

    private func statLabel(_ text: String, help: String) -> some View {
        InfoLabel(title: "\(text):", help: help, fontSize: 11.5)
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
    let help: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            InfoLabel(title: title, help: help, fontSize: 11.5)

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
        .statisticsPanel()
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
    let help: String
    var mode: UsageMetricMode = .total

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            InfoLabel(title: title, help: help, fontSize: 11.5)

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
        .statisticsPanel()
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
    let help: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            InfoLabel(title: title, help: help, fontSize: 13)
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
        .statisticsPanel()
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
                InfoLabel(
                    title: "Codex 30-day heatmap",
                    help: "Each cell is one calendar day. Opacity is relative to the busiest day in this 30-day window; hover a cell for tokens and estimated cost."
                )
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
        .statisticsPanel()
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
                .frame(width: 44, alignment: .trailing)
        }
    }
}

private struct ModelUsageHeader: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            ColumnInfoLabel(
                title: "Model",
                help: "Model name recorded in Codex session usage events.",
                width: 116,
                alignment: .leading
            )
            ColumnInfoLabel(
                title: "Tokens",
                help: "Input plus output tokens attributed to this model.",
                width: 76,
                alignment: .trailing
            )
            ColumnInfoLabel(
                title: "Estimate",
                help: "API-equivalent cost using this model's input, cache and output rates.",
                width: 70,
                alignment: .trailing
            )
            ColumnInfoLabel(
                title: "Events",
                help: "Number of token-usage events attributed to this model.",
                width: 44,
                alignment: .trailing
            )
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

private struct DailyUsageHeader: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            ColumnInfoLabel(
                title: "Date",
                help: "Local calendar day for the usage events.",
                width: 54,
                alignment: .leading
            )
            ColumnInfoLabel(
                title: "Tokens",
                help: "Input plus output tokens recorded on this day.",
                width: 82,
                alignment: .trailing
            )
            ColumnInfoLabel(
                title: "Estimate",
                help: "API-equivalent cost of this day's token usage.",
                width: 74,
                alignment: .trailing
            )
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

private struct KimiQuotaHeader: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            ColumnInfoLabel(
                title: "Window",
                help: "Provider-defined quota duration, such as 5 hours or 7 days.",
                width: 42,
                alignment: .leading
            )
            ColumnInfoLabel(
                title: "Usage",
                help: "Used quota units divided by the provider-reported limit.",
                width: 120,
                alignment: .leading
            )
            ColumnInfoLabel(
                title: "Remaining",
                help: "Percentage of quota still available in this window.",
                width: 86,
                alignment: .leading
            )
            ColumnInfoLabel(
                title: "Reset",
                help: "Provider-reported date and time when this quota window resets.",
                width: 150,
                alignment: .leading
            )
        }
    }
}

private struct InfoLabel: View {
    let title: String
    let help: String
    var fontSize: CGFloat = 12

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(title)
                .font(.system(size: fontSize, weight: .semibold))
            Image(systemName: "info.circle")
                .font(.system(size: max(9, fontSize - 1), weight: .medium))
                .help(help)
                .accessibilityLabel("About \(title)")
                .accessibilityHint(help)
        }
        .foregroundColor(.secondary)
    }
}

private struct ColumnInfoLabel: View {
    let title: String
    let help: String
    let width: CGFloat
    let alignment: Alignment

    var body: some View {
        InfoLabel(title: title, help: help, fontSize: 9.5)
            .lineLimit(1)
            .frame(width: width, alignment: alignment)
    }
}

private struct StatisticsSection<Content: View>: View {
    let title: String
    let help: String
    let page: Int
    let pageCount: Int
    let previousPage: () -> Void
    let nextPage: () -> Void
    let content: Content

    init(
        title: String,
        help: String,
        page: Int,
        pageCount: Int,
        previousPage: @escaping () -> Void,
        nextPage: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.help = help
        self.page = page
        self.pageCount = pageCount
        self.previousPage = previousPage
        self.nextPage = nextPage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                InfoLabel(title: title, help: help)
                Spacer(minLength: 8)
                PaginationControl(
                    page: page,
                    pageCount: pageCount,
                    previousPage: previousPage,
                    nextPage: nextPage
                )
            }

            VStack(alignment: .leading, spacing: 7) {
                content
            }
            .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
        }
        .padding(12)
        .statisticsPanel()
    }
}

private struct PaginationControl: View {
    let page: Int
    let pageCount: Int
    let previousPage: () -> Void
    let nextPage: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Button(action: previousPage) {
                Image(systemName: "chevron.left")
            }
            .disabled(page <= 0)
            .help("Previous page")

            Text("\(page + 1) / \(pageCount)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(minWidth: 34)

            Button(action: nextPage) {
                Image(systemName: "chevron.right")
            }
            .disabled(page >= pageCount - 1)
            .help("Next page")
        }
        .buttonStyle(.borderless)
    }
}

private var rowFont: Font {
    .system(size: 11.5, weight: .medium, design: .monospaced)
}

private extension View {
    func statisticsPanel() -> some View {
        background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

private func pageCount(itemCount: Int, pageSize: Int) -> Int {
    guard pageSize > 0 else { return 1 }
    return max(1, (itemCount + pageSize - 1) / pageSize)
}

private func pageItems<Element>(_ items: [Element], page: Int, pageSize: Int) -> [Element] {
    guard pageSize > 0, !items.isEmpty else { return [] }
    let lowerBound = min(max(0, page) * pageSize, items.count)
    let upperBound = min(lowerBound + pageSize, items.count)
    return Array(items[lowerBound..<upperBound])
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
