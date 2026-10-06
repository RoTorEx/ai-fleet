import AppKit
import SwiftUI

struct AccountsSettingsView: View {
    @ObservedObject private var store = AccountStore.shared
    @ObservedObject private var service = StatusService.shared
    @State private var selectedID = FleetAccount.defaultID

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("One badge can connect accounts from several providers.")
                .font(.callout).foregroundColor(.secondary)
            HStack {
                Picker("Account", selection: $selectedID) {
                    ForEach(store.accounts) { account in
                        Text("\(account.badge) · \(account.name)").tag(account.id)
                    }
                }
                Button {
                    selectedID = store.add().id
                } label: { Image(systemName: "plus") }
                .help("Add account")
                .accessibilityLabel("Add account")
            }
            if let account = store.accounts.first(where: { $0.id == selectedID }) {
                AccountEditor(account: account).id(account.id)
            }
            if let error = store.launchError {
                Text(error).font(.caption).foregroundColor(.red)
            }
            Text("Badges select quota and future sessions opened from AI Fleet. Existing sessions and ordinary CLI commands keep their login.")
                .font(.caption).foregroundColor(.secondary)
            Spacer(minLength: 0)
        }
        .onChange(of: store.accounts.map(\.id)) { ids in
            if !ids.contains(selectedID) { selectedID = FleetAccount.defaultID }
        }
        .onAppear { service.refresh() }
    }
}

private struct AccountEditor: View {
    let account: FleetAccount
    @ObservedObject private var store = AccountStore.shared
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
                Text(account.badge).font(.title2).frame(width: 28)
                TextField("Account name", text: $name).textFieldStyle(.roundedBorder).onSubmit(save)
                Button("Save", action: save).disabled(name == account.name && email == account.email)
            }
            TextField("Email / label (optional)", text: $email).textFieldStyle(.roundedBorder).onSubmit(save)
                .help("A label shared across providers. Hover a badge to see the actual provider login and plan when available.")
            Divider()
            ForEach(ProviderCatalog.all) { provider in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Toggle(provider.name, isOn: Binding(
                            get: { account.connection(for: provider.id) != nil },
                            set: { enabled in
                                if enabled { store.attach(provider.id, to: account.id) }
                                else { store.detach(provider.id, from: account.id) }
                                service.refresh()
                            }
                        ))
                        .disabled(account.connection(for: provider.id)?.configDirectory == nil && account.connection(for: provider.id) != nil)
                        Spacer()
                        if let connection = account.connection(for: provider.id) {
                            Text(service.status(for: connection)?.detail ?? "Checking…")
                                .font(.caption).foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    if let connection = account.connection(for: provider.id) {
                        connectionActions(connection, provider: provider)
                        if let notice = service.status(for: connection)?.quotaNotice {
                            Text(notice).font(.caption).foregroundColor(.orange)
                        }
                    } else {
                        HStack {
                            Menu("Link existing") {
                                ForEach(store.linkedAccounts(for: provider.id)) { owner in
                                    Button("\(owner.badge) · \(owner.name)") {
                                        if let connection = owner.connection(for: provider.id) { store.move(connection, to: account.id) }
                                        service.refresh()
                                    }
                                }
                            }
                            Button("Import folder…") { importFolder(provider) }
                        }.font(.caption)
                    }
                }
            }
            Divider()
            if account.id != FleetAccount.defaultID {
                Button("Remove account") {
                    store.remove(account.id)
                    service.refresh()
                }
                .help("Forget this account in AI Fleet; keep provider logins and session files.")
            }
        }
        .font(.callout)
    }

    private func connectionActions(_ connection: ProviderConnection, provider: ProviderDefinition) -> some View {
        HStack(spacing: 8) {
            Button("Sign in…") { store.open(connection, account: account, login: true) }
            Button("Open…") { store.open(connection, account: account) }
            if store.selections[provider.id] == account.id {
                Text("Selected").foregroundColor(.secondary)
            } else {
                Button("Use") { store.select(account.id, for: provider.id); service.refresh() }
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .disabled(!ProviderCatalog.isInstalled(provider))
        .help(account.tooltip(for: connection, status: service.status(for: connection)))
    }
    private func save() { store.update(account.id, name: name, email: email) }
    private func importFolder(_ provider: ProviderDefinition) {
        let panel = NSOpenPanel()
        panel.title = "Import \(provider.name) configuration folder"
        panel.prompt = "Link"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.attach(provider.id, to: account.id, configDirectory: url.path)
        service.refresh()
    }
}
