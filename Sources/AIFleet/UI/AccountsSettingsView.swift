import AppKit
import SwiftUI

struct AccountsSettingsView: View {
    @ObservedObject private var store = AccountStore.shared
    @ObservedObject private var codex = CodexMonitoringStore.shared
    @ObservedObject private var launch = ProviderLaunchStore.shared
    @ObservedObject private var service = StatusService.shared
    @ObservedObject private var navigation = SettingsNavigation.shared
    @State private var adding = false
    @State private var loginGuide: String?
    @State private var accountName = ""
    @State private var accountEmail = ""
    @State private var removal: AccountRemoval?

    private var busy: Bool { launch.busy || codex.refreshing || codex.authenticatingID != nil }

    private struct AccountRemoval: Identifiable {
        let account: FleetAccount
        let providerID: String?
        var id: String { account.id + (providerID ?? "") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button("Add account") { adding.toggle() }
                Spacer()
                Button("Refresh terminal logins") { service.refresh(); codex.refresh(force: true) }
            }
            Text("Terminal logins with a verified email appear under the matching account after refresh. A different email creates a separate account.")
                .font(FleetUI.caption).foregroundStyle(.secondary)
            if let requested = navigation.addingProviderID {
                Text("To connect \(ProviderCatalog.definition(for: requested)?.name ?? requested), use Add provider under the matching account, or Add account first.")
                    .font(FleetUI.caption).foregroundStyle(.secondary)
            }
            if let loginGuide {
                Text(loginGuide).font(FleetUI.caption).foregroundStyle(.secondary)
            }
            if adding {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Account name", text: $accountName).textFieldStyle(.roundedBorder)
                    TextField("Email used to sign in", text: $accountEmail).textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Add") {
                            _ = store.add(name: accountName, email: accountEmail.trimmingCharacters(in: .whitespacesAndNewlines))
                            adding = false; accountName = ""; accountEmail = ""
                        }.disabled(!accountEmail.contains("@") || store.visibleAccounts.contains {
                            $0.email.caseInsensitiveCompare(accountEmail.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
                        })
                        Button("Cancel") { adding = false }
                    }
                }
            }
            ForEach(store.visibleAccounts) { account in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(account.name) (\(account.badge))").font(FleetUI.title)
                        Spacer()
                        Menu("Add provider") {
                            ForEach(ProviderCatalog.all.filter { account.connection(for: $0.id) == nil }.sorted { $0.name < $1.name }) { provider in
                                Button(provider.name) { connect(provider.id, to: account) }
                            }
                        }.fixedSize().disabled(busy)
                        Button { removal = AccountRemoval(account: account, providerID: nil) } label: {
                            Image(systemName: "trash")
                        }.buttonStyle(.plain).disabled(busy).accessibilityLabel("Remove \(account.name) from AI Fleet")
                    }
                    Text(account.email).font(FleetUI.caption).foregroundStyle(.secondary)
                    Divider()
                    if account.connections.isEmpty {
                        Text("No providers yet. Choose Add provider, then sign in with this email.")
                            .font(FleetUI.caption).foregroundStyle(.secondary)
                    }
                    ForEach(account.connections.sorted { $0.providerID < $1.providerID }) { connection in
                        connector(connection, account: account)
                    }
                }.padding(12).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            }
            DisclosureGroup("Connecting a terminal login") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("1. Sign in with the provider in your terminal, or add it under the account above.")
                    Text("2. Refresh terminal logins. AI Fleet checks the provider's actual email.")
                    Text("3. Switch is available only when that email matches the account.")
                    Text("If the provider cannot report its identity, the connection stays unverified. It is never assigned using a typed email alone.")
                    Text("Only default terminal homes import automatically. For a separate home, use Add provider. AI Fleet Switch preserves running sessions; native terminal login changes that home's credentials.")
                }.font(FleetUI.caption).foregroundStyle(.secondary)
            }
            nativeLogins
            CodexAccountAuthenticationStatus(store: codex, accounts: store)
            if let error = store.launchError { Text(error).font(FleetUI.caption).foregroundStyle(.secondary) }
        }
        .onAppear { codex.synchronizeAccounts(store) }
        .alert(item: $removal) { item in
            Alert(title: Text(item.providerID == nil ? "Remove account from AI Fleet?" : "Remove provider from this account?"),
                  message: Text("This removes the saved association and default selection. Credentials, history and running sessions are preserved. You can import the terminal login again."),
                  primaryButton: .destructive(Text("Remove")) { remove(item) }, secondaryButton: .cancel())
        }
    }

    private func connector(_ connection: ProviderConnection, account: FleetAccount) -> some View {
        let status = connection.providerID == "codex" ? codex.status(for: account, global: service.codex, accounts: store.visibleAccounts)
            : service.status(for: connection)
        let match = AccountIdentityMatch.assess(expected: account.email, observed: status?.account?.email)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(ProviderCatalog.definition(for: connection.providerID)?.name ?? connection.providerID)
                Spacer()
                Text(status?.authentication == .signedIn && match == .verified ? "Connected" : "Not verified")
                    .font(FleetUI.caption).foregroundStyle(.secondary)
                Button { removal = AccountRemoval(account: account, providerID: connection.providerID) } label: {
                    Image(systemName: "minus.circle")
                }.buttonStyle(.plain).disabled(busy).accessibilityLabel("Remove \(connection.providerID) from \(account.name)")
            }
            if connection.providerID == "qwen" {
                Text("Email verification is unavailable for Qwen in this build. This connection cannot be confirmed; removing it clears named routing while preserving credentials.")
                    .font(FleetUI.caption).foregroundStyle(.secondary)
            } else if match == .different {
                Text("Signed in as \(status?.account?.email ?? "—"). Expected \(account.email). Sign in again with the correct email.")
                    .font(FleetUI.caption).foregroundStyle(.secondary)
            } else if match == .unavailable {
                Text("The provider has not confirmed this account's email. Switch is unavailable until verified.")
                    .font(FleetUI.caption).foregroundStyle(.secondary)
            }
            HStack {
                AccountConnectionActions(account: account, connection: connection, status: status,
                    isCurrentCLI: service.globalAccountIDs[connection.providerID] == account.id)
            }.buttonStyle(.bordered).controlSize(.small)
            if launch.messageAccountID == account.id, launch.messageProviderID == connection.providerID, let message = launch.message {
                Text(message).font(FleetUI.caption).foregroundStyle(.secondary)
                if launch.busy && connection.providerID == "kimi" {
                    Button("Cancel sign-in") { launch.cancelSignIn() }.controlSize(.small)
                }
            }
        }.padding(.vertical, 5)
    }

    private var nativeLogins: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(ProviderCatalog.all.sorted { $0.name < $1.name }) { provider in
                let status = service.status(for: provider.id)
                if status.authentication == .signedIn,
                   !store.visibleAccounts.contains(where: { account in
                       account.connection(for: provider.id) != nil && AccountIdentityMatch.assess(expected: account.email, observed: status.account?.email) == .verified
                   }) {
                    HStack {
                        Text("\(provider.name) · \(status.account?.email ?? "Identity unavailable")").font(FleetUI.caption)
                        Spacer()
                        Button("Import login") { store.importNative(status); service.refresh() }
                            .disabled(status.account?.email?.isEmpty != false)
                    }
                }
            }
        }
    }

    private func connect(_ providerID: String, to account: FleetAccount) {
        if providerID == "qwen" {
            loginGuide = "Qwen is visible in the menu, but this build cannot verify the email behind its configured provider credentials. Named-account connection and Switch are unavailable rather than guessed. Qwen can still be configured in its own CLI."
            return
        }
        if providerID == "gemini" {
            let installation = ProviderCatalog.isInstalled(providerID) ? "" : "Install the \(providerID) CLI first. "
            loginGuide = installation + "Open \(providerID) in your terminal and sign in as \(account.email), then click Refresh terminal logins. A confirmed email is imported under this account. If identity cannot be verified, no account binding is created."
            return
        }
        loginGuide = nil
        store.attach(providerID, to: account.id)
        guard let updated = store.accounts.first(where: { $0.id == account.id }) else { return }
        if providerID == "codex" { codex.signIn(codex.ensureProfile(for: updated)) }
        else { launch.signIn(updated, providerID: providerID) }
    }

    private func remove(_ item: AccountRemoval) {
        guard !launch.busy, !codex.refreshing, codex.authenticatingID == nil else { return }
        if let providerID = item.providerID {
            if providerID == "codex", let profile = codex.profile(for: item.account) { codex.remove(profile) }
            else { do { try launch.forget(item.account.id, providerID: providerID) } catch { return } }
            store.detach(providerID, from: item.account.id)
        } else {
            guard codex.forgetAccount(item.account) else { return }
            do { try launch.forget(item.account.id) } catch { return }
            store.remove(item.account.id)
        }
        service.refresh()
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
