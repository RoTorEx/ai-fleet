import AppKit
import SwiftUI

/// Accounts in Greek-letter order; drag a row to reorder, and the letters follow.
struct AccountsSettingsView: View {
    @ObservedObject private var store = AccountStore.shared
    @ObservedObject private var codex = CodexMonitoringStore.shared
    @ObservedObject private var service = StatusService.shared
    @ObservedObject private var navigation = SettingsNavigation.shared
    @ObservedObject private var switching = SwitchCoordinator.shared
    @State private var sheet: AccountSheet?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Drag to reorder. Letters follow the order, starting at α.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button { sheet = .add(providerID: nil) } label: { Label("Add Account", systemImage: "plus") }
            }
            .padding(.horizontal, 8)
            notices.padding(.horizontal, 8)
            if store.visibleAccounts.isEmpty {
                VStack(spacing: 6) {
                    Text("No accounts yet").font(.system(size: 13, weight: .semibold))
                    Text("Add an account by email, then connect its providers.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(store.visibleAccounts) { account in
                        AccountBlock(account: account, edit: { sheet = .edit(account.id) })
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    }
                    .onMove { store.moveAccounts(from: $0, to: $1) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case let .add(providerID): AddAccountSheet(providerID: providerID)
            case let .edit(id): EditAccountSheet(accountID: id)
            }
        }
        .onAppear { codex.synchronizeAccounts(store); consumeAddRequest(); service.refresh() }
        .onChange(of: navigation.addingProviderID) { _ in consumeAddRequest() }
    }

    @ViewBuilder private var notices: some View {
        if let detail = switching.detail {
            Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
        ForEach(Array(switching.active).sorted(), id: \.self) { provider in
            Button("Cancel \(provider.capitalized) switch") { switching.cancel(provider) }.controlSize(.small)
        }
        CodexAccountAuthenticationStatus(store: codex, accounts: store)
        if let error = store.launchError {
            Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "Set up connection…" in the menu lands here with its provider preselected.
    private func consumeAddRequest() {
        guard let requested = navigation.addingProviderID else { return }
        sheet = .add(providerID: requested)
        navigation.addingProviderID = nil
    }
}

private enum AccountSheet: Identifiable {
    case add(providerID: String?)
    case edit(String)
    var id: String {
        switch self {
        case let .add(provider): return "add:" + (provider ?? "")
        case let .edit(id): return "edit:" + id
        }
    }
}

/// One account: letter, name and email, then its provider connections.
private struct AccountBlock: View {
    let account: FleetAccount
    let edit: () -> Void
    @ObservedObject private var store = AccountStore.shared
    @ObservedObject private var codex = CodexMonitoringStore.shared
    @ObservedObject private var providerLaunch = ProviderLaunchStore.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var service = StatusService.shared
    @State private var confirmsRemoval = false
    @State private var hovering = false

    private var connections: [ProviderConnection] {
        account.connections.filter { settings.isEnabled($0.providerID) }
            .sorted { providerName($0.providerID) < providerName($1.providerID) }
    }
    private var connectable: [ProviderDefinition] {
        ProviderCatalog.all.filter { settings.isEnabled($0.id) && account.connection(for: $0.id) == nil }
            .sorted { $0.name < $1.name }
    }
    private var busy: Bool {
        providerLaunch.busy || codex.refreshing || codex.authenticatingID != nil || service.signingOutProvider != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                    .opacity(hovering ? 1 : 0.5)
                    .help("Drag to reorder")
                Text(account.badge)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(account.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if account.email.caseInsensitiveCompare(account.name) != .orderedSame {
                        Text(account.email.isEmpty ? "No email" : account.email)
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Menu {
                    Button("Edit…", action: edit)
                    Divider()
                    Button("Remove Account…", role: .destructive) { confirmsRemoval = true }
                        .disabled(busy || !SwitchCoordinator.shared.active.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 14))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Account actions")
            }
            .padding(.horizontal, 10).padding(.vertical, 8)

            Divider().padding(.leading, 10)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(connections) { connection in
                    ConnectionRow(account: account, connection: connection)
                }
                if !connectable.isEmpty {
                    Menu {
                        ForEach(connectable) { provider in
                            Button(provider.name) { connect(provider.id) }
                        }
                    } label: {
                        Label("Connect Provider", systemImage: "plus.circle").font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .disabled(busy)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
        }
        .background(Color.primary.opacity(hovering ? 0.07 : 0.045), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08)))
        .onHover { hovering = $0 }
        .confirmationDialog("Remove \(account.badge) \(account.name)?", isPresented: $confirmsRemoval) {
            Button("Remove Account", role: .destructive, action: remove)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("AI Fleet forgets this account and its provider links. Credentials, session history and running processes stay on this Mac. Accounts below move up one letter.")
        }
    }

    private func providerName(_ id: String) -> String { ProviderCatalog.definition(for: id)?.name ?? id }

    private func connect(_ providerID: String) {
        store.attachGlobal(providerID, to: account.id)
        guard let updated = store.accounts.first(where: { $0.id == account.id }) else { return }
        if providerID == "codex" { codex.signIn(codex.ensureProfile(for: updated)) }
        else { providerLaunch.signIn(updated, providerID: providerID) }
        service.refresh()
    }

    private func remove() {
        guard SwitchCoordinator.shared.active.isEmpty, !busy else { return }
        guard codex.forgetAccount(account) else { return }
        do { try providerLaunch.forget(account.id) } catch { return }
        store.remove(account.id)
        service.refresh()
    }
}

/// A provider under an account: status on the left, its actions on the right.
private struct ConnectionRow: View {
    let account: FleetAccount
    let connection: ProviderConnection
    @ObservedObject private var store = AccountStore.shared
    @ObservedObject private var codex = CodexMonitoringStore.shared
    @ObservedObject private var providerLaunch = ProviderLaunchStore.shared
    @ObservedObject private var service = StatusService.shared
    @State private var confirmsDisconnect = false

    private var isCodex: Bool { connection.providerID == "codex" }
    private var name: String { ProviderCatalog.definition(for: connection.providerID)?.name ?? connection.providerID }
    private var status: ProviderStatus? {
        isCodex ? codex.status(for: account, global: service.codex, accounts: store.visibleAccounts)
            : service.status(for: connection)
    }
    private var signedIn: Bool { status?.authentication == .signedIn }
    private var sharedLogin: Bool { isCodex && codex.profile(for: account) == nil }
    private var busy: Bool {
        providerLaunch.busy || codex.authenticatingID != nil || service.signingOutProvider != nil || (isCodex && codex.refreshing)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Circle().fill(signedIn ? Color.green : Color.secondary.opacity(0.5)).frame(width: 6, height: 6)
                Text(name).font(.system(size: 12, weight: .medium)).frame(width: 58, alignment: .leading)
                Text(status?.detail ?? "Checking…")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    .help(sharedLogin ? "Uses the shared terminal login. Sign in here once to keep access when the terminal account changes." : status?.detail ?? "")
                Spacer(minLength: 6)
                actions.controlSize(.small).disabled(busy)
                Menu {
                    Button("Disconnect \(name)…", role: .destructive) { confirmsDisconnect = true }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 11))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .disabled(busy || SwitchCoordinator.shared.active.contains(connection.providerID))
            }
            if providerLaunch.messageAccountID == account.id, providerLaunch.messageProviderID == connection.providerID,
               let message = providerLaunch.message {
                note(message)
            }
        }
        .confirmationDialog("Disconnect \(name) from \(account.badge) \(account.name)?", isPresented: $confirmsDisconnect) {
            Button("Disconnect", role: .destructive, action: disconnect)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("AI Fleet forgets this link. Credentials, session history and running processes stay on this Mac.")
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 4) {
            if isCodex {
                if codex.profile(for: account) == nil,
                   service.codex.account?.email?.caseInsensitiveCompare(account.email) == .orderedSame {
                    Button("Save Login") { codex.saveCurrentLogin(account) }
                        .help("Keep the current terminal login for this account")
                }
                if codex.profile(for: account) != nil {
                    Button("Switch") { codex.switchAccount(account) }
                        .help("The next codex command uses this account; running sessions keep theirs.")
                }
                if let profile = codex.profile(for: account), signedIn {
                    Button("Sign Out") { codex.signOut(profile) }
                } else {
                    Button("Sign In…") { codex.signIn(codex.ensureProfile(for: account)) }
                }
            } else {
                Button("Switch") {
                    providerLaunch.switchAccount(account, providerID: connection.providerID,
                                                 global: service.status(for: connection.providerID))
                }
                if signedIn {
                    Button("Sign Out") { providerLaunch.signOut(account, providerID: connection.providerID) }
                } else {
                    Button("Sign In…") { providerLaunch.signIn(account, providerID: connection.providerID) }
                }
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 10.5)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 14)
    }

    private func disconnect() {
        guard !busy, !SwitchCoordinator.shared.active.contains(connection.providerID) else { return }
        if isCodex { guard codex.forgetAccount(account) else { return } }
        else { do { try providerLaunch.forgetProvider(connection.providerID, accountID: account.id) } catch { return } }
        store.detach(connection.providerID, from: account.id)
        service.refresh()
    }
}

/// New account by email (it takes the next letter), optionally connecting a provider right away.
private struct AddAccountSheet: View {
    let providerID: String?
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = AccountStore.shared
    @ObservedObject private var codex = CodexMonitoringStore.shared
    @ObservedObject private var providerLaunch = ProviderLaunchStore.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var service = StatusService.shared
    @State private var email = ""
    @State private var name = ""
    @State private var provider = ""
    @State private var targetID = ""

    private var trimmed: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var createsAccount: Bool { targetID.isEmpty }
    private var duplicateEmail: Bool {
        createsAccount && store.visibleAccounts.contains { ConnectionIdentity.normalize($0.email) == ConnectionIdentity.normalize(trimmed) }
    }
    private var target: FleetAccount? { store.visibleAccounts.first { $0.id == targetID } }
    private var alreadyConnected: Bool { !provider.isEmpty && target?.connection(for: provider) != nil }
    private var nextLetter: String {
        FleetAccount(id: "", badgeIndex: store.visibleAccounts.count, name: "", email: "", connections: []).badge
    }
    private var canSubmit: Bool {
        if createsAccount { return !trimmed.isEmpty && trimmed.contains("@") && !duplicateEmail }
        return !provider.isEmpty && !alreadyConnected
    }
    private var importable: [ProviderStatus] {
        [service.codex, service.claude].filter { status in
            guard let identity = ConnectionIdentity(status: status) else { return false }
            return !store.visibleAccounts.contains {
                ConnectionIdentity.normalize($0.email) == identity.email && $0.connection(for: status.providerID) != nil
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(providerID == nil ? "Add Account" : "Connect \(ProviderCatalog.definition(for: providerID!)?.name ?? "Provider")")
                .font(.headline)
            Form {
                if providerID != nil, !store.visibleAccounts.isEmpty {
                    Picker("Account", selection: $targetID) {
                        Text("New account (\(nextLetter))").tag("")
                        ForEach(store.visibleAccounts) { Text("\($0.badge)  \($0.name)").tag($0.id) }
                    }
                }
                if createsAccount {
                    TextField("Email", text: $email, prompt: Text("name@example.com"))
                    TextField("Name", text: $name, prompt: Text("Optional, e.g. Work"))
                }
                Picker("Provider", selection: $provider) {
                    if createsAccount { Text("None for now").tag("") }
                    ForEach(ProviderCatalog.all.filter { settings.isEnabled($0.id) }.sorted { $0.name < $1.name }) {
                        Text($0.name).tag($0.id)
                    }
                }
            }
            .formStyle(.columns)
            Group {
                if duplicateEmail { Text("An account with this email already exists.") }
                else if alreadyConnected { Text("This provider is already connected to that account.") }
                else if createsAccount { Text("The account becomes \(nextLetter). Drag it in the list to change its letter.") }
            }
            .font(.caption).foregroundStyle(.secondary)

            if !importable.isEmpty && createsAccount {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Or import a terminal login").font(.caption).foregroundStyle(.secondary)
                    ForEach(importable, id: \.providerID) { status in
                        Button("Import \(status.name) · \(status.account?.email ?? "")") {
                            store.importNative(status); service.refresh(); dismiss()
                        }
                        .controlSize(.small)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(provider.isEmpty ? "Add" : "Add & Sign In…", action: submit)
                    .keyboardShortcut(.defaultAction).disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear {
            provider = providerID ?? ""
            if providerID != nil { targetID = store.visibleAccounts.first?.id ?? "" }
        }
    }

    private func submit() {
        let account: FleetAccount
        if let target { account = target }
        else { account = store.add(name: name.trimmingCharacters(in: .whitespaces).isEmpty ? trimmed : name, email: trimmed) }
        if !provider.isEmpty, account.connection(for: provider) == nil {
            store.attachGlobal(provider, to: account.id)
            let updated = store.accounts.first { $0.id == account.id } ?? account
            if provider == "codex" { codex.signIn(codex.ensureProfile(for: updated)) }
            else { providerLaunch.signIn(updated, providerID: provider) }
        }
        service.refresh()
        dismiss()
    }
}

private struct EditAccountSheet: View {
    let accountID: String
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = AccountStore.shared
    @State private var name = ""
    @State private var email = ""

    private var account: FleetAccount? { store.accounts.first { $0.id == accountID } }
    private var emailLocked: Bool { !(account?.connections.isEmpty ?? true) && !(account?.email.isEmpty ?? true) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit \(account?.badge ?? "") Account").font(.headline)
            Form {
                TextField("Name", text: $name)
                TextField("Email", text: $email).disabled(emailLocked)
            }
            .formStyle(.columns)
            if emailLocked {
                Text("Disconnect its providers to change the email.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    store.update(accountID, name: name, email: email); dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { name = account?.name ?? ""; email = account?.email ?? "" }
    }
}

struct CodexAccountAuthenticationStatus: View {
    @ObservedObject var store: CodexMonitoringStore
    @ObservedObject var accounts: AccountStore
    var accountID: String? = nil
    @State private var showsSwitchDetails = false

    private func matches(_ id: String?) -> Bool {
        guard let accountID else { return true }
        return store.profiles.first { $0.id == id }?.accountID == accountID
    }
    private func label(_ id: String?) -> String {
        let linkedID = store.profiles.first { $0.id == id }?.accountID
        let badge = accounts.accounts.first { $0.id == linkedID }?.badge ?? ""
        return badge.isEmpty ? "Codex" : "Codex (\(badge))"
    }
    var body: some View {
        Group {
            if let accountID, store.nextLaunchAccountID == accountID {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Next codex launch · running sessions keep their accounts")
                    if store.terminalSetupNotice {
                        Text("One-time setup for terminals already open: run rehash. No terminal restart is needed.")
                    }
                }
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let id = store.authenticatingID, matches(id) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.small)
                        Text(store.authenticationAction == .logout ? "\(label(id)): signing out…" : "\(label(id)): complete sign-in in your browser…")
                            .font(.caption).fixedSize(horizontal: false, vertical: true)
                    }
                    Button("Cancel") { store.cancelAuthentication() }.font(.caption).buttonStyle(.link)
                }
            }
            if let error = store.error, matches(store.errorProfileID) {
                if let pids = store.switchBlockedProcessIDs {
                    CodexSwitchBlockedNotice(label: label(store.errorProfileID), processIDs: pids,
                                             isExpanded: $showsSwitchDetails)
                } else {
                    Text("\(label(store.errorProfileID)): \(error)").font(.caption).foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        // A new action must not inherit the previous notice's expanded details.
        .onChange(of: store.error) { _ in showsSwitchDetails = false }
    }
}

struct CodexSwitchBlockedNotice: View {
    let label: String
    let processIDs: [Int32]
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(label): switching unavailable while Codex is running. Current login preserved.")
                .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("Details", isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Open Agents → Processes to review and stop remaining Codex processes, then retry. Reopen saved conversations with codex resume. Selecting a default account for new launches does not require stopping these processes.")
                    Text("Running PIDs: \(processIDs.map(String.init).joined(separator: ", "))")
                        .textSelection(.enabled)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.caption)
        .foregroundColor(.secondary)
    }
}

struct CodexSignInProgress: View {
    @ObservedObject var accounts: AccountStore

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Complete Codex sign-in in your browser…")
                .font(.caption)
            Button("Cancel sign-in") { accounts.cancelCodexSignIn() }
                .font(.caption)
        }
        .accessibilityElement(children: .contain)
    }
}
