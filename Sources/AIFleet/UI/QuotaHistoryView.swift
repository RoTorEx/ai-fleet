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

enum QuotaHistoryMode: String, CaseIterable, Identifiable {
    case quota = "Quota %"
    case tokens = "Local tokens"
    var id: Self { self }
}

struct QuotaHistoryRequest: Equatable {
    let targetID: String
    let provider: StatisticsProvider
    let mode: QuotaHistoryMode
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
    @State private var mode: QuotaHistoryMode
    @State private var targetID: String?
    @State private var windowID: String?
    @State private var model: String?

    init(targets: [QuotaHistoryTarget], request: QuotaHistoryRequest? = nil,
         openInStatistics: ((QuotaHistoryRequest) -> Void)? = nil) {
        self.targets = targets
        self.request = request
        self.openInStatistics = openInStatistics
        let hasWeeklyQuota = targets.first?.report?.weeklyWindows.isEmpty == false
        _mode = State(initialValue: request?.mode ?? (hasWeeklyQuota ? .quota : .tokens))
        _targetID = State(initialValue: request?.targetID)
        _windowID = State(initialValue: request?.windowID)
        _model = State(initialValue: request?.model)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            if let target = targets.first(where: { $0.id == targetID }) ?? targets.first {
                let now = timeline.date
                let tokenHistory = mode == .tokens
                    ? LocalTokenHistory(snapshot: snapshot, provider: target.provider, model: model, now: now) : nil
                let windows = target.report?.weeklyWindows ?? []
                let window = windows.first { $0.id == windowID } ?? windows.first
                VStack(alignment: .leading, spacing: 7) {
                    controls(target: target, windows: windows, window: window, models: tokenHistory?.models ?? [])
                    if let tokenHistory {
                        QuotaHistoryFigure(data: .tokens(tokenHistory))
                    } else if let report = target.report, let window {
                        QuotaHistoryFigure(data: .quota(WeeklyQuotaChart(report: report, window: window,
                                                                        history: quotaHistory.history, now: now)))
                    } else {
                        Text("No verified weekly quota for this connection.")
                            .font(.callout).foregroundStyle(.secondary).padding(.vertical, 12)
                    }
                    if let openInStatistics {
                        Button("Open in Statistics") {
                            openInStatistics(QuotaHistoryRequest(targetID: target.id, provider: target.provider,
                                mode: mode, windowID: window?.id, model: model))
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
        .onReceive(UsageAnalyticsService.shared.$snapshot) { snapshot = $0 }
        .onChange(of: request) { if let request = $0 { apply(request) } }
    }

    @ViewBuilder
    private func controls(target: QuotaHistoryTarget, windows: [ProviderLimitWindow],
                          window: ProviderLimitWindow?, models: [String]) -> some View {
        let choices = mode == .tokens ? uniqueProviders : targets
        HStack(spacing: 9) {
            Picker("History source", selection: $mode) {
                ForEach(QuotaHistoryMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().pickerStyle(.segmented).frame(width: 151)
            if choices.count > 1 {
                Picker(mode == .tokens ? "Provider" : "Account", selection: Binding(
                    get: { mode == .tokens ? choices.first(where: { $0.provider == target.provider })?.id ?? target.id : target.id },
                    set: { value in targetID = value; windowID = nil; model = nil }
                )) {
                    ForEach(choices) { choice in
                        Text(mode == .tokens ? choice.provider.title : choice.label).tag(choice.id)
                    }
                }
                .labelsHidden().frame(maxWidth: 142)
            } else {
                Text(mode == .tokens ? target.provider.title : target.label)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            if mode == .tokens, !models.isEmpty {
                Picker("Model", selection: Binding(get: { model.flatMap { models.contains($0) ? $0 : nil } },
                                                   set: { model = $0 })) {
                    Text("All models").tag(String?.none)
                    ForEach(models, id: \.self) { Text($0).tag(Optional($0)) }
                }
                .labelsHidden().frame(maxWidth: 150)
            } else if mode == .quota, windows.count > 1, let window {
                Picker("Quota window", selection: Binding(get: { window.id }, set: { windowID = $0 })) {
                    ForEach(windows) { scope in Text(scope.weeklyModel ?? "Account quota").tag(scope.id) }
                }
                .labelsHidden().frame(maxWidth: 150)
            } else if mode == .quota, let name = window?.weeklyModel {
                Text(name).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text(mode == .quota ? "Provider reports" : "On this Mac")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .controlSize(.small)
    }

    private var uniqueProviders: [QuotaHistoryTarget] {
        var seen = Set<StatisticsProvider>()
        return targets.filter { seen.insert($0.provider).inserted }
    }

    private func apply(_ request: QuotaHistoryRequest) {
        targetID = request.targetID
        mode = request.mode
        windowID = request.windowID
        model = request.model
    }
}
