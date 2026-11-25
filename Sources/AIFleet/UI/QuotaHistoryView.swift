import SwiftUI

struct QuotaHistoryTarget: Identifiable, Equatable {
    let id: String
    let provider: StatisticsProvider
    let label: String
    let report: StatisticsProviderReport?

    @MainActor
    init?(row: MenuAccountConnection, codex: CodexMonitoringStore) {
        guard let provider = StatisticsProvider(rawValue: row.connection.providerID) else { return nil }
        self.provider = provider
        id = row.id
        label = row.isSetup ? provider.title : "\(provider.title) (\(row.accountScope))"
        report = row.statisticsReport(codex: codex)
    }
}

struct QuotaHistoryRequest: Equatable {
    let targetID: String
    let provider: StatisticsProvider
    let windowID: String?
    let model: String?
}

@MainActor
final class QuotaHistoryNavigation: ObservableObject {
    static let shared = QuotaHistoryNavigation()
    @Published var request: QuotaHistoryRequest?
}

struct QuotaHistoryView: View {
    let targets: [QuotaHistoryTarget]
    let request: QuotaHistoryRequest?
    let openInStatistics: ((QuotaHistoryRequest) -> Void)?
    @ObservedObject private var quotaHistory = WeeklyQuotaHistoryStore.shared
    @State private var snapshot = UsageAnalyticsService.shared.snapshot
    @State private var targetID: String?
    @State private var windowID: String?
    @State private var model: String?

    init(targets: [QuotaHistoryTarget], request: QuotaHistoryRequest? = nil,
         openInStatistics: ((QuotaHistoryRequest) -> Void)? = nil) {
        self.targets = targets
        self.request = request
        self.openInStatistics = openInStatistics
        _targetID = State(initialValue: request?.targetID)
        _windowID = State(initialValue: request?.windowID)
        _model = State(initialValue: request?.model)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            if let target = targets.first(where: { $0.id == targetID }) ?? targets.first {
                let now = timeline.date
                let tokens = LocalTokenHistory(snapshot: snapshot, provider: target.provider, model: model, now: now)
                let windows = target.report?.weeklyWindows ?? []
                let window = windows.first { $0.id == windowID } ?? windows.first
                VStack(alignment: .leading, spacing: 8) {
                    quotaControls(target: target, windows: windows, window: window)
                    if let report = target.report, let window {
                        QuotaHistoryFigure(data: .quota(WeeklyQuotaChart(report: report, window: window,
                                                                        history: quotaHistory.history, now: now)))
                    } else {
                        Text("No verified weekly quota for this connection.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        tokenControls(models: tokens.models)
                        QuotaHistoryFigure(data: .tokens(tokens))
                    }
                    if let openInStatistics {
                        Button("Open in Statistics") {
                            openInStatistics(QuotaHistoryRequest(targetID: target.id, provider: target.provider,
                                windowID: window?.id, model: model))
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
        .onReceive(UsageAnalyticsService.shared.$snapshot) { snapshot = $0 }
        .onChange(of: request) { if let request = $0 { apply(request) } }
    }

    private func quotaControls(target: QuotaHistoryTarget, windows: [ProviderLimitWindow],
                               window: ProviderLimitWindow?) -> some View {
        HStack(spacing: 9) {
            if targets.count > 1 {
                Picker("Provider and account", selection: Binding(
                    get: { target.id },
                    set: { value in selectTarget(value, previousProvider: target.provider) }
                )) {
                    ForEach(targets) { Text($0.label).tag($0.id) }
                }
                .labelsHidden().frame(maxWidth: 142)
            } else {
                Text(target.label)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            if windows.count > 1, let window {
                Picker("Quota window", selection: Binding(get: { window.id }, set: { windowID = $0 })) {
                    ForEach(windows) { scope in Text(scope.weeklyModel ?? "Account quota").tag(scope.id) }
                }
                .labelsHidden().frame(maxWidth: 150)
            } else if let name = window?.weeklyModel {
                Text(name).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if window != nil {
                Text("Provider reports").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .controlSize(.small)
    }

    private func tokenControls(models: [String]) -> some View {
        HStack(spacing: 9) {
            Text("Local tokens").font(.system(size: 12, weight: .semibold))
            if !models.isEmpty {
                Picker("Model", selection: Binding(get: { model.flatMap { models.contains($0) ? $0 : nil } },
                                                   set: { model = $0 })) {
                    Text("All models").tag(String?.none)
                    ForEach(models, id: \.self) { Text($0).tag(Optional($0)) }
                }
                .labelsHidden().frame(maxWidth: 150)
            }
            Spacer(minLength: 0)
            Text("On this Mac").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }
        .controlSize(.small)
    }

    private func selectTarget(_ id: String, previousProvider: StatisticsProvider) {
        if targets.first(where: { $0.id == id })?.provider != previousProvider { model = nil }
        targetID = id
        windowID = nil
    }

    private func apply(_ request: QuotaHistoryRequest) {
        targetID = request.targetID
        windowID = request.windowID
        model = request.model
    }
}
