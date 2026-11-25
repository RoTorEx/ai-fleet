import SwiftUI

struct LogsView: View {
    @ObservedObject var agents: AgentSessionsService
    @ObservedObject private var analytics = UsageAnalyticsService.shared
    @ObservedObject private var service = StatusService.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var accounts = AccountStore.shared
    @ObservedObject private var codexProfiles = CodexMonitoringStore.shared
    @ObservedObject private var providerLaunch = ProviderLaunchStore.shared
    @ObservedObject private var updater = UpdateService.shared
    @ObservedObject private var quotaHistory = WeeklyQuotaHistoryStore.shared
    @State private var sourceIssues: [StatisticsSourceIssue] = []

    var body: some View {
        let appIssues = appIssues
        let groupedSources = Dictionary(grouping: Set(sourceIssues), by: \.provider)
        VStack(alignment: .leading, spacing: 0) {
            scanStatus
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            Divider()
            if appIssues.isEmpty && sourceIssues.isEmpty {
                Text("No issues to show.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if !appIssues.isEmpty {
                        Section("App issues") {
                            ForEach(appIssues, id: \.self) { issue in
                                issueRow(title: issue.label, message: issue.text, isError: issue.severity == .error)
                            }
                        }
                    }
                    ForEach([nil] + StatisticsProvider.allCases.map(Optional.some), id: \.self) { provider in
                        if let issues = groupedSources[provider] {
                            Section(provider.map { "\($0.title) statistics" } ?? "Statistics") {
                                ForEach(issues.sorted { $0.message < $1.message }, id: \.self) { issue in
                                    issueRow(message: issue.message)
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .onReceive(analytics.$snapshot) { snapshot in
            sourceIssues = LocalStatistics(snapshot: snapshot).sourceIssues
        }
    }

    private var scanStatus: some View {
        HStack(spacing: 8) {
            if analytics.isRefreshing {
                ProgressView().controlSize(.small)
                Text("Scanning statistics…")
            } else if let date = analytics.snapshot.refreshedAt {
                Text("Last statistics scan")
                Text(date.formatted(date: .abbreviated, time: .shortened))
                    .monospacedDigit()
            } else {
                Text("Statistics scan pending")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private var appIssues: [MenuStatusNote] {
        let connections = menuProviderRows(accounts: accounts.accounts, enabled: settings.isEnabled,
            global: service.status(for:), statusForConnection: service.status(for:), codex: codexProfiles)
        var notes = fleetStatusNotes(connections: connections, accounts: accounts,
                                     codexProfiles: codexProfiles, providerLaunch: providerLaunch)
        for entry in connections where entry.status.quotaNotice == nil {
            guard entry.status.quotaFailure == .network || entry.status.quotaFailure == .invalidResponse else { continue }
            let label = entry.account.badge.isEmpty ? entry.status.name : "\(entry.status.name) (\(entry.account.badge))"
            notes.append(.init(label: label, text: MenuConnectionState(status: entry.status).detail, severity: .error))
        }
        for error in [agents.error, agents.jumpError].compactMap({ $0 }) {
            notes.append(.init(label: "Agents", text: error, severity: .error))
        }
        if case .failed(let message) = updater.state {
            notes.append(.init(label: "Update", text: message, severity: .error))
        }
        if let issue = quotaHistory.issue {
            notes.append(.init(label: "Quota history", text: issue, severity: .error))
        }
        return Set(notes.filter { $0.severity != .info }).sorted {
            if $0.severity != $1.severity { return $0.severity == .error }
            if $0.label != $1.label { return $0.label < $1.label }
            return $0.text < $1.text
        }
    }

    private func issueRow(title: String? = nil, message: String, isError: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isError ? "exclamationmark.circle" : "exclamationmark.triangle")
                .foregroundStyle(isError ? FleetPalette.danger : FleetPalette.warning)
                .frame(width: 16)
                .accessibilityLabel(isError ? "Error" : "Warning")
            VStack(alignment: .leading, spacing: 3) {
                if let title { Text(title).fontWeight(.semibold) }
                Text(verbatim: message)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.callout)
        .padding(.vertical, 4)
    }
}
