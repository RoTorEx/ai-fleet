import SwiftUI

struct StatisticsView: View {
    @ObservedObject private var analytics = UsageAnalyticsService.shared
    @ObservedObject private var service = StatusService.shared
    @State private var tab: AnalyticsTab = .codex
    @State private var period: AnalyticsPeriod = .allTime
    @State private var customStart = Calendar.autoupdatingCurrent.date(
        byAdding: .day,
        value: -29,
        to: Calendar.autoupdatingCurrent.startOfDay(for: Date())
    ) ?? Calendar.autoupdatingCurrent.startOfDay(for: Date())
    @State private var customEnd = Calendar.autoupdatingCurrent.startOfDay(for: Date())

    private var snapshot: UsageAnalyticsSnapshot { analytics.snapshot }

    private var selection: CodexUsageSelection {
        let bounds = period.bounds(customStart: customStart, customEnd: customEnd)
        return codexUsageSelection(from: snapshot.codex, start: bounds.start, end: bounds.end)
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
        .onAppear { analytics.updateKimi(kimi: service.kimi) }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            AnalyticsTabControl(selection: $tab)
            Spacer(minLength: 20)
            RefreshStatus(
                progress: analytics.progress,
                refreshedAt: snapshot.refreshedAt,
                isRefreshing: analytics.isRefreshing,
                refresh: { analytics.refresh(kimi: service.kimi) }
            )
        }
    }

    private var codexContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            PeriodToolbar(
                period: $period,
                customStart: $customStart,
                customEnd: $customEnd
            )

            HStack(spacing: 8) {
                MetricCard(
                    title: "Total tokens",
                    value: compactCount(selection.totals.totalTokens),
                    detail: period.label,
                    help: "Input tokens plus output tokens for the selected period."
                )
                MetricCard(
                    title: "Input",
                    value: compactCount(selection.totals.inputTokens),
                    detail: "uncached \(compactCount(selection.totals.billableInputTokens))",
                    help: "All input tokens reported by Codex, including cached reads and cache writes."
                )
                MetricCard(
                    title: "Output",
                    value: compactCount(selection.totals.outputTokens),
                    detail: "reasoning \(compactCount(selection.totals.reasoningOutputTokens))",
                    help: "Generated output tokens. Reasoning is the internally processed subset reported by Codex."
                )
                MetricCard(
                    title: "Estimate",
                    value: money(selection.totals.estimatedCostUSD),
                    detail: "API-equivalent",
                    help: "Estimated API cost from model-specific input, cache and output rates; not a subscription charge."
                )
            }

            DatasetPanel(codex: snapshot.codex, selection: selection)

            HStack(alignment: .top, spacing: 10) {
                ModelTablePanel(models: selection.models)
                    .frame(minWidth: 430, maxWidth: .infinity)
                DailyTablePanel(daily: selection.daily)
                    .frame(minWidth: 330, maxWidth: .infinity)
            }

            HeatmapSection(daily: selection.daily)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var kimiContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 240), spacing: 10)],
                alignment: .leading,
                spacing: 10
            ) {
                MetricCard(title: "Lowest remaining", value: kimiRemainingText, detail: kimiResetText)
                MetricCard(title: "Quota windows", value: "\(snapshot.kimi.windows.count)", detail: snapshot.kimi.source)
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
    case custom = "Custom"

    var id: String { rawValue }
    var label: String { self == .allTime ? "all recorded days" : rawValue }

    func bounds(customStart: Date, customEnd: Date, calendar: Calendar = .autoupdatingCurrent) -> (start: Date?, end: Date?) {
        let today = calendar.startOfDay(for: Date())
        switch self {
        case .sevenDays: return (calendar.date(byAdding: .day, value: -6, to: today), today)
        case .thirtyDays: return (calendar.date(byAdding: .day, value: -29, to: today), today)
        case .ninetyDays: return (calendar.date(byAdding: .day, value: -89, to: today), today)
        case .allTime: return (nil, nil)
        case .custom:
            return (
                calendar.startOfDay(for: min(customStart, customEnd)),
                calendar.startOfDay(for: max(customStart, customEnd))
            )
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
    let isRefreshing: Bool
    let refresh: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            HStack(spacing: 9) {
                if isRefreshing {
                    ProgressView(value: progress.fractionCompleted ?? 0)
                        .progressViewStyle(.linear)
                        .frame(width: 90)
                    Text(progress.totalFiles > 0 ? "\(progress.processedFiles)/\(progress.totalFiles)" : "preparing")
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

            Text(refreshedAt.map { "Last updated \(dateTimeText($0))" } ?? "Not updated yet")
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
        }
    }
}

private struct PeriodToolbar: View {
    @Binding var period: AnalyticsPeriod
    @Binding var customStart: Date
    @Binding var customEnd: Date

    var body: some View {
        HStack(spacing: 12) {
            Text("Period").font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary)
            Picker("Period", selection: $period) {
                ForEach(AnalyticsPeriod.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: period == .custom ? 330 : 420)
            if period == .custom {
                DatePicker("From", selection: $customStart, displayedComponents: .date)
                DatePicker("To", selection: $customEnd, displayedComponents: .date)
                .font(.system(size: 11, weight: .medium))
            }
            Spacer()
        }
        .frame(height: 30)
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let detail: String
    var help = "Current provider value for this metric."

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text(title)
                HoverInfoTip(text: help)
            }
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(detail)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(9)
        .frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
        .panelStyle()
    }
}

private struct DatasetPanel: View {
    let codex: CodexUsageAnalytics
    let selection: CodexUsageSelection

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Dataset & accounting").font(.system(size: 12.5, weight: .semibold)).foregroundColor(.secondary)
            HStack(alignment: .top, spacing: 10) {
                AccountingGroup(title: "Data", rows: [
                    AccountingRow(label: "Source", value: codex.source),
                    AccountingRow(label: "Files", value: "\(codex.fileCount)"),
                    AccountingRow(label: "Events", value: "\(selection.eventCount)", help: "Token-usage samples found in Codex session logs.")
                ])
                Divider()
                AccountingGroup(title: "Input", rows: [
                    AccountingRow(label: "Uncached", value: compactCount(selection.totals.billableInputTokens), help: "Input tokens minus cached reads and cache writes."),
                    AccountingRow(label: "Cached", value: compactCount(selection.totals.cachedInputTokens), help: "Input tokens served from the prompt cache."),
                    AccountingRow(label: "Cache writes", value: compactCount(selection.totals.cacheWriteInputTokens), help: "Input tokens written into the prompt cache.")
                ])
                Divider()
                AccountingGroup(title: "Output", rows: [
                    AccountingRow(label: "Generated", value: compactCount(selection.totals.outputTokens)),
                    AccountingRow(label: "Reasoning", value: compactCount(selection.totals.reasoningOutputTokens), help: "Internally processed tokens reported as a subset of output.")
                ])
                Divider()
                AccountingGroup(title: "Estimate", rows: [
                    AccountingRow(label: "API-equivalent", value: money(selection.totals.estimatedCostUSD), help: "Model-rate estimate; not a subscription bill."),
                    AccountingRow(label: "Basis", value: "model rates")
                ])
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelStyle()
    }
}

private struct AccountingRow: Identifiable {
    let label: String
    let value: String
    var help: String?
    var id: String { label }
}

private struct AccountingGroup: View {
    let title: String
    let rows: [AccountingRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .bold))
                .foregroundColor(Color(nsColor: .tertiaryLabelColor))
            ForEach(rows) { row in
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
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct HoverInfoTip: View {
    let text: String
    @State private var isPresented = false

    var body: some View {
        Image(systemName: "info.circle")
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.secondary)
            .onHover { isPresented = $0 }
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                Text(text).font(.system(size: 11, weight: .medium)).padding(10).frame(width: 260, alignment: .leading)
            }
            .accessibilityLabel(text)
    }
}

private struct HeatmapCell: Identifiable {
    let id: String
    let usage: DailyUsage?
}

private struct HeatmapMonthGroup: Identifiable {
    let id: Date
    let label: String
    let cells: [HeatmapCell]

    var width: CGFloat {
        CGFloat(max(1, Int(ceil(Double(cells.count) / 7.0)))) * 12 - 2
    }
}

private struct HeatmapSection: View {
    let daily: [DailyUsage]
    private var maxTokens: Int { max(1, daily.map(\.totals.totalTokens).max() ?? 1) }

    private var months: [HeatmapMonthGroup] {
        let calendar = Calendar.autoupdatingCurrent
        let grouped = Dictionary(grouping: daily) { usage in
            let parts = calendar.dateComponents([.year, .month], from: usage.day)
            return calendar.date(from: parts) ?? calendar.startOfDay(for: usage.day)
        }
        return grouped.keys.sorted().map { month in
            let values = (grouped[month] ?? []).sorted { $0.day < $1.day }
            let weekdayOffset = (calendar.component(.weekday, from: month) - calendar.firstWeekday + 7) % 7
            let daysBeforeSelection = max(0, (values.first.map { calendar.component(.day, from: $0.day) } ?? 1) - 1)
            let leading = weekdayOffset + daysBeforeSelection
            let blanks = (0..<leading).map { HeatmapCell(id: "blank-\(month.timeIntervalSince1970)-\($0)", usage: nil) }
            return HeatmapMonthGroup(
                id: month,
                label: month.formatted(.dateTime.month(.abbreviated)),
                cells: blanks + values.map { HeatmapCell(id: "day-\($0.day.timeIntervalSince1970)", usage: $0) }
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Activity").font(.system(size: 12.5, weight: .semibold)).foregroundColor(.secondary)
                Spacer()
                HeatmapLegend()
            }
            if months.isEmpty {
                Text("No Codex usage in this period")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 74, alignment: .center)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: months.count > 8) {
                        HStack(alignment: .top, spacing: 14) {
                            ForEach(months) { month in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(month.label)
                                        .font(.system(size: 9.5, weight: .semibold))
                                        .foregroundColor(.secondary)
                                    LazyHGrid(rows: Array(repeating: GridItem(.fixed(10), spacing: 2), count: 7), spacing: 2) {
                                        ForEach(month.cells) { cell in
                                            HeatmapDayCell(cell: cell, maxTokens: maxTokens)
                                                .id(cell.id)
                                        }
                                    }
                                    .frame(width: month.width, height: 82, alignment: .leading)
                                }
                                .id(month.id)
                            }
                        }
                        .padding(.vertical, 1)
                    }
                    .onAppear { scrollToLatest(proxy) }
                    .onChange(of: months.last?.id) { _ in scrollToLatest(proxy) }
                }
                .frame(height: 100)
            }
        }
        .padding(9)
        .panelStyle()
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        guard let last = months.last else { return }
        DispatchQueue.main.async { proxy.scrollTo(last.id, anchor: .trailing) }
    }
}

private struct HeatmapDayCell: View {
    let cell: HeatmapCell
    let maxTokens: Int
    @State private var showsDetails = false

    var body: some View {
        Group {
            if let usage = cell.usage {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(heatmapColor(tokens: usage.totals.totalTokens))
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
                    .onHover { showsDetails = $0 }
                    .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(usage.day.formatted(.dateTime.weekday(.wide).month(.wide).day().year()))
                                .font(.system(size: 11, weight: .semibold))
                            Text("Activity: \(compactCount(usage.totals.totalTokens)) tokens")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                            Text("Estimate: \(money(usage.totals.estimatedCostUSD))")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                        .padding(10)
                    }
            } else {
                Color.clear
            }
        }
        .frame(width: 10, height: 10)
    }

    private func heatmapColor(tokens: Int) -> Color {
        guard tokens > 0 else { return Color(nsColor: .quaternaryLabelColor).opacity(0.22) }
        let level = min(4, max(1, Int(ceil(Double(tokens) / Double(maxTokens) * 4))))
        return Color.accentColor.opacity([0, 0.28, 0.46, 0.68, 0.92][level])
    }
}

private struct HeatmapLegend: View {
    var body: some View {
        HStack(spacing: 4) {
            Text("Less")
            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2)
                    .fill(level == 0 ? Color(nsColor: .quaternaryLabelColor).opacity(0.22) : Color.accentColor.opacity(Double(level) * 0.2 + 0.12))
                    .frame(width: 10, height: 10)
            }
            Text("More")
        }
        .font(.system(size: 9.5, weight: .medium))
        .foregroundColor(.secondary)
    }
}

private struct ModelTablePanel: View {
    let models: [ModelUsage]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Text("Models")
                HoverInfoTip(text: "Reasoning is the internally processed subset of output. Showing it by model reveals which models consume those less-visible tokens.")
            }
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundColor(.secondary)
            Table(models) {
                TableColumn("Model", value: \.model).width(min: 125, ideal: 150)
                TableColumn("Tokens") { Text(compactCount($0.totals.totalTokens)).monospacedDigit() }.width(min: 75, ideal: 90)
                TableColumn("Reasoning") { Text(compactCount($0.totals.reasoningOutputTokens)).monospacedDigit() }.width(min: 82, ideal: 95)
                TableColumn("Estimate") { Text(money($0.totals.estimatedCostUSD)).monospacedDigit() }.width(min: 70, ideal: 80)
            }
            .frame(height: 122)
        }
        .padding(9)
        .panelStyle()
    }
}

private struct DailyTablePanel: View {
    let daily: [DailyUsage]
    private var newestFirst: [DailyUsage] { Array(daily.reversed()) }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Days").font(.system(size: 12.5, weight: .semibold)).foregroundColor(.secondary)
            Table(newestFirst) {
                TableColumn("Date") { Text(shortDate($0.day)) }.width(min: 80, ideal: 95)
                TableColumn("Tokens") { Text(compactCount($0.totals.totalTokens)).monospacedDigit() }.width(min: 90, ideal: 110)
                TableColumn("Estimate") { Text(money($0.totals.estimatedCostUSD)).monospacedDigit() }.width(min: 75, ideal: 90)
            }
            .frame(height: 122)
        }
        .padding(9)
        .panelStyle()
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
        return "\(used)/\(limit)"
    }
}

struct CodexUsageSelection: Equatable {
    let totals: UsageTotals
    let daily: [DailyUsage]
    let models: [ModelUsage]
    let eventCount: Int
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

    let daily = codex.daily.filter { includes($0.day) }
    let selectedDailyModels = codex.dailyModels.filter { includes($0.day) }
    let totals = daily.reduce(into: UsageTotals.zero) { $0.add($1.totals) }
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
    return CodexUsageSelection(
        totals: isAllTime && daily.isEmpty ? codex.total : totals,
        daily: daily,
        models: selectedDailyModels.isEmpty && isAllTime ? codex.models : models,
        eventCount: selectedDailyModels.isEmpty && isAllTime ? codex.eventCount : selectedDailyModels.reduce(0) { $0 + $1.events }
    )
}

private extension View {
    func panelStyle() -> some View {
        background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
    }
}

private func compactCount(_ value: Int) -> String {
    let absolute = abs(value)
    if absolute >= 1_000_000 { return String(format: "%.2fM", Double(value) / 1_000_000) }
    if absolute >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
    return "\(value)"
}

private func money(_ value: Double) -> String {
    if value >= 100 { return String(format: "$%.0f", value) }
    if value >= 10 { return String(format: "$%.1f", value) }
    return String(format: "$%.2f", value)
}

private func durationText(_ value: TimeInterval) -> String {
    if value < 1 { return String(format: "%.0fms", value * 1_000) }
    if value < 10 { return String(format: "%.2fs", value) }
    return String(format: "%.1fs", value)
}

private func shortDate(_ date: Date) -> String {
    date.formatted(.dateTime.month(.abbreviated).day())
}

private func dateTimeText(_ date: Date) -> String {
    date.formatted(.dateTime.month(.abbreviated).day().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
}
