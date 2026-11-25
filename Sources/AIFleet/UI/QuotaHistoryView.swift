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

    func selectedWindow(_ id: String?) -> ProviderLimitWindow? {
        let windows = quotaWindows
        return windows.first { $0.id == id }
            ?? windows.first { $0.isWeeklyQuota && $0.weeklyModel == nil }
            ?? windows.max { ($0.durationSeconds ?? 0) < ($1.durationSeconds ?? 0) }
    }

    func quotaFigure(window: ProviderLimitWindow?, history: WeeklyQuotaHistory, now: Date) -> QuotaHistoryFigureData {
        if let window, let report, report.weeklyWindows.contains(window) {
            return .quota(WeeklyQuotaChart(report: report, window: window, history: history, now: now))
        }
        return .currentQuota(QuotaLimitReading(window: window, measuredAt: status.lastUpdated, now: now,
                                              markedStale: status.quotaState == .stale))
    }
}

struct QuotaHistoryRequest: Equatable {
    let targetID: String
    let provider: StatisticsProvider
    var windowID: String?
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
                let windowID = selection?.targetID == target.id ? selection?.windowID : nil
                let window = target.selectedWindow(windowID)
                let request = QuotaHistoryRequest(targetID: target.id, provider: target.provider,
                    windowID: window?.id, model: model.flatMap { tokens.models.contains($0) ? $0 : nil })
                VStack(alignment: .leading, spacing: 8) {
                    controls(target: target, models: tokens.models, request: request)
                    VStack(spacing: 0) {
                        if target.provider != .qwen {
                            let quota = QuotaHistoryDrawing(data: target.quotaFigure(window: window,
                                history: quotaHistory.history, now: now))
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
                quotaControls(target: target, request: request)
                Spacer(minLength: 0)
                modelPicker(models: models, request: request)
            }
            VStack(alignment: .leading, spacing: 6) {
                quotaControls(target: target, request: request)
                modelPicker(models: models, request: request)
            }
        }
        .controlSize(.small)
    }

    private func quotaControls(target: QuotaHistoryTarget, request: QuotaHistoryRequest) -> some View {
        let windows = target.quotaWindows
        return HStack(spacing: 8) {
            if openInStatistics == nil {
                Picker("Provider and account", selection: Binding(
                    get: { target.id },
                    set: { value in
                        guard let next = targets.first(where: { $0.id == value }) else { return }
                        selection = QuotaHistoryRequest(targetID: next.id, provider: next.provider, windowID: nil,
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
            if target.provider != .qwen {
                Picker("Quota window", selection: Binding(get: { request.windowID }, set: { id in
                    var next = request
                    next.windowID = id
                    selection = next
                })) {
                    if windows.isEmpty { Text("Quota unavailable").tag(String?.none) }
                    ForEach(windows) { scope in Text(scope.quotaDisplayLabel).tag(Optional(scope.id)) }
                }
                .labelsHidden().frame(width: 150, alignment: .leading)
                .disabled(windows.count < 2)
            }
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
