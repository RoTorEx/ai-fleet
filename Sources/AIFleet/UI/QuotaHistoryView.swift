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

    func quotaFigure(history: WeeklyQuotaHistory, now: Date, calendar: Calendar = .current) -> QuotaHistoryFigureData {
        guard provider != .qwen else { return .unsupportedQuota }
        let window = primaryQuotaWindow
        if let window, window.weeklyModel == nil, let report, report.weeklyWindows.contains(window) {
            return .quota(WeeklyQuotaChart(report: report, window: window, history: history, now: now, calendar: calendar))
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
    private var isStatistics: Bool { openInStatistics == nil }
    private var controlLabelWidth: CGFloat { isStatistics ? 142 : 110 }

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
                let tokens = LocalTokenHistory(snapshot: snapshot, provider: target.provider, model: model, now: now, calendar: calendar)
                let request = QuotaHistoryRequest(targetID: target.id, provider: target.provider,
                    model: model.flatMap { tokens.models.contains($0) ? $0 : nil }, tokenSeries: selection?.tokenSeries)
                VStack(alignment: .leading, spacing: 8) {
                    controls(target: target, models: tokens.models, request: request)
                    let windows = target.quotaWindows
                    if isStatistics {
                        statisticsQuotaReadings(target, windows: windows, calendar: calendar)
                    } else if target.provider != .qwen, !windows.isEmpty {
                        quotaReadings(windows, stale: target.status.quotaState == .stale, calendar: calendar)
                    }
                    VStack(spacing: 0) {
                        if isStatistics || target.provider != .qwen {
                            let data = target.quotaFigure(history: quotaHistory.history, now: now, calendar: calendar)
                            let quota = QuotaHistoryDrawing(data: data, calendar: calendar)
                            QuotaHistoryFigure(drawing: quota, panel: .overview)
                            QuotaHistoryFigure(drawing: quota, panel: .hourly)
                        }
                        let data = QuotaHistoryFigureData.tokens(tokens, series: request.tokenSeries)
                        QuotaHistoryFigure(drawing: QuotaHistoryDrawing(data: data, calendar: calendar), panel: .hourly)
                            .id(request.tokenSeries)
                    }
                    if let openInStatistics {
                        Button("Open in Statistics") {
                            openInStatistics(request)
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
        .onReceive(UsageAnalyticsService.shared.$snapshot) { snapshot = $0 }
    }

    private func controls(target: QuotaHistoryTarget, models: [String], request: QuotaHistoryRequest) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                providerControl(target: target, request: request)
                Spacer(minLength: 0)
                tokenControls(models: models, request: request)
            }
            VStack(alignment: .leading, spacing: 6) {
                providerControl(target: target, request: request)
                tokenControls(models: models, request: request)
            }
        }
        .controlSize(.small)
    }

    @ViewBuilder private func providerControl(target: QuotaHistoryTarget, request: QuotaHistoryRequest) -> some View {
        if isStatistics {
            Picker("Provider and account", selection: Binding(
                get: { target.id },
                set: { value in
                    guard let next = targets.first(where: { $0.id == value }) else { return }
                    selection = QuotaHistoryRequest(targetID: next.id, provider: next.provider,
                        model: next.provider == target.provider ? request.model : nil, tokenSeries: request.tokenSeries)
                }
            )) {
                ForEach(targets) { Text($0.label).tag($0.id) }
            }
            .labelsHidden().frame(width: controlLabelWidth, alignment: .leading)
            .disabled(targets.count < 2)
        } else {
            Text(target.label)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .frame(width: controlLabelWidth, alignment: .leading)
        }
    }

    private func statisticsQuotaReadings(_ target: QuotaHistoryTarget, windows: [ProviderLimitWindow],
                                         calendar: Calendar) -> some View {
        // The account picker changes the readings without moving the charts below it.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                if windows.isEmpty {
                    Text(target.provider == .qwen ? "Local tokens only" : "No quota reading")
                        .foregroundStyle(.secondary)
                } else {
                    Text(target.status.quotaState == .stale ? "Last used" : "Used").foregroundStyle(.secondary)
                    quotaReadingLine(windows, calendar: calendar)
                }
            }
            .font(.system(size: 11))
        }
        .frame(height: 16)
    }

    private func quotaReadings(_ windows: [ProviderLimitWindow], stale: Bool, calendar: Calendar) -> some View {
        let title = stale ? "Last used" : "Used"
        return HStack(alignment: .top, spacing: 10) {
            Text(title).foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                quotaReadingLine(windows, calendar: calendar)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 105), alignment: .leading)], alignment: .leading) {
                    ForEach(windows) { quotaReading($0, calendar: calendar) }
                }
            }
        }
        .font(.system(size: 11))
    }

    private func quotaReadingLine(_ windows: [ProviderLimitWindow], calendar: Calendar) -> some View {
        HStack(spacing: 14) {
            ForEach(windows) { quotaReading($0, calendar: calendar) }
        }
    }

    private func quotaReading(_ window: ProviderLimitWindow, calendar: Calendar) -> some View {
        let value = quotaPercent(Double(100 - window.remainingPercent))
        return HStack(spacing: 5) {
            Text(window.quotaDisplayLabel).foregroundStyle(.secondary)
            Text(value).monospacedDigit().fontWeight(.medium)
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(window.quotaDisplayLabel) quota, \(value) used")
        .help(window.resetAt.map { "Resets \(chartTimestamp($0, calendar: calendar))" } ?? "Reset time unavailable")
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
            .labelsHidden().frame(width: 124)
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
        .labelsHidden().frame(width: 150)
        .disabled(models.isEmpty)
        .help("Filter the local token chart by model")
    }
}
