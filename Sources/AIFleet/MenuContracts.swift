import Foundation

struct MenuAccountConnection: Identifiable {
    let account: FleetAccount
    let connection: ProviderConnection
    let status: ProviderStatus
    let isSelected: Bool
    var isCurrentCLI: Bool? = nil
    var usesAccountLogin = false
    var isSetup = false
    var id: String { connection.statusID }
}


struct MonitoringSummary {
    let monitoring: Bool
    let total: Int
    let measured: Int
    let lastChecked: Date?

    init(rows: [MenuAccountConnection], monitoring: Bool) {
        self.monitoring = monitoring
        let saved = rows.filter { !$0.isSetup && !$0.account.badge.isEmpty }
        total = saved.count
        measured = saved.filter { $0.status.hasCurrentQuota }.count
        lastChecked = saved.compactMap { $0.status.lastUpdated }.max()
    }
}

enum QuotaResetState: Equatable {
    case notReported, upcoming(Date), due
    init(resetAt: Date?, now: Date) {
        guard let resetAt, resetAt.timeIntervalSince1970.isFinite else { self = .notReported; return }
        self = resetAt > now ? .upcoming(resetAt) : .due
    }
    func text(now: Date) -> String {
        switch self {
        case .notReported: return "Not reported"
        case .due: return "Reset due"
        case .upcoming(let date):
            let interval = ceil(date.timeIntervalSince(now))
            guard interval > 0 else { return "Reset due" }
            guard interval < Double(Int.max) else { return "Not reported" }
            var seconds = Int(interval)
            let parts = [(86400, "d"), (3600, "h"), (60, "m"), (1, "s")].map { unit, suffix -> (Int, String) in
                let value = seconds / unit; seconds %= unit
                return (value, suffix)
            }
            // Only leading zero units are dropped: `2h 0m 5s`, never `0d 2h 0m 5s`.
            return parts.drop { $0.0 == 0 }.map { "\($0.0)\($0.1)" }.joined(separator: " ")
        }
    }
}

struct MenuLegendSection {
    let title: String
    let entries: [String]
    static let sections: [Self] = [
        .init(title: "Monitoring", entries: ["Active or paused", "Measured / saved enabled connections; zero remaining is measured"]),
        .init(title: "Accounts", entries: ["Stable account badges: α β γ δ ε ζ η θ ι κ", "Next launch selection does not establish login"]),
        .init(title: "Quotas", entries: ["0–10% critical; 11–25% low; above 25% normal", "Stale and unavailable are not current measurements"]),
        .init(title: "Reset", entries: ["d days; h hours; m minutes; s seconds", "Not reported: no date; Reset due: refresh required"]),
        .init(title: "Agents", entries: ["Working, Idle, Ready, Question/Approval, Error", "Unknown, Stale and Unlinked retain uncertainty; observed duration is a lower bound"])
    ]
}

@MainActor
func menuProviderRows(accounts: [FleetAccount], enabled: (String) -> Bool,
                      global: (String) -> ProviderStatus,
                      statusForConnection: (ProviderConnection) -> ProviderStatus?,
                      codex: CodexMonitoringStore) -> [MenuAccountConnection] {
    sortedAccountProviderRows(ProviderCatalog.all.filter { enabled($0.id) }.flatMap { provider in
        let rows = accountProviderRows(accounts: accounts, providerID: provider.id,
            global: global(provider.id), statusForConnection: statusForConnection, codex: codex)
        if !rows.isEmpty { return rows }
        let account = FleetAccount(id: "setup:" + provider.id, badgeIndex: -1, name: "", email: "", connections: [])
        return [MenuAccountConnection(account: account, connection: .global(provider.id),
            status: global(provider.id), isSelected: false, isSetup: true)]
    })
}
