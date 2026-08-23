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
        .onAppear {
            analytics.updateKimi(kimi: service.kimi)
            analytics.refreshAccountUsageIfNeeded()
        }
    }

    private var header: some View {
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
    }

    private var codexContent: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 8) {
                PeriodToolbar(
                    period: $period,
                    customStart: $customStart,
                    customEnd: $customEnd
                )

                HStack(alignment: .top, spacing: 8) {
                    MetricCard(
                        title: "Total tokens",
                        sourceLabel: selection.usesAccountUsage ? "Account" : "Local",
                        value: compactCount(selection.totalTokens),
                        detail: periodDetail,
                        helpExamples: tokenVolumeHelpExamples(selection.totalTokens, metric: selection.usesAccountUsage ? .accountTotal : .total)
                    )
                    .frame(minWidth: 210, idealWidth: 250, maxWidth: 300)
                    DatasetCard(codex: snapshot.codex, eventCount: selection.eventCount)
                }

                HStack(alignment: .top, spacing: 8) {
                    MetricCard(
                        title: "Input",
                        sourceLabel: "Local",
                        value: compactCount(selection.totals.inputTokens),
                        helpExamples: tokenVolumeHelpExamples(selection.totals.inputTokens, metric: .input),
                        rows: [
                            AccountingRow(label: "Uncached", value: compactCount(selection.totals.billableInputTokens), help: "Input tokens minus cached reads and cache writes."),
                            AccountingRow(label: "Cached", value: compactCount(selection.totals.cachedInputTokens), help: "Input tokens served from the prompt cache."),
                            AccountingRow(label: "Cache writes", value: compactCount(selection.totals.cacheWriteInputTokens), help: "Input tokens written into the prompt cache.")
                        ]
                    )
                    MetricCard(
                        title: "Output",
                        sourceLabel: "Local",
                        value: compactCount(selection.totals.outputTokens),
                        helpExamples: tokenVolumeHelpExamples(selection.totals.outputTokens, metric: .output),
                        rows: [
                            AccountingRow(label: "Reasoning", value: compactCount(selection.totals.reasoningOutputTokens), help: "Internally processed tokens reported as a subset of output.")
                        ]
                    )
                    MetricCard(
                        title: "Estimate",
                        sourceLabel: "Local",
                        value: money(selection.totals.estimatedCostUSD),
                        help: "Calculated only from local session logs: uncached input × input rate + cached input × cached rate + cache writes × write rate + output × output rate. It may cover less activity than the account total and is not a subscription charge.",
                        rows: [AccountingRow(label: "Basis", value: "model rates")]
                    )
                }

                HStack(alignment: .top, spacing: 10) {
                    ModelTablePanel(models: selection.models)
                        .frame(minWidth: 430, maxWidth: .infinity)
                    DailyTablePanel(daily: selection.daily, usesAccountUsage: selection.usesAccountUsage)
                        .frame(minWidth: 330, maxWidth: .infinity)
                }

                ActivityHeatmap(days: selection.daily, sourceLabel: selection.usesAccountUsage ? "Account" : "Local")
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
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
    let sourceLabel: String?
    let value: String
    let detail: String?
    var helpExamples = ["Current provider value for this metric."]
    var rows: [AccountingRow] = []

    init(title: String, sourceLabel: String? = nil, value: String, detail: String? = nil, help: String = "Current provider value for this metric.", rows: [AccountingRow] = []) {
        self.title = title
        self.sourceLabel = sourceLabel
        self.value = value
        self.detail = detail
        helpExamples = [help]
        self.rows = rows
    }

    init(title: String, sourceLabel: String? = nil, value: String, detail: String? = nil, helpExamples: [String], rows: [AccountingRow] = []) {
        self.title = title
        self.sourceLabel = sourceLabel
        self.value = value
        self.detail = detail
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
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
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
        .frame(maxWidth: .infinity, minHeight: rows.isEmpty ? 66 : 118, alignment: .topLeading)
        .panelStyle()
    }
}

private struct DatasetCard: View {
    let codex: CodexUsageAnalytics
    let eventCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 5) {
                Text("Sources")
                HoverInfoTip(text: "Account totals and daily activity come from Codex through your ChatGPT account. Detailed token categories, models, events, files, and cost estimates come from session logs stored on this Mac.")
            }
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 24) {
                DatasetValue(label: "Total & days", value: codex.accountUsage == nil ? "Local sessions" : "Codex account")
                    .frame(maxWidth: .infinity, alignment: .leading)
                DatasetValue(label: "Details", value: "Local sessions", help: "Input, output, cache, reasoning, models, events, and estimates are calculated from local session logs.")
                    .frame(maxWidth: .infinity, alignment: .leading)
                DatasetValue(label: "Files", value: "\(codex.fileCount)")
                DatasetValue(label: "Events", value: "\(eventCount)", help: "Token-usage samples found in Codex session logs.")
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
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
            compactDayRow(date: "Date", tokens: "Tokens", estimate: usesAccountUsage ? "Local est." : "Estimate", isHeader: true)
            Divider()
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(newestFirst) { day in
                        compactDayRow(
                            date: shortDate(day.day),
                            tokens: compactCount(day.tokens),
                            estimate: day.localEstimateUSD.map(money) ?? "—",
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

private struct ActivityHeatmap: View {
    let days: [CodexSelectedDay]
    let sourceLabel: String

    private var weeks: [HeatmapWeek] { heatmapWeeks(from: days) }
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

            if weeks.isEmpty {
                Text("No activity in this period")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 90, alignment: .center)
            } else {
                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 3) {
                            ForEach(weeks) { week in
                                Text(week.monthLabel ?? "")
                                    .font(.system(size: 9.5, weight: .medium))
                                    .foregroundColor(.secondary)
                                    .frame(width: 11, alignment: .leading)
                            }
                        }
                        HStack(alignment: .top, spacing: 3) {
                            ForEach(weeks) { week in
                                VStack(spacing: 3) {
                                    ForEach(Array(week.days.enumerated()), id: \.offset) { _, day in
                                        heatmapCell(day)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.bottom, 2)
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
            RoundedRectangle(cornerRadius: 2)
                .fill(heatmapColor(level: level))
                .frame(width: 11, height: 11)
                .help("\(rangeDate(day.day)) · \(day.tokens.formatted(.number.grouping(.automatic))) tokens")
        } else {
            Color.clear.frame(width: 11, height: 11)
        }
    }
}

struct HeatmapDay: Equatable {
    let day: Date
    let tokens: Int
}

struct HeatmapWeek: Identifiable, Equatable {
    let start: Date
    let monthLabel: String?
    let days: [HeatmapDay?]
    var id: Date { start }
}

func heatmapWeeks(from selectedDays: [CodexSelectedDay], calendar suppliedCalendar: Calendar = .autoupdatingCurrent) -> [HeatmapWeek] {
    guard let first = selectedDays.map(\.day).min(), let last = selectedDays.map(\.day).max() else { return [] }
    var calendar = suppliedCalendar
    calendar.firstWeekday = 1
    let firstDay = calendar.startOfDay(for: first)
    let lastDay = calendar.startOfDay(for: last)
    guard let firstWeek = calendar.dateInterval(of: .weekOfYear, for: firstDay)?.start,
          let lastWeek = calendar.dateInterval(of: .weekOfYear, for: lastDay)?.start else { return [] }
    let tokenByDay = Dictionary(uniqueKeysWithValues: selectedDays.map {
        (calendar.startOfDay(for: $0.day), $0.tokens)
    })
    var result: [HeatmapWeek] = []
    var weekStart = firstWeek
    var previousMonth: Int?
    while weekStart <= lastWeek {
        let weekDays: [HeatmapDay?] = (0..<7).map { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: weekStart),
                  day >= firstDay, day <= lastDay else { return nil }
            return HeatmapDay(day: day, tokens: tokenByDay[day] ?? 0)
        }
        let labelDay = weekDays.compactMap { $0 }.first
        let month = labelDay.map { calendar.component(.month, from: $0.day) }
        let monthLabel = month != previousMonth ? labelDay?.day.formatted(.dateTime.month(.abbreviated)) : nil
        result.append(HeatmapWeek(start: weekStart, monthLabel: monthLabel, days: weekDays))
        previousMonth = month ?? previousMonth
        guard let next = calendar.date(byAdding: .day, value: 7, to: weekStart) else { break }
        weekStart = next
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
        return "\(used)/\(limit)"
    }
}

struct CodexUsageSelection: Equatable {
    let totals: UsageTotals
    let totalTokens: Int
    let daily: [CodexSelectedDay]
    let models: [ModelUsage]
    let eventCount: Int
    let usesAccountUsage: Bool
}

struct CodexSelectedDay: Identifiable, Equatable {
    let day: Date
    let tokens: Int
    let localEstimateUSD: Double?

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
    let localByDay = Dictionary(uniqueKeysWithValues: localDaily.map {
        (calendar.startOfDay(for: $0.day), $0.totals)
    })
    let accountDaily = codex.accountUsage?.daily.filter { includes($0.day) }
    let displayDaily: [CodexSelectedDay]
    if let accountDaily {
        displayDaily = accountDaily.map { usage in
            let local = localByDay[calendar.startOfDay(for: usage.day)]
            return CodexSelectedDay(
                day: usage.day,
                tokens: usage.tokens,
                localEstimateUSD: local?.estimatedCostUSD
            )
        }
    } else {
        displayDaily = localDaily.map {
            CodexSelectedDay(day: $0.day, tokens: $0.totals.totalTokens, localEstimateUSD: $0.totals.estimatedCostUSD)
        }
    }
    let accountTotal = isAllTime
        ? codex.accountUsage?.lifetimeTokens
        : accountDaily?.reduce(0) { $0 + $1.tokens }
    return CodexUsageSelection(
        totals: selectedTotals,
        totalTokens: accountTotal ?? selectedTotals.totalTokens,
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
        let formattedWords = book.approximateWords.formatted(.number.grouping(.automatic))
        let comparison = bookCopyComparison(copies, title: book.title)
        return "\(metric.explanation)\n\nFor a sense of scale, that is \(comparison) (~\(formattedWords) words each). Book lengths and the token-to-text conversion are approximate.\(metric.cacheNote) Hover again for another book."
    }
}

func bookCopyComparison(_ copies: Double, title: String) -> String {
    guard copies >= 0.5 else { return "less than one copy of \(title)" }
    let roundedCopies = Int(copies.rounded())
    if roundedCopies == 1 { return "roughly one copy of \(title)" }
    return "roughly \(roundedCopies.formatted(.number.grouping(.automatic))) copies of \(title)"
}

private func dateTimeText(_ date: Date) -> String {
    date.formatted(.dateTime.month(.abbreviated).day().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
}
