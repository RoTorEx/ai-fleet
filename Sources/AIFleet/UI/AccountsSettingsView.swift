import AppKit
import SwiftUI

struct AccountsSettingsView: View {
    @ObservedObject private var store = AccountStore.shared
    @ObservedObject private var codex = CodexMonitoringStore.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var service = StatusService.shared
    @ObservedObject private var navigation = SettingsNavigation.shared
    @State private var selectedID = ""
    @State private var isAdding = false
    @State private var createsAccount = false
    @State private var targetID = ""
    @State private var providerID = "codex"
    @State private var email = ""
    @State private var name = ""

    private var selected: FleetAccount? {
        store.visibleAccounts.first { $0.id == selectedID } ?? store.visibleAccounts.first
    }
    private var target: FleetAccount? {
        store.visibleAccounts.first { $0.id == targetID } ?? selected
    }
    private var duplicate: Bool { !createsAccount && target?.connection(for: providerID) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Each letter identifies one account. Connect each provider once per account.")
                .font(.callout).foregroundColor(.secondary)
            if !isAdding {
                HStack {
                    if !store.visibleAccounts.isEmpty {
                        Picker("Account", selection: Binding(get: { selected?.id ?? "" }, set: { selectedID = $0 })) {
                            ForEach(store.visibleAccounts) { account in
                                Text("\(account.badge) · \(account.name)").tag(account.id)
                            }
                        }
                    }
                    Button("Connect provider…") {
                        targetID = selected?.id ?? ""
                        createsAccount = store.visibleAccounts.isEmpty
                        isAdding = true
                    }
                }
            }
            if isAdding { connectionForm }
            else if let selected { AccountEditor(account: selected).id(selected.id) }
            CodexAccountAuthenticationStatus(store: codex, accounts: store)
            if let error = store.launchError { Text(error).font(.caption).foregroundColor(.red) }
            DisclosureGroup("Provider visibility") {
                ForEach(ProviderCatalog.all) { provider in
                    Toggle("Show \(provider.name)", isOn: Binding(
                        get: { settings.isEnabled(provider.id) },
                        set: { settings.setEnabled($0, for: provider.id); service.refresh() }
                    ))
                }
            }.font(.callout)
        }
        .onAppear { codex.synchronizeAccounts(store); consumeAddRequest(); service.refresh() }
        .onChange(of: navigation.addingProviderID) { _ in consumeAddRequest() }
    }

    private var connectionForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Provider", selection: $providerID) {
                ForEach(ProviderCatalog.all.filter { settings.isEnabled($0.id) }) { Text($0.name).tag($0.id) }
            }
            Picker("Connect to", selection: $createsAccount) {
                Text("Existing account").tag(false)
                Text("New account").tag(true)
            }.pickerStyle(.segmented)
            if createsAccount {
                TextField("Account name", text: $name).textFieldStyle(.roundedBorder)
                TextField("Account email", text: $email).textFieldStyle(.roundedBorder)
            } else {
                Picker("Account", selection: Binding(get: { target?.id ?? "" }, set: { targetID = $0 })) {
                    ForEach(store.visibleAccounts) { account in
                        Text("\(account.badge) · \(account.name)").tag(account.id)
                    }
                }
                if duplicate { Text("This provider is already connected to this account.").font(.caption) }
            }
            HStack {
                Button("Connect & sign in…", action: connect)
                    .disabled(duplicate || (createsAccount && email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) ||
                              (!createsAccount && target == nil) || codex.refreshing || codex.authenticatingID != nil)
                Button("Cancel") { isAdding = false; email = ""; name = "" }
            }
        }
    }

    private func connect() {
        let account: FleetAccount
        if createsAccount {
            let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
            account = store.add(name: name.isEmpty ? trimmed : name, email: trimmed)
        } else if let target { account = target }
        else { return }
        guard account.connection(for: providerID) == nil else { return }
        store.attachGlobal(providerID, to: account.id)
        selectedID = account.id
        if providerID == "codex" { codex.signIn(codex.ensureProfile(for: account)) }
        else { store.signInGlobally(providerID) }
        isAdding = false
        email = ""; name = ""
        service.refresh()
    }

    private func consumeAddRequest() {
        guard let requested = navigation.addingProviderID else { return }
        providerID = requested
        targetID = selected?.id ?? ""
        createsAccount = store.visibleAccounts.isEmpty
        isAdding = true
        navigation.addingProviderID = nil
    }
}

private struct AccountEditor: View {
    let account: FleetAccount
    @ObservedObject private var store = AccountStore.shared
    @ObservedObject private var codex = CodexMonitoringStore.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var service = StatusService.shared
    @State private var name: String
    @State private var email: String

    init(account: FleetAccount) {
        self.account = account
        _name = State(initialValue: account.name)
        _email = State(initialValue: account.email)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(account.badge).font(.title2)
                TextField("Account name", text: $name).textFieldStyle(.roundedBorder)
                Button("Save") { store.update(account.id, name: name, email: email) }
                    .disabled(name == account.name && email == account.email)
            }
            TextField("Account email", text: $email).textFieldStyle(.roundedBorder)
            ForEach(account.connections.filter { settings.isEnabled($0.providerID) }) { connection in
                let status = connection.providerID == "codex" ? codex.status(for: account, global: service.codex, accounts: store.visibleAccounts)
                    : service.status(for: connection)
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("\(ProviderCatalog.definition(for: connection.providerID)?.name ?? connection.providerID) (\(account.badge))").bold()
                        Spacer()
                        Text(status?.detail ?? "Checking…").font(.caption).foregroundColor(.secondary)
                    }
                    HStack {
                        Button("Sign in…") {
                            if connection.providerID == "codex" { codex.signIn(codex.ensureProfile(for: account)) }
                            else { store.signInGlobally(connection.providerID) }
                        }
                        if connection.providerID == "codex" {
                            if let profile = codex.profile(for: account), status?.authentication == .signedIn {
                                Button("Sign out", role: .destructive) { codex.signOut(profile) }
                            }
                        } else if status?.authentication == .signedIn {
                            Button("Sign out", role: .destructive) { Task { await service.signOutGlobally(connection.providerID) } }
                        }
                    }
                    .disabled(codex.authenticatingID != nil || service.signingOutProvider != nil ||
                              (connection.providerID == "codex" && codex.refreshing))
                }
                Divider()
            }
            Button("Remove account") {
                guard !codex.refreshing, codex.authenticatingID == nil else { return }
                codex.forgetAccount(account)
                store.remove(account.id)
                service.refresh()
            }
            .disabled(codex.refreshing || codex.authenticatingID != nil)
            .help("Forget account metadata; preserve credentials and session history.")
        }.font(.callout)
    }
}

struct CodexAccountAuthenticationStatus: View {
    @ObservedObject var store: CodexMonitoringStore
    @ObservedObject var accounts: AccountStore
    var body: some View {
        if let id = store.authenticatingID {
            let accountID = store.profiles.first { $0.id == id }?.accountID
            let badge = accounts.accounts.first { $0.id == accountID }?.badge ?? ""
            HStack {
                ProgressView().controlSize(.small)
                Text("Complete Codex (\(badge)) sign-in in your browser…").font(.caption)
                Button("Cancel") { store.cancelAuthentication() }.font(.caption)
            }
        }
        if let error = store.error { Text(error).font(.caption).foregroundColor(.red) }
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
