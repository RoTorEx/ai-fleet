import SwiftUI

struct QuotaHistoryTarget: Identifiable, Equatable {
    let id: String
    let provider: StatisticsProvider
    let label: String
    let status: ProviderStatus
    let report: StatisticsProviderReport?

    @MainActor
    init?(row: MenuAccountConnection, codex: CodexMonitoringStore) {
        guard let provider = StatisticsProvider(rawValue: row.connection.providerID) else { return nil }
        self.provider = provider
        id = row.id
        label = row.isSetup ? provider.title : "\(provider.title) (\(row.accountScope))"
        status = row.status
        report = row.statisticsReport(codex: codex)
    }

    var quotaWindows: [ProviderLimitWindow] {
        guard status.hasCurrentQuotaMeasurement || (status.authentication == .signedIn && status.quotaState == .stale)
        else { return [] }
        return status.limitWindows.filter { (0...100).contains($0.remainingPercent) }
    }

    var primaryQuotaWindow: ProviderLimitWindow? {
        let windows = quotaWindows
        let accountWindows = windows.filter { $0.weeklyModel == nil }
        return accountWindows.first { $0.isWeeklyQuota }
            ?? (accountWindows.isEmpty ? windows : accountWindows).max {
                ($0.durationSeconds ?? 0) < ($1.durationSeconds ?? 0)
            }
    }

    func quotaFigure(history: WeeklyQuotaHistory, now: Date, calendar: Calendar = .current,
                     range: QuotaHistoryRange = .threeDays, displayedReset: Date? = nil) -> QuotaHistoryFigureData {
        guard provider != .qwen else { return .unsupportedQuota }
        let window = primaryQuotaWindow
        if let window, window.weeklyModel == nil, let report, report.weeklyWindows.contains(window) {
            return .quota(WeeklyQuotaChart(report: report, window: window, history: history,
                                           now: now, calendar: calendar, range: range, displayedReset: displayedReset))
        }
        return .currentQuota(QuotaLimitReading(window: window, measuredAt: status.lastUpdated, now: now,
                                              markedStale: status.quotaState == .stale))
    }
}

struct QuotaHistoryRequest: Equatable {
    let targetID: String
    let provider: StatisticsProvider
    var model: String?
    var tokenSeries: LocalTokenSeries? = nil
    var cycleReset: Date? = nil
    var identity: ConnectionIdentity? = nil
}

@MainActor
final class QuotaHistoryNavigation: ObservableObject {
    static let shared = QuotaHistoryNavigation()
    @Published var request: QuotaHistoryRequest?
}

struct QuotaHistoryView: View {
    let targets: [QuotaHistoryTarget]
    let openInStatistics: ((QuotaHistoryRequest) -> Void)?
    @Binding var selection: QuotaHistoryRequest?
    @ObservedObject private var quotaHistory = WeeklyQuotaHistoryStore.shared
    @State private var snapshot = UsageAnalyticsService.shared.snapshot
    @State private var refreshingLocalTokens = UsageAnalyticsService.shared.isRefreshing
    @AppStorage("quotaHistory.hourlyDays") private var range: QuotaHistoryRange = .sevenDays
    private var isStatistics: Bool { openInStatistics == nil }
    private var stackSpacing: CGFloat { isStatistics ? 4 : 6 }

    init(targets: [QuotaHistoryTarget], selection: Binding<QuotaHistoryRequest?>,
         openInStatistics: ((QuotaHistoryRequest) -> Void)? = nil) {
        self.targets = targets
        _selection = selection
        self.openInStatistics = openInStatistics
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            if let target = targets.first(where: { $0.id == selection?.targetID }) ?? targets.first {
                let now = timeline.date
                let calendar = Calendar.current
                let model = selection?.provider == target.provider ? selection?.model : nil
                let tokens = LocalTokenHistory(snapshot: snapshot, provider: target.provider, model: model,
                                               now: now, calendar: calendar, range: range)
                let request = QuotaHistoryRequest(targetID: target.id, provider: target.provider,
                    model: model, tokenSeries: selection?.tokenSeries,
                    cycleReset: selection?.targetID == target.id && selection?.identity == target.report?.identity
                        ? selection?.cycleReset : nil,
                    identity: target.report?.identity)
                let quotaData = isStatistics || target.provider != .qwen
                    ? target.quotaFigure(history: quotaHistory.history, now: now, calendar: calendar,
                                         range: range, displayedReset: request.cycleReset)
                    : nil
                let otherLimits = target.quotaWindows.filter { $0.id != target.primaryQuotaWindow?.id }
                let quota = quotaData.map {
                    QuotaHistoryDrawing(data: $0, calendar: calendar, range: range, otherLimits: otherLimits)
                }
                let weekly: WeeklyQuotaChart? = if case .quota(let chart)? = quotaData { chart } else { nil }
                VStack(alignment: .leading, spacing: stackSpacing) {
                    HStack(spacing: 8) {
                        Text(target.provider == .qwen ? "Provider" : "Quota account")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        providerControl(target: target, request: request)
                        Spacer(minLength: 4)
                        if quota != nil {
                            cycleControls(weekly, request: request)
                        }
                    }
                    .controlSize(.small)
                    let tokenDrawing = QuotaHistoryDrawing(data: .tokens(tokens, series: request.tokenSeries), calendar: calendar)
                    QuotaHistoryCharts(quota: quota, tokens: tokenDrawing, cycle: request.cycleReset, range: range,
                                       spacing: stackSpacing,
                                       hourlyControls: hourlyControls(models: tokens.models, request: request))
                        .id(ChartAccount(id: target.id, identity: target.report?.identity))
                    if let openInStatistics {
                        HStack(spacing: 8) {
                            Button("Open in Statistics") {
                                openInStatistics(request)
                            }
                            Button(refreshingLocalTokens ? "Refreshing local tokens…" : "Refresh local tokens") {
                                UsageAnalyticsService.shared.refreshLocalHistory()
                            }
                            .disabled(refreshingLocalTokens)
                            .help("Update saved token totals from new or changed local journals")
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
        .onReceive(UsageAnalyticsService.shared.$snapshot) { snapshot = $0 }
        .onReceive(UsageAnalyticsService.shared.$isRefreshing) { refreshingLocalTokens = $0 }
    }

    private func cycleControls(_ chart: WeeklyQuotaChart?, request: QuotaHistoryRequest) -> some View {
        HStack(spacing: 3) {
            cycleButton("Previous quota cycle", symbol: "chevron.left", offset: 1, chart: chart, request: request)
            cycleButton("Next quota cycle", symbol: "chevron.right", offset: -1, chart: chart, request: request)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func cycleButton(_ label: String, symbol: String, offset: Int, chart: WeeklyQuotaChart?,
                             request: QuotaHistoryRequest) -> some View {
        let reset = chart?.cycleReset(offset: offset)
        return Button {
            guard let reset else { return }
            var next = request
            next.cycleReset = reset == chart?.cycleResets.first ? nil : reset
            selection = next
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 14)
        }
        .disabled(reset == nil)
        .accessibilityLabel(label)
        .help(label)
    }

    private func hourlyControls(models: [String], request: QuotaHistoryRequest) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                rangePicker
                tokenControls(models: models, request: request)
            }
            VStack(alignment: .trailing, spacing: 6) {
                rangePicker
                tokenControls(models: models, request: request)
            }
        }
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    @ViewBuilder private func providerControl(target: QuotaHistoryTarget, request: QuotaHistoryRequest) -> some View {
        if isStatistics {
            Picker("Quota account", selection: Binding(
                get: { target.id },
                set: { value in
                    guard let next = targets.first(where: { $0.id == value }) else { return }
                    selection = QuotaHistoryRequest(targetID: next.id, provider: next.provider,
                        model: next.provider == target.provider ? request.model : nil, tokenSeries: request.tokenSeries)
                }
            )) {
                ForEach(targets) { Text($0.label).tag($0.id) }
            }
            .labelsHidden().frame(width: 142, alignment: .leading)
            .disabled(targets.count < 2)
        } else {
            Text(target.label)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
        }
    }

    private var rangePicker: some View {
        Picker("Hourly chart range", selection: $range) {
            ForEach(QuotaHistoryRange.allCases) { range in
                Text(range.label).tag(range)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .fixedSize()
        .help("Time range for both hourly charts")
    }

    private func tokenControls(models: [String], request: QuotaHistoryRequest) -> some View {
        HStack(spacing: 8) {
            modelPicker(models: models, request: request)
            Picker("Token category", selection: Binding(get: { request.tokenSeries }, set: { series in
                var next = request
                next.tokenSeries = series
                selection = next
            })) {
                Text("All tokens").tag(LocalTokenSeries?.none)
                ForEach(LocalTokenSeries.allCases) { series in
                    Text(series.rawValue).tag(Optional(series))
                }
            }
            .labelsHidden().frame(width: 104)
            .disabled(models.isEmpty)
            .help("Show all tokens together or inspect one category")
        }
    }

    private func modelPicker(models: [String], request: QuotaHistoryRequest) -> some View {
        Picker("Local token model", selection: Binding(get: { request.model }, set: { model in
            var next = request
            next.model = model
            selection = next
        })) {
            Text("All models").tag(String?.none)
            ForEach(models, id: \.self) { Text($0).tag(Optional($0)) }
        }
        .labelsHidden().frame(width: 116)
        .disabled(models.isEmpty)
        .help("Filter the local token chart by model")
    }
}

private struct ChartAccount: Hashable {
    let id: String
    let identity: ConnectionIdentity?
}

private struct QuotaHistoryCharts<HourlyControls: View>: View {
    let quota: QuotaHistoryDrawing?
    let tokens: QuotaHistoryDrawing
    let cycle: Date?
    let range: QuotaHistoryRange
    let spacing: CGFloat
    let hourlyControls: HourlyControls

    @State private var overviewCursor: QuotaChartCursor?
    @State private var hourlyCursor: QuotaChartCursor?

    var body: some View {
        VStack(spacing: spacing) {
            if let quota {
                QuotaHistoryFigure(drawing: quota, panel: .overview, cursor: $overviewCursor)
            }
            hourlyControls
            VStack(spacing: 5) {
                if let quota {
                    QuotaHistoryFigure(drawing: quota, panel: .hourly, cursor: $hourlyCursor)
                }
                QuotaHistoryFigure(drawing: tokens, panel: .hourly, cursor: $hourlyCursor)
            }
        }
        .onChange(of: cycle) { _ in overviewCursor = nil }
        .onChange(of: range) { _ in hourlyCursor = nil }
    }
}
