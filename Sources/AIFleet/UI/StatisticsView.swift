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
        VStack(alignment: .leading, spacing: 10) {
            header
            switch tab {
            case .codex: codexContent
            case .kimi: kimiContent
            }
        }
        .padding(18)
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
        VStack(alignment: .leading, spacing: 10) {
            PeriodToolbar(
                period: $period,
                customStart: $customStart,
                customEnd: $customEnd
            )

            HStack(spacing: 10) {
                MetricCard(title: "Total tokens", value: compactCount(selection.totals.totalTokens), detail: period.label)
                MetricCard(title: "Input", value: compactCount(selection.totals.inputTokens), detail: "uncached \(compactCount(selection.totals.billableInputTokens))")
                MetricCard(title: "Output", value: compactCount(selection.totals.outputTokens), detail: "reasoning \(compactCount(selection.totals.reasoningOutputTokens))")
                MetricCard(title: "Estimate", value: money(selection.totals.estimatedCostUSD), detail: "API-equivalent")
            }

            HeatmapSection(daily: selection.daily)
            DatasetPanel(codex: snapshot.codex, selection: selection)

            HStack(alignment: .top, spacing: 10) {
                ModelTablePanel(models: selection.models)
                    .frame(minWidth: 430, maxWidth: .infinity)
                DailyTablePanel(daily: selection.daily)
                    .frame(minWidth: 330, maxWidth: .infinity)
            }
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
        .padding(8)
        .panelStyle()
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundColor(.secondary)
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
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
        .panelStyle()
    }
}

private struct DatasetPanel: View {
    let codex: CodexUsageAnalytics
    let selection: CodexUsageSelection

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Dataset & accounting").font(.system(size: 12.5, weight: .semibold)).foregroundColor(.secondary)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 180), spacing: 12)],
                alignment: .leading,
                spacing: 6
            ) {
                DatasetItem(label: "Source", value: codex.source)
                DatasetItem(label: "Files", value: "\(codex.fileCount)")
                DatasetItem(label: "Events", value: "\(selection.eventCount)")
                DatasetItem(label: "Uncached input", value: compactCount(selection.totals.billableInputTokens), help: "Input tokens minus cached-input reads and cache-write tokens.")
                DatasetItem(label: "Cached input", value: compactCount(selection.totals.cachedInputTokens), help: "Input tokens served from the prompt cache.")
                DatasetItem(label: "Cache writes", value: compactCount(selection.totals.cacheWriteInputTokens), help: "Input tokens written into the prompt cache.")
                DatasetItem(label: "Reasoning output", value: compactCount(selection.totals.reasoningOutputTokens), help: "The reasoning-token subset reported inside output usage.")
                DatasetItem(label: "Cost estimate", value: money(selection.totals.estimatedCostUSD), help: "API-equivalent estimate from model-specific input, cache and output rates; not a subscription bill.")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelStyle()
    }
}

private struct DatasetItem: View {
    let label: String
    let value: String
    var help: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(label):").font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
            if let help { HoverInfoTip(text: help) }
            Spacer(minLength: 6)
            Text(value)
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
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

private struct HeatmapSection: View {
    let daily: [DailyUsage]
    private var maxTokens: Int { max(1, daily.map(\.totals.totalTokens).max() ?? 1) }

    private var cells: [HeatmapCell] {
        guard let first = daily.first else { return [] }
        let calendar = Calendar.autoupdatingCurrent
        let leading = (calendar.component(.weekday, from: first.day) - calendar.firstWeekday + 7) % 7
        let blanks = (0..<leading).map { HeatmapCell(id: "blank-\($0)", usage: nil) }
        return blanks + daily.map { HeatmapCell(id: "day-\($0.day.timeIntervalSince1970)", usage: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Activity").font(.system(size: 12.5, weight: .semibold)).foregroundColor(.secondary)
                Spacer()
                HeatmapLegend()
            }
            if cells.isEmpty {
                Text("No Codex usage in this period")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 74, alignment: .center)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        LazyHGrid(rows: Array(repeating: GridItem(.fixed(10), spacing: 2), count: 7), spacing: 2) {
                            ForEach(cells) { cell in heatmapSquare(cell).id(cell.id) }
                        }
                        .padding(.vertical, 2)
                    }
                    .onAppear { scrollToLatest(proxy) }
                    .onChange(of: cells.last?.id) { _ in scrollToLatest(proxy) }
                }
                .frame(height: 82)
            }
        }
        .padding(10)
        .panelStyle()
    }

    @ViewBuilder
    private func heatmapSquare(_ cell: HeatmapCell) -> some View {
        if let usage = cell.usage {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(heatmapColor(tokens: usage.totals.totalTokens))
                .frame(width: 10, height: 10)
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
                .help("\(shortDate(usage.day)): \(compactCount(usage.totals.totalTokens)) tokens · \(money(usage.totals.estimatedCostUSD))")
        } else {
            Color.clear.frame(width: 10, height: 10)
        }
    }

    private func heatmapColor(tokens: Int) -> Color {
        guard tokens > 0 else { return Color(nsColor: .quaternaryLabelColor).opacity(0.22) }
        let level = min(4, max(1, Int(ceil(Double(tokens) / Double(maxTokens) * 4))))
        return Color.accentColor.opacity([0, 0.28, 0.46, 0.68, 0.92][level])
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        guard let last = cells.last else { return }
        DispatchQueue.main.async { proxy.scrollTo(last.id, anchor: .trailing) }
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
        VStack(alignment: .leading, spacing: 8) {
            Text("Models").font(.system(size: 12.5, weight: .semibold)).foregroundColor(.secondary)
            Table(models) {
                TableColumn("Model", value: \.model)
                TableColumn("Tokens") { Text(compactCount($0.totals.totalTokens)).monospacedDigit() }
                TableColumn("Reasoning") { Text(compactCount($0.totals.reasoningOutputTokens)).monospacedDigit() }
                TableColumn("Estimate") { Text(money($0.totals.estimatedCostUSD)).monospacedDigit() }
                TableColumn("Events") { Text("\($0.events)").monospacedDigit() }
            }
            .frame(height: 150)
        }
        .padding(10)
        .panelStyle()
    }
}

private struct DailyTablePanel: View {
    let daily: [DailyUsage]
    private var newestFirst: [DailyUsage] { Array(daily.reversed()) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Days").font(.system(size: 12.5, weight: .semibold)).foregroundColor(.secondary)
            Table(newestFirst) {
                TableColumn("Date") { Text(shortDate($0.day)) }
                TableColumn("Tokens") { Text(compactCount($0.totals.totalTokens)).monospacedDigit() }
                TableColumn("Reasoning") { Text(compactCount($0.totals.reasoningOutputTokens)).monospacedDigit() }
                TableColumn("Estimate") { Text(money($0.totals.estimatedCostUSD)).monospacedDigit() }
            }
            .frame(height: 150)
        }
        .padding(10)
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
