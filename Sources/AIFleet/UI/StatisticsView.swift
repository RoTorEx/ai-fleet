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
                    detail: periodDetail,
                    helpExamples: tokenVolumeHelpExamples(selection.totals.totalTokens)
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
                    help: "Sum of the per-model estimates below. For each model: uncached input × input rate + cached input × cached rate + cache writes × write rate + output × output rate. Rounded table rows can differ slightly from this total. This is not a subscription charge."
                )
            }

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
                    Text(progress.totalFiles > 0 ? "files \(progress.processedFiles)/\(progress.totalFiles)" : "preparing")
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
    var helpExamples = ["Current provider value for this metric."]

    init(title: String, value: String, detail: String, help: String = "Current provider value for this metric.") {
        self.title = title
        self.value = value
        self.detail = detail
        helpExamples = [help]
    }

    init(title: String, value: String, detail: String, helpExamples: [String]) {
        self.title = title
        self.value = value
        self.detail = detail
        self.helpExamples = helpExamples
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text(title)
                HoverInfoTip(texts: helpExamples)
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
        .fixedSize(horizontal: false, vertical: true)
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
                    .padding(10)
                    .frame(width: 310, alignment: .leading)
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
                HoverInfoTip(text: "Reasoning is the internally processed subset of output. Showing it by model reveals which models consume those less-visible tokens.")
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
            .frame(height: 184)
        }
        .padding(9)
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
    let daily: [DailyUsage]
    private var newestFirst: [DailyUsage] {
        Array(daily.filter { $0.totals.totalTokens > 0 }.reversed())
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Days").font(.system(size: 12.5, weight: .semibold)).foregroundColor(.secondary)
            compactDayRow(date: "Date", tokens: "Tokens", estimate: "Estimate", isHeader: true)
            Divider()
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(newestFirst) { day in
                        compactDayRow(
                            date: shortDate(day.day),
                            tokens: compactCount(day.totals.totalTokens),
                            estimate: money(day.totals.estimatedCostUSD),
                            isHeader: false
                        )
                        Divider()
                    }
                }
            }
            .frame(height: 184)
        }
        .padding(9)
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
    BookTokenComparison(title: "the complete The Lord of the Rings trilogy", approximateWords: 481_000),
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

func tokenVolumeHelpExamples(_ tokens: Int) -> [String] {
    let words = Double(max(0, tokens)) * 0.75
    return bookTokenComparisons.map { book in
        let copies = words / Double(book.approximateWords)
        let formattedCopies = copies.formatted(
            .number.grouping(.automatic).precision(.fractionLength(copies < 10 ? 1 : 0))
        )
        let formattedWords = book.approximateWords.formatted(.number.grouping(.automatic))
        return "Your selected usage is roughly equivalent to \(formattedCopies) × \(book.title) (~\(formattedWords) words). Book lengths and the token-to-text conversion are approximate. Repeated cached context is counted again, so this is processed volume, not unique reading. Hover again for another book."
    }
}

private func dateTimeText(_ date: Date) -> String {
    date.formatted(.dateTime.month(.abbreviated).day().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
}
