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
                let windows = target.report?.weeklyWindows ?? []
                let windowID = selection?.targetID == target.id ? selection?.windowID : nil
                let window = windows.first { $0.id == windowID } ?? windows.first
                let request = QuotaHistoryRequest(targetID: target.id, provider: target.provider,
                    windowID: window?.id, model: model.flatMap { tokens.models.contains($0) ? $0 : nil })
                VStack(alignment: .leading, spacing: 8) {
                    quotaControls(target: target, windows: windows, window: window, request: request)
                    if let report = target.report, let window {
                        QuotaHistoryFigure(data: .quota(WeeklyQuotaChart(report: report, window: window,
                                                                        history: quotaHistory.history, now: now)))
                    } else {
                        Text("No verified weekly quota for this connection.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        tokenControls(models: tokens.models, request: request)
                        QuotaHistoryFigure(data: .tokens(tokens))
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

    private func quotaControls(target: QuotaHistoryTarget, windows: [ProviderLimitWindow],
                               window: ProviderLimitWindow?, request: QuotaHistoryRequest) -> some View {
        HStack(spacing: 9) {
            if targets.count > 1 {
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
                .labelsHidden().frame(maxWidth: 142)
            } else {
                Text(target.label)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            if windows.count > 1, let window {
                Picker("Quota window", selection: Binding(get: { window.id }, set: { id in
                    var next = request
                    next.windowID = id
                    selection = next
                })) {
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

    private func tokenControls(models: [String], request: QuotaHistoryRequest) -> some View {
        HStack(spacing: 9) {
            Text("Local tokens").font(.system(size: 12, weight: .semibold))
            if !models.isEmpty {
                Picker("Model", selection: Binding(get: { request.model }, set: { model in
                    var next = request
                    next.model = model
                    selection = next
                })) {
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
}
