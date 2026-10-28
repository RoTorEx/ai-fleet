import Foundation

func quotaAvailabilityText(_ statuses: [ProviderStatus]) -> String {
    statuses.isEmpty ? "none installed" : "\(statuses.filter(\.hasCurrentQuota).count)/\(statuses.count) loaded"
}

struct MenuConnectionState {
    let status: ProviderStatus
    var available: Bool { status.hasCurrentQuota }
    var marker: String { available ? "○" : status.authentication.needsAccess ? "×" : "?" }
    var detail: String {
        if status.authentication.needsAccess { return "Sign in to load limits" }
        if status.quotaState == .unsupported { return "Limit tracking not supported" }
        if status.quotaState == .stale { return "Last known limits · update pending" }
        if status.detail == "Signed in · quota unavailable" || status.detail == "Quota unavailable" { return "Limits unavailable" }
        if status.detail == "Auth status unknown" { return "Could not verify login" }
        return status.detail.replacingOccurrences(of: "Signed in · ", with: "")
            .replacingOccurrences(of: "quota", with: "limits")
            .replacingOccurrences(of: "Quota", with: "Limits")
    }
}

struct MenuOperationStatus {
    let title: String
    var detail: String? = nil
    var failed = false

    static func resolve(update: UpdateService.State, refreshing: Bool, signingIn: String? = nil) -> Self {
        switch update {
        case .checking: return Self(title: "Checking for updates…")
        case .downloading(let version): return Self(title: "Downloading v\(version)…")
        case .installing(let version): return Self(title: "Installing v\(version)…")
        case .failed(let message): return Self(title: "Update failed", detail: message, failed: true)
        case .idle, .upToDate:
            if let signingIn { return Self(title: signingIn) }
            if refreshing { return Self(title: "Updating limits…") }
            if case .upToDate = update { return Self(title: "Up to date") }
            return Self(title: "Idle")
        }
    }
}

/// Keep tools together; prioritize the current CLI account within each tool.
func sortedAccountProviderRows(_ rows: [MenuAccountConnection]) -> [MenuAccountConnection] {
    rows.sorted { lhs, rhs in
        let toolOrder = lhs.status.name.localizedCaseInsensitiveCompare(rhs.status.name)
        if toolOrder != .orderedSame { return toolOrder == .orderedAscending }
        let lhsCurrent = lhs.isCurrentCLI ?? lhs.isSelected
        let rhsCurrent = rhs.isCurrentCLI ?? rhs.isSelected
        if lhsCurrent != rhsCurrent { return lhsCurrent }
        if lhs.account.badgeIndex != rhs.account.badgeIndex {
            return lhs.account.badgeIndex < rhs.account.badgeIndex
        }
        return lhs.id < rhs.id
    }
}

/// The badge always identifies a Fleet account, regardless of credential storage.
@MainActor
func accountProviderRows(accounts: [FleetAccount], providerID: String, global: ProviderStatus,
                         statusForConnection: (ProviderConnection) -> ProviderStatus?,
                         codex: CodexMonitoringStore) -> [MenuAccountConnection] {
    let linked = accounts.filter { $0.connection(for: providerID) != nil }
    let named = linked.filter { $0.id != FleetAccount.defaultID || !$0.email.isEmpty }
    return (named.isEmpty ? linked : named).compactMap { account in
        guard let connection = account.connection(for: providerID) else { return nil }
        let status = providerID == "codex" ? connection.status(from: codex.status(for: account, global: global, accounts: accounts))
            : statusForConnection(connection) ?? connection.status(from: LocalProviderAuth.unknown.status(for: ProviderCatalog.definition(for: providerID)!))
        let currentCLI = global.authentication == .signedIn && !account.email.isEmpty &&
            global.account?.email?.caseInsensitiveCompare(account.email) == .orderedSame
        return MenuAccountConnection(account: account, connection: connection, status: status,
            isSelected: status.authentication == .signedIn,
            isCurrentCLI: currentCLI, usesAccountLogin: providerID == "codex")
    }
}
