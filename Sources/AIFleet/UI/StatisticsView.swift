import AppKit
import SwiftUI

struct StatisticsView: View {
    @ObservedObject private var analytics = UsageAnalyticsService.shared
    @ObservedObject private var service = StatusService.shared
    @State private var tab: AnalyticsTab = .codex
    @State private var period: AnalyticsPeriod = .allTime
    @State private var detailPage: StatisticsDetailPage = .tables

    private var snapshot: UsageAnalyticsSnapshot { analytics.snapshot }

    private var selection: CodexUsageSelection {
        let bounds = period.bounds()
        return codexUsageSelection(from: snapshot.codex, start: bounds.start, end: bounds.end)
    }

    private var periodDetail: String {
        guard period == .allTime, let first = selection.daily.first?.day, let last = selection.daily.last?.day else {
            return period.label
        }
        return "\(rangeDate(first)) – \(rangeDate(last))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            switch tab {
            case .codex: codexContent
            case .kimi: kimiContent
            }
        }
        .padding(16)
        .frame(minWidth: 820, minHeight: 600, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            analytics.updateKimi(kimi: service.kimi)
            analytics.refreshAccountUsageIfNeeded()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 16) {
                AnalyticsTabControl(selection: $tab)
                Spacer(minLength: 20)
                RefreshStatus(
                    progress: analytics.progress,
                    refreshedAt: snapshot.refreshedAt,
                    accountRefreshedAt: snapshot.codex.accountUsage?.fetchedAt,
                    isRefreshing: analytics.isRefreshing,
                    refresh: { analytics.refresh(kimi: service.kimi) }
                )
            }
            if tab == .codex {
                HStack {
                    Spacer(minLength: 0)
                    PeriodToolbar(period: $period)
                }
            }
        }
    }

    private var codexContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            summaryGrid
            DetailPageControl(page: $detailPage)
            switch detailPage {
            case .tables:
                HStack(alignment: .top, spacing: 10) {
                    ModelTablePanel(models: selection.models)
                        .frame(minWidth: 430, maxWidth: .infinity)
                    DailyTablePanel(daily: selection.daily, usesAccountUsage: selection.usesAccountUsage)
                        .frame(minWidth: 330, maxWidth: .infinity)
                }
            case .activity:
                ActivityHeatmap(
                    days: selection.daily,
                    sourceLabel: selection.usesAccountUsage ? "Account" : "Local",
                    displayThrough: period == .allTime
                        ? selection.daily.first.map { heatmapHorizon(startingAt: $0.day) }
                        : nil
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var summaryGrid: some View {
        GeometryReader { geometry in
            let spacing: CGFloat = 8
            let columnWidth = max(0, (geometry.size.width - spacing * 2) / 3)
            VStack(spacing: spacing) {
                HStack(spacing: spacing) {
                    MetricCard(
                        title: "Estimate",
                        sourceLabel: selection.usesAccountUsage ? "Account" : "Local",
                        value: money(selection.estimatedCostUSD),
                        help: selection.usesAccountUsage
                            ? "Estimated from Codex account tokens for the selected period, multiplied by the average API-equivalent cost per token observed in local sessions. The 7d, 30d, and 90d ranges use the matching Codex daily totals. Codex does not provide account-wide model or input/output breakdowns, so this is an extrapolation—not a subscription charge."
                            : "Calculated from local session logs: uncached input × input rate + cached input × cached rate + cache writes × write rate + output × output rate. This is not a subscription charge.",
                        rows: [AccountingRow(label: "Basis", value: selection.usesAccountUsage ? "account total × local rate" : "model rates")],
                        fixedHeight: 98
                    )
                    .frame(width: columnWidth)
                    MetricCard(
                        title: "Total tokens",
                        sourceLabel: selection.usesAccountUsage ? "Account" : "Local",
                        value: billionsCount(selection.totalTokens),
                        detail: periodDetail,
                        helpExamples: tokenVolumeHelpExamples(selection.totalTokens, metric: selection.usesAccountUsage ? .accountTotal : .total),
                        fixedHeight: 98
                    )
                    .frame(width: columnWidth * 2 + spacing)
                }
                HStack(spacing: spacing) {
                    DatasetCard(codex: snapshot.codex, eventCount: selection.eventCount)
                        .frame(width: columnWidth)
                    MetricCard(
                        title: "Input",
                        sourceLabel: "Local",
                        value: compactCount(selection.totals.inputTokens),
                        helpExamples: tokenVolumeHelpExamples(selection.totals.inputTokens, metric: .input),
                        rows: [
                            AccountingRow(label: "Uncached", value: compactCount(selection.totals.billableInputTokens), help: "Input tokens minus cached reads and cache writes."),
                            AccountingRow(label: "Cached", value: compactCount(selection.totals.cachedInputTokens), help: "Input tokens served from the prompt cache."),
                            AccountingRow(label: "Cache writes", value: compactCount(selection.totals.cacheWriteInputTokens), help: "Input tokens written into the prompt cache.")
                        ],
                        fixedHeight: 112
                    )
                    .frame(width: columnWidth)
                    MetricCard(
                        title: "Output",
                        sourceLabel: "Local",
                        value: compactCount(selection.totals.outputTokens),
                        helpExamples: tokenVolumeHelpExamples(selection.totals.outputTokens, metric: .output),
                        rows: [
                            AccountingRow(label: "Reasoning", value: compactCount(selection.totals.reasoningOutputTokens), help: "Internally processed tokens reported as a subset of output.")
                        ],
                        fixedHeight: 112
                    )
                    .frame(width: columnWidth)
                }
            }
        }
        .frame(height: 218)
    }

    private var kimiContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 240), spacing: 10)],
                alignment: .leading,
                spacing: 10
            ) {
                MetricCard(title: "Lowest remaining", value: kimiRemainingText, detail: kimiResetText)
                MetricCard(title: "Quota windows", value: groupedInteger(snapshot.kimi.windows.count), detail: snapshot.kimi.source)
            }
            KimiTablePanel(windows: snapshot.kimi.windows)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var kimiRemainingText: String {
        guard let lowest = snapshot.kimi.windows.min(by: { $0.remainingPercent < $1.remainingPercent }) else { return "--" }
        return "\(lowest.remainingPercent)%"
    }

    private var kimiResetText: String {
        guard let lowest = snapshot.kimi.windows.min(by: { $0.remainingPercent < $1.remainingPercent }) else { return "no quota data" }
        return lowest.resetAt.map { "resets \(dateTimeText($0))" } ?? lowest.label
    }
}

private enum AnalyticsTab: String, CaseIterable, Identifiable {
    case codex = "Codex"
    case kimi = "Kimi"
    var id: String { rawValue }
}

private enum AnalyticsPeriod: String, CaseIterable, Identifiable {
    case sevenDays = "7d"
    case thirtyDays = "30d"
    case ninetyDays = "90d"
    case allTime = "All"

    var id: String { rawValue }
    var label: String { self == .allTime ? "all recorded days" : rawValue }

    func bounds(calendar: Calendar = .autoupdatingCurrent) -> (start: Date?, end: Date?) {
        let today = calendar.startOfDay(for: Date())
        switch self {
        case .sevenDays: return (calendar.date(byAdding: .day, value: -6, to: today), today)
        case .thirtyDays: return (calendar.date(byAdding: .day, value: -29, to: today), today)
        case .ninetyDays: return (calendar.date(byAdding: .day, value: -89, to: today), today)
        case .allTime: return (nil, nil)
        }
    }
}

private enum StatisticsDetailPage: Int, CaseIterable {
    case tables
    case activity

    var label: String {
        switch self {
        case .tables: return "Models + Days"
        case .activity: return "Activity"
        }
    }
}

private struct AnalyticsTabControl: View {
    @Binding var selection: AnalyticsTab

    var body: some View {
        HStack(spacing: 6) {
            ForEach(AnalyticsTab.allCases) { tab in
                Button { selection = tab } label: {
                    Text(tab.rawValue)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(selection == tab ? .white : .primary)
                        .padding(.horizontal, 17)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(selection == tab ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct RefreshStatus: View {
    let progress: UsageAnalyticsLoadProgress
    let refreshedAt: Date?
    let accountRefreshedAt: Date?
    let isRefreshing: Bool
    let refresh: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            HStack(spacing: 9) {
                if isRefreshing {
                    ProgressView(value: progress.fractionCompleted ?? 0)
                        .progressViewStyle(.linear)
                        .frame(width: 90)
                    Text(progress.totalFiles > 0 ? "files \(groupedInteger(progress.processedFiles))/\(groupedInteger(progress.totalFiles))" : "preparing")
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                } else if let duration = progress.lastDuration {
                    Label(durationText(duration), systemImage: "stopwatch")
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                Button(action: refresh) {
                    Image(systemName: "arrow.clockwise").frame(width: 18, height: 18)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isRefreshing)
                .help("Refresh Codex statistics now")
            }

            HStack(spacing: 8) {
                Text(accountRefreshedAt.map { "Account \(dateTimeText($0))" } ?? "Account not synced")
                Text(refreshedAt.map { "Local \(dateTimeText($0))" } ?? "Local not scanned")
            }
            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            .foregroundColor(.secondary)
        }
    }
}

private struct PeriodToolbar: View {
    @Binding var period: AnalyticsPeriod

    var body: some View {
        HStack(spacing: 8) {
            Text("Period").font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary)
            Picker("Period", selection: $period) {
                ForEach(AnalyticsPeriod.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
        }
        .frame(height: 30)
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct DetailPageControl: View {
    @Binding var page: StatisticsDetailPage

    private var index: Int { page.rawValue }

    var body: some View {
        HStack(spacing: 8) {
            Text(page.label)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(.secondary)
            Spacer()
            Button {
                if let previous = StatisticsDetailPage(rawValue: index - 1) { page = previous }
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain)
            .disabled(index == 0)
            .accessibilityLabel("Previous statistics page")

            Text("\(index + 1) / \(StatisticsDetailPage.allCases.count)")
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 36)

            Button {
                if let next = StatisticsDetailPage(rawValue: index + 1) { page = next }
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.plain)
            .disabled(index == StatisticsDetailPage.allCases.count - 1)
            .accessibilityLabel("Next statistics page")
        }
        .frame(height: 20)
    }
}

private struct MetricCard: View {
    let title: String
    let sourceLabel: String?
    let value: String
    let detail: String?
    let fixedHeight: CGFloat?
    var helpExamples = ["Current provider value for this metric."]
    var rows: [AccountingRow] = []

    init(title: String, sourceLabel: String? = nil, value: String, detail: String? = nil, help: String = "Current provider value for this metric.", rows: [AccountingRow] = [], fixedHeight: CGFloat? = nil) {
        self.title = title
        self.sourceLabel = sourceLabel
        self.value = value
        self.detail = detail
        self.fixedHeight = fixedHeight
        helpExamples = [help]
        self.rows = rows
    }

    init(title: String, sourceLabel: String? = nil, value: String, detail: String? = nil, helpExamples: [String], rows: [AccountingRow] = [], fixedHeight: CGFloat? = nil) {
        self.title = title
        self.sourceLabel = sourceLabel
        self.value = value
        self.detail = detail
        self.fixedHeight = fixedHeight
        self.helpExamples = helpExamples
        self.rows = rows
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text(title)
                if let sourceLabel { SourceBadge(text: sourceLabel) }
                HoverInfoTip(texts: helpExamples)
            }
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundColor(.secondary)
            .frame(height: 15, alignment: .leading)
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .frame(height: 22, alignment: .leading)
            if let detail {
                Text(detail)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            if !rows.isEmpty {
                Divider().padding(.vertical, 1)
                ForEach(rows) { row in
                    AccountingRowView(row: row)
                }
            }
        }
        .padding(9)
        .frame(
            minWidth: 0,
            maxWidth: .infinity,
            minHeight: fixedHeight ?? (rows.isEmpty ? 66 : 118),
            maxHeight: fixedHeight,
            alignment: .topLeading
        )
        .panelStyle()
    }
}

private struct DatasetCard: View {
    let codex: CodexUsageAnalytics
    let eventCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Text("Sources")
                HoverInfoTip(text: "Account totals and daily activity come from Codex through your ChatGPT account. Input/output categories, models, events, files, and the blended rate used for cost estimates come from session logs stored on this Mac.")
            }
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                DatasetValue(label: "Total & days", value: codex.accountUsage == nil ? "Local" : "Codex account")
                    .frame(maxWidth: .infinity, alignment: .leading)
                DatasetValue(label: "Details", value: "Local sessions", help: "Input, output, cache, reasoning, models, events, and the blended cost rate are calculated from local session logs.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                DatasetValue(label: "Files", value: groupedInteger(codex.fileCount))
                    .frame(maxWidth: .infinity, alignment: .leading)
                DatasetValue(label: "Events", value: groupedInteger(eventCount), help: "Token-usage samples found in Codex session logs.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, minHeight: 112, maxHeight: 112, alignment: .topLeading)
        .panelStyle()
    }
}

private struct SourceBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 8.5, weight: .semibold))
            .foregroundColor(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color(nsColor: .quaternaryLabelColor).opacity(0.18)))
            .accessibilityLabel("Source: \(text)")
    }
}

private struct DatasetValue: View {
    let label: String
    let value: String
    var help: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(label)
                if let help { HoverInfoTip(text: help) }
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}

private struct AccountingRow: Identifiable {
    let label: String
    let value: String
    var help: String?
    var id: String { label }
}

private struct AccountingRowView: View {
    let row: AccountingRow
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(row.label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(.secondary)
            if let help = row.help { HoverInfoTip(text: help) }
            Spacer(minLength: 4)
            Text(row.value)
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}

private struct HoverInfoTip: View {
    let texts: [String]
    @State private var isPresented = false
    @State private var nextIndex = 0
    @State private var currentText = ""

    init(text: String) {
        texts = [text]
    }

    init(texts: [String]) {
        self.texts = texts
    }

    var body: some View {
        Image(systemName: "info.circle")
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.secondary)
            .onHover { hovering in
                if hovering {
                    let safeTexts = texts.isEmpty ? ["No additional information."] : texts
                    currentText = safeTexts[nextIndex % safeTexts.count]
                    nextIndex = (nextIndex + 1) % safeTexts.count
                }
                isPresented = hovering
            }
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                Text(currentText.isEmpty ? (texts.first ?? "No additional information.") : currentText)
                    .font(.system(size: 11, weight: .medium))
                    .lineSpacing(2)
                    .padding(10)
                    .frame(width: 320, alignment: .leading)
            }
            .accessibilityLabel(texts.first ?? "Additional information")
    }
}

private struct ModelTablePanel: View {
    let models: [ModelUsage]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Text("Models")
                SourceBadge(text: "Local")
                HoverInfoTip(text: "Models and their row estimates come from local sessions. The headline account estimate can be larger because it applies the observed blended local rate to all Codex account tokens. Reasoning is the internally processed subset of output.")
            }
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundColor(.secondary)
            compactModelRow(model: "Model", tokens: "Tokens", reasoning: "Reasoning", estimate: "Estimate", isHeader: true)
            Divider()
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(models) { model in
                        compactModelRow(
                            model: model.model,
                            tokens: compactCount(model.totals.totalTokens),
                            reasoning: compactCount(model.totals.reasoningOutputTokens),
                            estimate: money(model.totals.estimatedCostUSD),
                            isHeader: false
                        )
                        Divider()
                    }
                }
            }
            .frame(height: 160)
        }
        .padding(9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .panelStyle()
    }

    private func compactModelRow(
        model: String,
        tokens: String,
        reasoning: String,
        estimate: String,
        isHeader: Bool
    ) -> some View {
        HStack(spacing: 8) {
            Text(model).frame(minWidth: 110, maxWidth: .infinity, alignment: .leading)
            Text(tokens).frame(width: 76, alignment: .trailing)
            Text(reasoning).frame(width: 78, alignment: .trailing)
            Text(estimate).frame(width: 68, alignment: .trailing)
        }
        .font(.system(size: isHeader ? 10.5 : 11, weight: isHeader ? .semibold : .medium, design: isHeader ? .default : .monospaced))
        .foregroundColor(isHeader ? .secondary : .primary)
        .padding(.horizontal, 4)
        .padding(.vertical, isHeader ? 3 : 5)
    }
}

private struct DailyTablePanel: View {
    let daily: [CodexSelectedDay]
    let usesAccountUsage: Bool
    private var newestFirst: [CodexSelectedDay] {
        Array(daily.filter { $0.tokens > 0 }.reversed())
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Text("Days")
                SourceBadge(text: usesAccountUsage ? "Account" : "Local")
            }
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundColor(.secondary)
            compactDayRow(date: "Date", tokens: "Tokens", estimate: "Estimate", isHeader: true)
            Divider()
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(newestFirst) { day in
                        compactDayRow(
                            date: shortDate(day.day),
                            tokens: compactCount(day.tokens),
                            estimate: day.estimatedCostUSD.map(money) ?? "—",
                            isHeader: false
                        )
                        Divider()
                    }
                }
            }
            .frame(height: 160)
        }
        .padding(9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .panelStyle()
    }

    private func compactDayRow(date: String, tokens: String, estimate: String, isHeader: Bool) -> some View {
        HStack(spacing: 10) {
            Text(date).frame(maxWidth: .infinity, alignment: .leading)
            Text(tokens).frame(width: 105, alignment: .trailing)
            Text(estimate).frame(width: 76, alignment: .trailing)
        }
        .font(.system(size: isHeader ? 10.5 : 11, weight: isHeader ? .semibold : .medium, design: isHeader ? .default : .monospaced))
        .foregroundColor(isHeader ? .secondary : .primary)
        .padding(.horizontal, 4)
        .padding(.vertical, isHeader ? 3 : 5)
    }
}

private struct ActivityHeatmap: View {
    let days: [CodexSelectedDay]
    let sourceLabel: String
    let displayThrough: Date?

    private let cellSize: CGFloat = 9
    private let cellSpacing: CGFloat = 2
    private let monthSpacing: CGFloat = 8

    private var months: [HeatmapMonth] { heatmapMonths(from: days, displayThrough: displayThrough) }
    private var maximumTokens: Int { max(1, days.map(\.tokens).max() ?? 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Text("Activity")
                SourceBadge(text: sourceLabel)
                Spacer()
                Text("Less")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundColor(.secondary)
                ForEach(0..<5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(heatmapColor(level: level))
                        .frame(width: 11, height: 11)
                }
                Text("More")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundColor(.secondary)

            if months.isEmpty {
                Text("No activity in this period")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 90, alignment: .center)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: monthSpacing) {
                            ForEach(months) { month in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(month.label)
                                        .font(.system(size: 9.5, weight: .medium))
                                        .foregroundColor(.secondary)
                                        .frame(width: monthWidth(month), alignment: .center)
                                    HStack(alignment: .top, spacing: cellSpacing) {
                                        ForEach(Array(month.weeks.enumerated()), id: \.offset) { _, week in
                                            VStack(spacing: cellSpacing) {
                                                ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                                                    heatmapCell(day)
                                                }
                                            }
                                        }
                                    }
                                }
                                .id(month.id)
                            }
                        }
                        .padding(.bottom, 2)
                    }
                    .onAppear { scrollToLatestMonth(proxy) }
                    .onChange(of: months.last?.id) { _ in scrollToLatestMonth(proxy) }
                }
            }
        }
        .padding(9)
        .panelStyle()
    }

    @ViewBuilder
    private func heatmapCell(_ day: HeatmapDay?) -> some View {
        if let day {
            let level = heatmapLevel(tokens: day.tokens, maximum: maximumTokens)
            HeatmapCell(day: day, level: level)
        } else {
            Color.clear.frame(width: cellSize, height: cellSize)
        }
    }

    private func monthWidth(_ month: HeatmapMonth) -> CGFloat {
        CGFloat(month.weeks.count) * cellSize + CGFloat(max(0, month.weeks.count - 1)) * cellSpacing
    }

    private func scrollToLatestMonth(_ proxy: ScrollViewProxy) {
        guard let latest = months.last else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(latest.id, anchor: .trailing)
        }
    }
}

private struct HeatmapCell: View {
    let day: HeatmapDay
    let level: Int
    @State private var isPresented = false

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(heatmapColor(level: level))
            .frame(width: 9, height: 9)
            .contentShape(Rectangle())
            .onHover { isPresented = $0 }
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(rangeDate(day.day))
                        .font(.system(size: 11, weight: .semibold))
                    Text("\(millionsCount(day.tokens)) tokens")
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                    Text(day.estimatedCostUSD.map { "\(money($0)) estimated cost" } ?? "Cost estimate unavailable")
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .padding(9)
            }
            .accessibilityLabel(
                "\(rangeDate(day.day)), \(millionsCount(day.tokens)) tokens, "
                    + (day.estimatedCostUSD.map { "\(money($0)) estimated cost" } ?? "cost estimate unavailable")
            )
    }
}

struct HeatmapDay: Equatable {
    let day: Date
    let tokens: Int
    let estimatedCostUSD: Double?
}

struct HeatmapMonth: Identifiable, Equatable {
    let start: Date
    let label: String
    let weeks: [[HeatmapDay?]]
    var id: Date { start }
}

func heatmapHorizon(
    startingAt firstActivity: Date,
    now: Date = Date(),
    calendar suppliedCalendar: Calendar = .autoupdatingCurrent
) -> Date {
    let calendar = suppliedCalendar
    let start = calendar.startOfDay(for: firstActivity)
    let firstAnniversary = calendar.date(byAdding: .year, value: 1, to: start) ?? start
    let firstYearEnd = calendar.date(byAdding: .day, value: -1, to: firstAnniversary) ?? firstAnniversary
    let today = calendar.startOfDay(for: now)
    guard today > firstYearEnd,
          let currentMonth = calendar.dateInterval(of: .month, for: today),
          let currentMonthEnd = calendar.date(byAdding: .day, value: -1, to: currentMonth.end)
    else { return firstYearEnd }
    return currentMonthEnd
}

func heatmapMonths(
    from selectedDays: [CodexSelectedDay],
    displayThrough: Date? = nil,
    calendar suppliedCalendar: Calendar = .autoupdatingCurrent
) -> [HeatmapMonth] {
    guard let first = selectedDays.map(\.day).min(), let last = selectedDays.map(\.day).max() else { return [] }
    var calendar = suppliedCalendar
    calendar.firstWeekday = 1
    let firstDay = calendar.startOfDay(for: first)
    let lastDay = calendar.startOfDay(for: max(last, displayThrough ?? last))
    guard var monthStart = calendar.dateInterval(of: .month, for: firstDay)?.start,
          let finalMonthStart = calendar.dateInterval(of: .month, for: lastDay)?.start else { return [] }
    let usageByDay = Dictionary(uniqueKeysWithValues: selectedDays.map {
        (calendar.startOfDay(for: $0.day), ($0.tokens, $0.estimatedCostUSD))
    })
    var result: [HeatmapMonth] = []
    while monthStart <= finalMonthStart {
        guard let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStart),
              let monthEnd = calendar.date(byAdding: .day, value: -1, to: nextMonth),
              let firstWeek = calendar.dateInterval(of: .weekOfYear, for: monthStart)?.start,
              let lastWeek = calendar.dateInterval(of: .weekOfYear, for: monthEnd)?.start else { break }
        var weeks: [[HeatmapDay?]] = []
        var weekStart = firstWeek
        while weekStart <= lastWeek {
            let weekDays: [HeatmapDay?] = (0..<7).map { offset in
                guard let day = calendar.date(byAdding: .day, value: offset, to: weekStart),
                      day >= firstDay,
                      day <= lastDay,
                      calendar.isDate(day, equalTo: monthStart, toGranularity: .month) else { return nil }
                let usage = usageByDay[day]
                return HeatmapDay(day: day, tokens: usage?.0 ?? 0, estimatedCostUSD: usage?.1)
            }
            weeks.append(weekDays)
            guard let nextWeek = calendar.date(byAdding: .day, value: 7, to: weekStart) else { break }
            weekStart = nextWeek
        }
        result.append(HeatmapMonth(
            start: monthStart,
            label: monthStart.formatted(.dateTime.month(.abbreviated)),
            weeks: weeks
        ))
        monthStart = nextMonth
    }
    return result
}

func heatmapLevel(tokens: Int, maximum: Int) -> Int {
    guard tokens > 0, maximum > 0 else { return 0 }
    return min(4, max(1, Int(ceil(Double(tokens) / Double(maximum) * 4))))
}

private func heatmapColor(level: Int) -> Color {
    switch level {
    case 1: return Color.accentColor.opacity(0.25)
    case 2: return Color.accentColor.opacity(0.45)
    case 3: return Color.accentColor.opacity(0.70)
    case 4: return Color.accentColor
    default: return Color(nsColor: .separatorColor).opacity(0.35)
    }
}

private struct KimiTablePanel: View {
    let windows: [KimiQuotaWindow]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quota windows").font(.system(size: 12.5, weight: .semibold)).foregroundColor(.secondary)
            Table(windows) {
                TableColumn("Window", value: \.label)
                TableColumn("Usage") { Text(usageText($0)).monospacedDigit() }
                TableColumn("Remaining") { Text("\($0.remainingPercent)%").monospacedDigit() }
                TableColumn("Reset") { Text($0.resetAt.map(dateTimeText) ?? "unknown") }
            }
            .frame(minHeight: 190)
        }
        .padding(12)
        .panelStyle()
    }

    private func usageText(_ window: KimiQuotaWindow) -> String {
        guard let used = window.used, let limit = window.limit else { return "unknown" }
        return "\(groupedInteger(used))/\(groupedInteger(limit))"
    }
}

struct CodexUsageSelection: Equatable {
    let totals: UsageTotals
    let totalTokens: Int
    let estimatedCostUSD: Double
    let daily: [CodexSelectedDay]
    let models: [ModelUsage]
    let eventCount: Int
    let usesAccountUsage: Bool
}

struct CodexSelectedDay: Identifiable, Equatable {
    let day: Date
    let tokens: Int
    let estimatedCostUSD: Double?

    var id: Date { day }
}

func codexUsageSelection(
    from codex: CodexUsageAnalytics,
    start: Date?,
    end: Date?,
    calendar: Calendar = .autoupdatingCurrent
) -> CodexUsageSelection {
    let startDay = start.map { calendar.startOfDay(for: $0) }
    let endDay = end.map { calendar.startOfDay(for: $0) }
    let includes: (Date) -> Bool = { date in
        let day = calendar.startOfDay(for: date)
        return (startDay == nil || day >= startDay!) && (endDay == nil || day <= endDay!)
    }

    let localDaily = codex.daily.filter { includes($0.day) }
    let selectedDailyModels = codex.dailyModels.filter { includes($0.day) }
    let totals = localDaily.reduce(into: UsageTotals.zero) { $0.add($1.totals) }
    var modelBuckets: [String: ModelUsage] = [:]
    for usage in selectedDailyModels {
        if modelBuckets[usage.model] == nil {
            modelBuckets[usage.model] = ModelUsage(model: usage.model, totals: .zero, events: 0)
        }
        modelBuckets[usage.model]?.totals.add(usage.totals)
        modelBuckets[usage.model]?.events += usage.events
    }
    let models = modelBuckets.values.sorted {
        if $0.totals.estimatedCostUSD != $1.totals.estimatedCostUSD { return $0.totals.estimatedCostUSD > $1.totals.estimatedCostUSD }
        return $0.totals.totalTokens > $1.totals.totalTokens
    }
    let isAllTime = startDay == nil && endDay == nil
    let selectedTotals = isAllTime && localDaily.isEmpty ? codex.total : totals
    let accountDaily = codex.accountUsage?.daily.filter { includes($0.day) }
    let rateBasisTotals = selectedTotals.totalTokens > 0 ? selectedTotals : codex.total
    let blendedCostPerToken = rateBasisTotals.totalTokens > 0
        ? rateBasisTotals.estimatedCostUSD / Double(rateBasisTotals.totalTokens)
        : 0
    let displayDaily: [CodexSelectedDay]
    if let accountDaily {
        displayDaily = accountDaily.map { usage in
            return CodexSelectedDay(
                day: usage.day,
                tokens: usage.tokens,
                estimatedCostUSD: blendedCostPerToken > 0 ? Double(usage.tokens) * blendedCostPerToken : nil
            )
        }
    } else {
        displayDaily = localDaily.map {
            CodexSelectedDay(day: $0.day, tokens: $0.totals.totalTokens, estimatedCostUSD: $0.totals.estimatedCostUSD)
        }
    }
    let accountTotal = isAllTime
        ? codex.accountUsage?.lifetimeTokens
        : accountDaily?.reduce(0) { $0 + $1.tokens }
    return CodexUsageSelection(
        totals: selectedTotals,
        totalTokens: accountTotal ?? selectedTotals.totalTokens,
        estimatedCostUSD: accountTotal.map { Double($0) * blendedCostPerToken } ?? selectedTotals.estimatedCostUSD,
        daily: displayDaily,
        models: selectedDailyModels.isEmpty && isAllTime ? codex.models : models,
        eventCount: selectedDailyModels.isEmpty && isAllTime ? codex.eventCount : selectedDailyModels.reduce(0) { $0 + $1.events },
        usesAccountUsage: codex.accountUsage != nil
    )
}

private extension View {
    func panelStyle() -> some View {
        background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
    }
}

func compactCount(_ value: Int) -> String {
    let absolute = abs(value)
    if absolute >= 1_000_000 { return "\(formattedNumber(Double(value) / 1_000_000, fractionDigits: 2))M" }
    if absolute >= 1_000 { return "\(formattedNumber(Double(value) / 1_000, fractionDigits: 1))K" }
    return groupedInteger(value)
}

func billionsCount(_ value: Int) -> String {
    "\(formattedNumber(Double(value) / 1_000_000_000, fractionDigits: 2))B"
}

func millionsCount(_ value: Int) -> String {
    "\(formattedNumber(Double(value) / 1_000_000, fractionDigits: 2))M"
}

func money(_ value: Double) -> String {
    let absolute = abs(value)
    if absolute >= 100 { return "$\(formattedNumber(value, fractionDigits: 0))" }
    if absolute >= 10 { return "$\(formattedNumber(value, fractionDigits: 1))" }
    return "$\(formattedNumber(value, fractionDigits: 2))"
}

private func durationText(_ value: TimeInterval) -> String {
    if value < 1 { return "\(formattedNumber(value * 1_000, fractionDigits: 0))ms" }
    if value < 10 { return "\(formattedNumber(value, fractionDigits: 2))s" }
    return "\(formattedNumber(value, fractionDigits: 1))s"
}

private func shortDate(_ date: Date) -> String {
    date.formatted(.dateTime.month(.abbreviated).day())
}

private func rangeDate(_ date: Date) -> String {
    date.formatted(.dateTime.year().month(.abbreviated).day())
}

struct BookTokenComparison: Equatable {
    let title: String
    let approximateWords: Int
}

let bookTokenComparisons: [BookTokenComparison] = [
    BookTokenComparison(title: "The Little Prince", approximateWords: 16_500),
    BookTokenComparison(title: "The Hobbit", approximateWords: 95_000),
    BookTokenComparison(title: "the complete Lord of the Rings trilogy", approximateWords: 481_000),
    BookTokenComparison(title: "the complete seven-book Harry Potter series", approximateWords: 1_084_000),
    BookTokenComparison(title: "Dune", approximateWords: 188_000),
    BookTokenComparison(title: "1984", approximateWords: 89_000),
    BookTokenComparison(title: "Brave New World", approximateWords: 64_000),
    BookTokenComparison(title: "A Game of Thrones", approximateWords: 298_000),
    BookTokenComparison(title: "The Name of the Wind", approximateWords: 259_000),
    BookTokenComparison(title: "American Gods", approximateWords: 183_000),
    BookTokenComparison(title: "The Hitchhiker's Guide to the Galaxy", approximateWords: 46_000),
    BookTokenComparison(title: "Ender's Game", approximateWords: 101_000),
    BookTokenComparison(title: "Neuromancer", approximateWords: 79_000),
    BookTokenComparison(title: "The Martian", approximateWords: 105_000),
    BookTokenComparison(title: "Fahrenheit 451", approximateWords: 46_000)
]

enum TokenHelpMetric {
    case accountTotal
    case total
    case input
    case output

    var explanation: String {
        switch self {
        case .accountTotal:
            return "Account-wide Codex token activity reported by OpenAI. It follows your ChatGPT account and can include work whose session files are no longer stored on this Mac. OpenAI does not split this account total into input, output, or models here."
        case .total:
            return "Total tokens cover everything the model processed—not only what you typed. Total is Input + Output."
        case .input:
            return "Input tokens cover everything the model read: your messages, instructions, earlier conversation, files, tool results, and cached context."
        case .output:
            return "Output tokens cover everything the model generated: replies and actions returned to you, plus internal reasoning reported by Codex. Reasoning is usually not visible."
        }
    }

    var cacheNote: String {
        switch self {
        case .accountTotal, .total, .input:
            return " Cached context can be counted repeatedly, so this is processed text rather than unique reading."
        case .output:
            return ""
        }
    }
}

func tokenVolumeHelpExamples(_ tokens: Int, metric: TokenHelpMetric = .total) -> [String] {
    let words = Double(max(0, tokens)) * 0.75
    return bookTokenComparisons.map { book in
        let copies = words / Double(book.approximateWords)
        let formattedWords = groupedInteger(book.approximateWords)
        let comparison = bookCopyComparison(copies, title: book.title)
        return "\(metric.explanation)\n\nFor a sense of scale, that is \(comparison) (~\(formattedWords) words each). Book lengths and the token-to-text conversion are approximate.\(metric.cacheNote) Hover again for another book."
    }
}

func bookCopyComparison(_ copies: Double, title: String) -> String {
    guard copies >= 0.5 else { return "less than one copy of \(title)" }
    let roundedCopies = Int(copies.rounded())
    if roundedCopies == 1 { return "roughly one copy of \(title)" }
    return "roughly \(groupedInteger(roundedCopies)) copies of \(title)"
}

func groupedInteger(_ value: Int) -> String {
    formattedNumber(Double(value), fractionDigits: 0)
}

private func formattedNumber(_ value: Double, fractionDigits: Int) -> String {
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.numberStyle = .decimal
    formatter.usesGroupingSeparator = true
    formatter.groupingSeparator = " "
    formatter.groupingSize = 3
    formatter.secondaryGroupingSize = 3
    formatter.decimalSeparator = "."
    formatter.minimumFractionDigits = fractionDigits
    formatter.maximumFractionDigits = fractionDigits
    return formatter.string(from: NSNumber(value: value)) ?? String(value)
}

private func dateTimeText(_ date: Date) -> String {
    date.formatted(.dateTime.month(.abbreviated).day().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
}
