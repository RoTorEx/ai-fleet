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

    func quotaFigure(history: WeeklyQuotaHistory, now: Date) -> QuotaHistoryFigureData {
        let window = primaryQuotaWindow
        if let window, window.weeklyModel == nil, let report, report.weeklyWindows.contains(window) {
            return .quota(WeeklyQuotaChart(report: report, window: window, history: history, now: now))
        }
        return .currentQuota(QuotaLimitReading(window: window, measuredAt: status.lastUpdated, now: now,
                                              markedStale: status.quotaState == .stale))
    }
}

struct QuotaHistoryRequest: Equatable {
    let targetID: String
    let provider: StatisticsProvider
    var model: String?
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
    private var controlLabelWidth: CGFloat { openInStatistics == nil ? 142 : 110 }

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
                let model = selection?.provider == target.provider ? selection?.model : nil
                let tokens = LocalTokenHistory(snapshot: snapshot, provider: target.provider, model: model, now: now)
                let request = QuotaHistoryRequest(targetID: target.id, provider: target.provider,
                    model: model.flatMap { tokens.models.contains($0) ? $0 : nil })
                VStack(alignment: .leading, spacing: 8) {
                    controls(target: target, models: tokens.models, request: request)
                    if target.provider != .qwen, !target.quotaWindows.isEmpty {
                        quotaReadings(target.quotaWindows, stale: target.status.quotaState == .stale)
                    }
                    VStack(spacing: 0) {
                        if target.provider != .qwen {
                            let quota = QuotaHistoryDrawing(data: target.quotaFigure(history: quotaHistory.history, now: now))
                            QuotaHistoryFigure(drawing: quota, panel: .overview)
                            QuotaHistoryFigure(drawing: quota, panel: .hourly)
                        }
                        QuotaHistoryFigure(drawing: QuotaHistoryDrawing(data: .tokens(tokens)), panel: .hourly)
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
                modelPicker(models: models, request: request)
            }
            VStack(alignment: .leading, spacing: 6) {
                providerControl(target: target, request: request)
                modelPicker(models: models, request: request)
            }
        }
        .controlSize(.small)
    }

    @ViewBuilder private func providerControl(target: QuotaHistoryTarget, request: QuotaHistoryRequest) -> some View {
        if openInStatistics == nil {
            Picker("Provider and account", selection: Binding(
                get: { target.id },
                set: { value in
                    guard let next = targets.first(where: { $0.id == value }) else { return }
                    selection = QuotaHistoryRequest(targetID: next.id, provider: next.provider,
                        model: next.provider == target.provider ? request.model : nil)
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

    private func quotaReadings(_ windows: [ProviderLimitWindow], stale: Bool) -> some View {
        let title = stale ? "Last used" : "Used"
        return HStack(alignment: .top, spacing: 10) {
            Text(title).foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    ForEach(windows, content: quotaReading)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 105), alignment: .leading)], alignment: .leading) {
                    ForEach(windows, content: quotaReading)
                }
            }
        }
        .font(.system(size: 11))
    }

    private func quotaReading(_ window: ProviderLimitWindow) -> some View {
        let value = quotaPercent(Double(100 - window.remainingPercent))
        return HStack(spacing: 5) {
            Text(window.quotaDisplayLabel).foregroundStyle(.secondary)
            Text(value).monospacedDigit().fontWeight(.medium)
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(window.quotaDisplayLabel) quota, \(value) used")
        .help(window.resetAt.map { "Resets \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Reset time unavailable")
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
