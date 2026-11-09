import Foundation

/// One source for the menu card and the menu-bar attention indicator.
@MainActor
func fleetStatusNotes(connections: [MenuAccountConnection], accounts: AccountStore,
                      codexProfiles: CodexMonitoringStore, providerLaunch: ProviderLaunchStore) -> [MenuStatusNote] {
    var notes: [MenuStatusNote] = []
    func label(_ entry: MenuAccountConnection) -> String {
        entry.account.badge.isEmpty ? entry.status.name : "\(entry.status.name) (\(entry.account.badge))"
    }
    for entry in connections {
        if let notice = entry.status.quotaNotice {
            notes.append(.init(label: label(entry), text: notice, severity: entry.isSelected ? .warning : .info))
        }
        if providerLaunch.messageIsError, let message = providerLaunch.message,
           providerLaunch.messageAccountID == entry.account.id, providerLaunch.messageProviderID == entry.status.providerID {
            notes.append(.init(label: label(entry), text: message, severity: .error))
        }
        if entry.usesAccountLogin, let error = codexProfiles.error,
           codexProfiles.profiles.first(where: { $0.id == codexProfiles.errorProfileID })?.accountID == entry.account.id {
            let text = codexProfiles.switchBlockedProcessIDs == nil ? error
                : "Switch blocked while Codex is running. Stop it in Processes, then retry."
            notes.append(.init(label: label(entry), text: text, severity: .error))
        }
    }
    if let error = accounts.launchError {
        let provider = accounts.launchProviderID.flatMap { ProviderCatalog.definition(for: $0)?.name } ?? "Sign-in"
        notes.append(.init(label: provider, text: error, severity: .error))
    }
    if codexProfiles.terminalSetupNotice {
        notes.append(.init(label: "Codex", text: "Terminals opened earlier: run rehash once.", severity: .info))
    }
    return notes
}

extension MenuStatusNote {
    static func attention(in notes: [MenuStatusNote]) -> Severity? {
        if notes.contains(where: { $0.severity == .error }) { return .error }
        if notes.contains(where: { $0.severity == .warning }) { return .warning }
        return nil
    }
}
