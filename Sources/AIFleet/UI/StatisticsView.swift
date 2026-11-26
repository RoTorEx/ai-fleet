import AppKit
import SwiftUI

struct StatisticsView: View {
    @ObservedObject private var analytics = UsageAnalyticsService.shared
    @ObservedObject private var service = StatusService.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var accounts = AccountStore.shared
    @ObservedObject private var codexMonitoring = CodexMonitoringStore.shared
    @AppStorage("statistics.period") private var period: StatisticsPeriod = .allTime
    @State private var tab: StatisticsTab = .tokenSpend
    @State private var historySelection: QuotaHistoryRequest?
    @State private var quotaScrollID = UUID()

    private var enabled: [StatisticsProvider] {
        StatisticsProvider.allCases.filter { settings.isEnabled($0.rawValue) }
    }
    private var chosen: Set<StatisticsProvider> { analytics.selectedProviders.intersection(enabled) }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.bottom, 8)
            Picker("Statistics section", selection: $tab) {
                ForEach(StatisticsTab.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.bottom, 10)
            Divider()
            ScrollView(.vertical) {
                Group {
                    if chosen.isEmpty {
                        Text("Choose at least one provider above.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 200)
                    } else if tab == .tokenSpend {
                        tokenSpend
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            quotaHistory
                            providerReports
                        }
                    }
                }
                .padding(.vertical, 12)
            }
            .id(tab == .quotaHistory ? quotaScrollID : nil)
        }
        .onReceive(QuotaHistoryNavigation.shared.$request.compactMap { $0 }) { request in
            if enabled.contains(request.provider) {
                if !chosen.contains(request.provider) { analytics.selectedProviders.insert(request.provider) }
                historySelection = request
                quotaScrollID = UUID()
                tab = .quotaHistory
            }
            DispatchQueue.main.async {
                if QuotaHistoryNavigation.shared.request == request { QuotaHistoryNavigation.shared.request = nil }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .frame(minWidth: 820, minHeight: 600, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .modifier(StatisticsNoFocusRing())
        .onAppear {
            analytics.updateKimi(kimi: service.kimi)
            analytics.refreshAccountUsageIfNeeded()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 6) {
            Chip(title: "All", selected: chosen.count == enabled.count && !enabled.isEmpty) {
                analytics.selectedProviders = Set(enabled)
            }
            ForEach(enabled, id: \.self) { provider in
                Chip(title: provider.title, color: provider.color, selected: chosen.contains(provider)) {
                    var next = analytics.selectedProviders
                    if next.contains(provider) { next.remove(provider) } else { next.insert(provider) }
                    analytics.selectedProviders = next
                }
                .help("Option-click to show only \(provider.title)")
                .simultaneousGesture(TapGesture().modifiers(.option).onEnded { analytics.selectedProviders = [provider] })
            }
            Spacer(minLength: 16)
            ForEach(StatisticsPeriod.allCases) { item in
                Chip(title: item.rawValue, selected: period == item) { period = item }
            }
            RefreshStatus(progress: analytics.progress, refreshedAt: analytics.snapshot.refreshedAt,
                          isRefreshing: analytics.isRefreshing,
                          refresh: { analytics.refresh(kimi: service.kimi) })
                .padding(.leading, 8)
        }
    }

    private var tokenSpend: some View {
        let now = Date()
        let stats = analytics.localStatistics(providers: chosen, days: period.days, now: now)
        let rows = chosen.sorted { $0.rawValue < $1.rawValue }.map { provider in
            (provider, analytics.localStatistics(providers: [provider], days: period.days, now: now).tokenSpend)
        }.sorted { $0.1.totals.totalTokens > $1.1.totals.totalTokens }
        return VStack(alignment: .leading, spacing: 10) {
            scopeLine(stats)
            summary(stats)
            HStack(alignment: .top, spacing: 10) {
                providerBreakdown(rows, totalTokens: stats.totals.totalTokens).frame(width: 200)
                ModelTablePanel(models: stats.models).frame(maxWidth: .infinity)
                DailyTablePanel(daily: stats.daily).frame(width: 224)
            }
            ActivityHeatmap(
                days: selectedDays(stats),
                sourceLabel: "Local",
                displayThrough: period == .allTime ? stats.daily.first.map { heatmapHorizon(startingAt: $0.day) } : nil
            )
        }
    }

    private func scopeLine(_ stats: LocalStatistics) -> some View {
        Text("Local history on this Mac · \(rangeText(stats))")
            .font(.system(size: 11)).foregroundStyle(.secondary)
    }

    private func rangeText(_ stats: LocalStatistics) -> String {
        if period == .allTime, let first = stats.daily.first?.day, let last = stats.daily.last?.day {
            return "\(rangeDate(first)) – \(rangeDate(last))"
        }
        return period == .allTime ? "no recorded days" : "last \(period.days ?? 0) days"
    }

    // MARK: Summary

    private func summary(_ stats: LocalStatistics) -> some View {
        let totals = stats.totals
        return HStack(alignment: .top, spacing: 8) {
            StatCard(title: "Total tokens", value: compactCount(totals.totalTokens),
                     help: tokenVolumeHelpExamples(totals.totalTokens, metric: .total)) {
                detailRow("Events", groupedInteger(stats.dailyModels.reduce(0) { $0 + $1.events }))
                detailRow("Active days", groupedInteger(stats.daily.filter { $0.totals.totalTokens > 0 }.count))
            }
            .frame(maxWidth: .infinity)
            StatCard(title: "Input", value: compactCount(totals.inputTokens),
                     help: tokenVolumeHelpExamples(totals.inputTokens, metric: .input)) {
                detailRow("Uncached", compactCount(totals.billableInputTokens))
                detailRow("Cached", compactCount(totals.cachedInputTokens))
                detailRow("Cache writes", compactCount(totals.cacheWriteInputTokens))
            }
            .frame(maxWidth: .infinity)
            StatCard(title: "Output", value: compactCount(totals.outputTokens),
                     help: tokenVolumeHelpExamples(totals.outputTokens, metric: .output)) {
                detailRow("Reasoning", compactCount(totals.reasoningOutputTokens))
            }
            .frame(maxWidth: .infinity)
            StatCard(title: "API estimate", value: stats.cost.formattedEstimate,
                     help: ["API-equivalent value of the recorded tokens at standard model rates. It is not a subscription charge. Unknown model prices are left out, so a partial total shows as a minimum with its price coverage."]) {
                detailRow("Priced", stats.cost.coverage.map { "\(Int(($0 * 100).rounded(.down)))% of tokens" } ?? "—")
            }
            .frame(maxWidth: .infinity)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value).font(.system(size: 10.5, weight: .medium, design: .monospaced)).lineLimit(1)
        }
        .font(.system(size: 10.5))
    }

    // MARK: Providers

    private func providerBreakdown(_ rows: [(StatisticsProvider, TokenSpendSummary)], totalTokens: Int) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                PanelTitle("By provider")
                Spacer()
                Text("Share of tokens").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            ForEach(rows, id: \.0) { provider, spend in
                let share = spend.share(of: totalTokens)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Circle().fill(provider.color).frame(width: 6, height: 6)
                        Text(provider.title).fontWeight(.medium)
                        Spacer(minLength: 2)
                        Text(compactCount(spend.totals.totalTokens)).foregroundStyle(.secondary)
                        Text(shareText(share)).fontWeight(.semibold)
                            .frame(width: 42, alignment: .trailing)
                    }
                    HStack(spacing: 8) {
                        GeometryReader { geometry in
                            Capsule().fill(provider.color.opacity(0.14))
                                .overlay(alignment: .leading) {
                                    Capsule().fill(provider.color.opacity(0.75))
                                        .frame(width: geometry.size.width * (share ?? 0))
                                }
                        }
                        .frame(height: 4)
                        Text(spend.cost.formattedEstimate).foregroundStyle(.secondary)
                            .frame(width: 63, alignment: .trailing)
                    }
                }
                .font(.system(size: 11)).monospacedDigit().lineLimit(1)
            }
        }
        .padding(10)
        .frame(height: statisticsTableHeight, alignment: .topLeading)
        .fleetCard(hovering: false)
    }

    private func shareText(_ share: Double?) -> String {
        guard let share else { return "—" }
        if share > 0, share < 0.001 { return "<0.1%" }
        return "\(formattedNumber(share * 100, fractionDigits: 1))%"
    }

    private func selectedDays(_ stats: LocalStatistics) -> [CodexSelectedDay] {
        stats.daily.map {
            CodexSelectedDay(day: $0.day, tokens: $0.totals.totalTokens,
                             estimatedCostUSD: $0.totals.estimatedCostUSD > 0 ? $0.totals.estimatedCostUSD : nil)
        }
    }

    // MARK: Provider reports

    @ViewBuilder private var quotaHistory: some View {
        let rows = menuProviderRows(accounts: accounts.accounts,
            enabled: { id in StatisticsProvider(rawValue: id).map(chosen.contains) ?? false },
            global: service.status(for:), statusForConnection: service.status(for:), codex: codexMonitoring)
        let targets = rows.compactMap { QuotaHistoryTarget(row: $0, codex: codexMonitoring) }
        if !targets.isEmpty {
            QuotaHistoryView(targets: targets, selection: $historySelection)
                .frame(maxWidth: 740)
                .frame(maxWidth: .infinity)
                .padding(12)
                .fleetCard(hovering: false)
        }
    }

    @ViewBuilder private var providerReports: some View {
        let showsKimi = chosen.contains(.kimi) && !analytics.snapshot.kimi.windows.isEmpty
        if chosen.contains(.codex) || showsKimi {
            VStack(alignment: .leading, spacing: 8) {
                PanelTitle("Provider reports")
                Text("Reported by the provider for each account, separate from the local history above.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if chosen.contains(.codex) {
                    let bounds = period.bounds()
                    CodexProfilesView(nativeStatus: service.codex, start: bounds.start, end: bounds.end,
                                      refreshNative: { analytics.refreshAccountUsage(); service.refresh() })
                        .padding(10)
                        .fleetCard(hovering: false)
                }
                if showsKimi {
                    KimiTablePanel(windows: analytics.snapshot.kimi.windows)
                }
            }
            .padding(.top, 6)
        }
    }
}

extension StatisticsProvider {
    var title: String { rawValue == "qwen" ? "Qwen" : rawValue.capitalized }
    var color: Color {
        switch self {
        case .codex: return .teal
        case .claude: return .orange
        case .kimi: return .purple
        case .qwen: return .indigo
        }
    }
}

private enum StatisticsTab: String, CaseIterable, Identifiable {
    case tokenSpend = "Token Spend"
    case quotaHistory = "Quota & Usage"

    var id: Self { self }
}

private enum StatisticsPeriod: String, CaseIterable, Identifiable {
    case sevenDays = "7d"
    case thirtyDays = "30d"
    case ninetyDays = "90d"
    case allTime = "All"

    var id: String { rawValue }
    var days: Int? {
        switch self {
        case .sevenDays: return 7
        case .thirtyDays: return 30
        case .ninetyDays: return 90
        case .allTime: return nil
        }
    }

    func bounds(calendar: Calendar = .autoupdatingCurrent) -> (start: Date?, end: Date?) {
        let today = calendar.startOfDay(for: Date())
        guard let days else { return (nil, nil) }
        return (calendar.date(byAdding: .day, value: -(days - 1), to: today), today)
    }
}

private struct StatisticsNoFocusRing: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) { content.focusEffectDisabled() } else { content }
    }
}

/// Filter chip in the menu's style: a soft capsule, a colored dot when the item has a color.
private struct Chip: View {
    let title: String
    var color: Color?
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let color {
                    Circle().fill(selected ? color : color.opacity(0.3)).frame(width: 7, height: 7)
                }
                Text(title).font(.system(size: 11.5, weight: .medium))
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .background(Color.primary.opacity(selected ? 0.12 : (hovering ? 0.07 : 0.035)), in: Capsule())
            .overlay(Capsule().stroke(Color.primary.opacity(selected ? 0.14 : 0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct PanelTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
    }
}

extension StatisticsCost {
    var formattedEstimate: String {
        if let fullEstimateUSD { return money(fullEstimateUSD) }
        return knownEstimateUSD > 0 ? "≥ " + money(knownEstimateUSD) : "—"
    }
}

private struct StatCard<Details: View>: View {
    let title: String
    let value: String
    let help: [String]
    @ViewBuilder let details: Details
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text(title)
                HoverInfoTip(texts: help)
            }
            .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .monospaced))
                .lineLimit(1).minimumScaleFactor(0.6)
            Divider().padding(.vertical, 1)
            details
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .fleetCard(hovering: hovering)
        .onHover { hovering = $0 }
    }
}

private struct RefreshStatus: View {
    let progress: UsageAnalyticsLoadProgress
    let refreshedAt: Date?
    let isRefreshing: Bool
    let refresh: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            if isRefreshing {
                ProgressView(value: progress.fractionCompleted ?? 0).progressViewStyle(.linear).frame(width: 70)
                Text(progress.totalFiles > 0 ? "\(groupedInteger(progress.processedFiles))/\(groupedInteger(progress.totalFiles))" : "preparing")
            } else {
                Text(refreshedAt.map(dateTimeText) ?? "Not scanned")
            }
            Button(action: refresh) {
                Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .background(Color.primary.opacity(hovering ? 0.12 : 0), in: RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .disabled(isRefreshing)
            .help("Rescan local Codex, Claude, Kimi and Qwen history and Codex account usage")
        }
        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
        .foregroundStyle(.secondary)
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

private let statisticsTableHeight: CGFloat = 206

private struct ModelTablePanel: View {
    let models: [ModelUsage]
    private var sorted: [ModelUsage] { models.sorted { $0.totals.totalTokens > $1.totals.totalTokens } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                PanelTitle("Models")
                HoverInfoTip(text: "Models and API-equivalent estimates come from local sessions at standard model rates, not subscription charges. Unknown prices show no estimate. Reasoning is a reported subset of output; missing reasoning is not inferred.")
            }
            row(provider: nil, model: "Model", tokens: "Tokens", reasoning: "Reasoning", estimate: "Estimate", header: true)
            Divider()
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(sorted) { model in
                        let parts = model.model.components(separatedBy: " · ")
                        row(provider: StatisticsProvider(rawValue: parts.first ?? ""),
                            model: parts.count > 1 ? parts.dropFirst().joined(separator: " · ") : model.model,
                            tokens: compactCount(model.totals.totalTokens),
                            reasoning: model.totals.reasoningOutputTokens == 0 ? "—" : compactCount(model.totals.reasoningOutputTokens),
                            estimate: model.totals.hasCostEstimate ? money(model.totals.estimatedCostUSD) : "—",
                            header: false)
                    }
                }
            }
        }
        .padding(10)
        .frame(height: statisticsTableHeight, alignment: .topLeading)
        .fleetCard(hovering: false)
    }

    private func row(provider: StatisticsProvider?, model: String, tokens: String, reasoning: String, estimate: String, header: Bool) -> some View {
        HStack(spacing: 6) {
            Circle().fill(provider?.color ?? .clear).frame(width: 6, height: 6)
            ModelNameCell(name: model)
            Text(tokens).frame(width: 66, alignment: .trailing)
            Text(reasoning).frame(width: 62, alignment: .trailing)
            Text(estimate).frame(width: 62, alignment: .trailing)
        }
        .font(.system(size: header ? 10.5 : 11, weight: header ? .semibold : .medium, design: header ? .default : .monospaced))
        .foregroundStyle(header ? Color.secondary : Color.primary)
        .padding(.horizontal, 2)
        .padding(.vertical, header ? 2 : 4)
    }
}

/// Shows the full model name on hover, only when the column cut it off.
private struct ModelNameCell: View {
    let name: String
    @State private var truncated = false

    var body: some View {
        Text(name).lineLimit(1).frame(minWidth: 82, maxWidth: .infinity, alignment: .leading)
            .background(GeometryReader { column in
                Text(name).fixedSize().hidden().background(GeometryReader { full in
                    let overflow = full.size.width > column.size.width + 0.5
                    Color.clear.onAppear { truncated = overflow }.onChange(of: overflow) { truncated = $0 }
                })
            })
            .hoverPopover(enabled: truncated) {
                Text(name).font(.system(size: 11, weight: .medium, design: .monospaced)).padding(9)
            }
    }
}

private struct DailyTablePanel: View {
    let daily: [DailyUsage]
    private var newestFirst: [DailyUsage] { Array(daily.filter { $0.totals.totalTokens > 0 }.reversed()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PanelTitle("Days")
            row(date: "Date", tokens: "Tokens", estimate: "Estimate", header: true)
            Divider()
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(newestFirst, id: \.day) { day in
                        row(date: shortDate(day.day), tokens: compactCount(day.totals.totalTokens),
                            estimate: estimate(day.totals), header: false)
                    }
                }
            }
        }
        .padding(10)
        .frame(height: statisticsTableHeight, alignment: .topLeading)
        .fleetCard(hovering: false)
    }

    /// Days mixing priced and unpriced models show the known part as a minimum.
    private func estimate(_ totals: UsageTotals) -> String {
        guard totals.estimatedCostUSD > 0 else { return "—" }
        return (totals.hasCostEstimate ? "" : "≥ ") + money(totals.estimatedCostUSD)
    }

    private func row(date: String, tokens: String, estimate: String, header: Bool) -> some View {
        HStack(spacing: 6) {
            Text(date).frame(maxWidth: .infinity, alignment: .leading)
            Text(tokens).frame(width: 68, alignment: .trailing)
            Text(estimate).frame(width: 64, alignment: .trailing)
        }
        .font(.system(size: header ? 10.5 : 11, weight: header ? .semibold : .medium, design: header ? .default : .monospaced))
        .foregroundStyle(header ? Color.secondary : Color.primary)
        .padding(.horizontal, 2)
        .padding(.vertical, header ? 2 : 4)
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
        .padding(10)
        .fleetCard(hovering: false)
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

    private var isFuture: Bool { day.day > Calendar.current.startOfDay(for: Date()) }

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
                    if !isFuture {
                        Text("\(millionsCount(day.tokens)) tokens")
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                        Text(day.estimatedCostUSD.map { "\(money($0)) estimated cost" } ?? "Cost estimate unavailable")
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(9)
            }
            .accessibilityLabel(isFuture ? rangeDate(day.day) :
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
    case 1: return Color.teal.opacity(0.3)
    case 2: return Color.teal.opacity(0.5)
    case 3: return Color.teal.opacity(0.75)
    case 4: return Color.teal
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
        .padding(10)
        .fleetCard(hovering: false)
    }

    private func usageText(_ window: KimiQuotaWindow) -> String {
        guard let used = window.used, let limit = window.limit else { return "unknown" }
        return "\(groupedInteger(used))/\(groupedInteger(limit))"
    }
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

private func dateTimeText(_ date: Date) -> String {
    date.formatted(.dateTime.month(.abbreviated).day().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
}
