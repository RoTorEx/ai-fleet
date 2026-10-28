import Foundation

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
