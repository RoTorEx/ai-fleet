import AppKit
import Combine
import Foundation
import CryptoKit

struct ProviderAccountIdentity: Equatable {
    let email: String?
    let organizationID: String?
    let organizationName: String?
    let subscriptionType: String?

    var planLabel: String? {
        guard let type = subscriptionType, !type.isEmpty else { return nil }
        switch type.lowercased() {
        case "plus": return "Plus"
        case "business": return "Business"
        case "pro": return "Pro"
        case "max": return "Max"
        case "team": return "Team"
        case "enterprise": return "Enterprise"
        case "free": return "Free"
        default: return type
        }
    }

    var caption: String {
        [email, organizationName, planLabel].compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }.joined(separator: " · ")
    }

    var scope: String? {
        guard let email, !email.isEmpty, let organizationID, !organizationID.isEmpty else { return nil }
        let digest = SHA256.hash(data: Data((email.lowercased() + "\n" + organizationID).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

struct ProviderConnection: Codable, Identifiable, Equatable {
    let id: String
    let providerID: String
    var configDirectory: String?
    // Metadata association only; never an independent credential store.
    var globalAssociation: Bool? = nil
    var verifiedIdentity: ConnectionIdentity? = nil

    var isNativeDefault: Bool { configDirectory == nil && globalAssociation != true }
    var statusID: String { isNativeDefault ? providerID : "\(providerID):\(id)" }
    static func global(_ providerID: String) -> ProviderConnection {
        ProviderConnection(id: providerID, providerID: providerID, configDirectory: nil)
    }
    var claudeProfile: ClaudeProfile {
        ClaudeProfile(id: configDirectory == nil ? ClaudeProfile.defaultID : id,
                      name: "Claude", configDirectory: configDirectory)
    }
    var selector: String {
        switch providerID {
        case "claude": return "CLAUDE_CONFIG_DIR"
        case "codex": return "CODEX_HOME"
        case "kimi": return "KIMI_CODE_HOME"
        case "qwen": return "QWEN_HOME"
        case "gemini": return "GEMINI_CLI_HOME"
        case "grok": return "GROK_HOME"
        default: return ""
        }
    }
    var overrideKeys: [String] {
        switch providerID {
        case "claude": return ClaudeProfile.authOverrideKeys
        case "codex": return [selector, "CODEX_SQLITE_HOME", "OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN"]
        case "kimi": return [selector, "KIMI_SHARE_DIR", "KIMI_API_KEY", "KIMI_BASE_URL", "KIMI_MODEL_NAME"]
        case "qwen": return [selector, "QWEN_RUNTIME_DIR", "QWEN_API_KEY", "OPENAI_API_KEY", "OPENAI_BASE_URL"]
        case "grok": return [selector, "XAI_API_KEY"]
        case "gemini": return [selector, "GEMINI_API_KEY", "GOOGLE_API_KEY", "GOOGLE_GENAI_USE_VERTEXAI",
                               "GOOGLE_APPLICATION_CREDENTIALS", "GOOGLE_GENAI_USE_GCA", "GEMINI_DEFAULT_AUTH_TYPE"]
        default: return []
        }
    }
    func credentialURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let directory = configDirectory.map { URL(fileURLWithPath: $0) }
        switch providerID {
        case "codex": return (directory ?? home.appendingPathComponent(".codex")).appendingPathComponent("auth.json")
        case "kimi":
            let root = directory ?? home.appendingPathComponent(".kimi-code")
            return root.appendingPathComponent(KimiCodeEnvironment(root: root).credentialFile)
        case "qwen": return (directory ?? home.appendingPathComponent(".qwen")).appendingPathComponent("oauth_creds.json")
        case "grok": return (directory ?? home.appendingPathComponent(".grok")).appendingPathComponent("auth.json")
        default: return nil
        }
    }
    func status(from source: ProviderStatus) -> ProviderStatus {
        ProviderStatus(id: statusID, name: ProviderCatalog.definition(for: providerID)?.name ?? providerID,
                       state: source.state, detail: source.detail, lastUpdated: source.lastUpdated,
                       remainingPercent: source.remainingPercent, windowLabel: source.windowLabel,
                       resetAt: source.resetAt, limitWindows: source.limitWindows, providerID: providerID,
                       account: source.account,
                       notificationScope: "\(statusID).\(source.account?.scope ?? "unidentified")",
                       quotaNotice: source.quotaNotice, authentication: source.authentication, quotaState: source.quotaState, quotaFailure: source.quotaFailure)
    }
}

struct FleetAccount: Codable, Identifiable, Equatable {
    let id: String
    /// Position among labeled accounts: α is first. Reordering and removal renumber it.
    fileprivate(set) var badgeIndex: Int
    var name: String
    var email: String
    var connections: [ProviderConnection]

    init(id: String, badgeIndex: Int, name: String, email: String, connections: [ProviderConnection]) {
        self.id = id; self.badgeIndex = badgeIndex; self.name = name; self.email = email; self.connections = connections
    }

    static let defaultID = "default"
    static let current = FleetAccount(id: defaultID, badgeIndex: -1, name: "Default", email: "",
        connections: ProviderCatalog.all.map { ProviderConnection(id: $0.id, providerID: $0.id, configDirectory: nil) })
    var badge: String {
        guard badgeIndex >= 0 else { return "" }
        let alphabet = Array("αβγδεζηθικλμνξοπρστυφχψω").map(String.init)
        return badgeIndex < alphabet.count ? alphabet[max(0, badgeIndex)] : "α\(badgeIndex + 1)"
    }
    func connection(for providerID: String) -> ProviderConnection? {
        connections.first { $0.providerID == providerID }
    }
    func tooltip(for connection: ProviderConnection, status: ProviderStatus?) -> String {
        let providerEmail = status?.account?.email?.trimmingCharacters(in: .whitespacesAndNewlines)
        return [providerEmail.flatMap { $0.isEmpty ? nil : $0 } ?? email, status?.account?.planLabel ?? ""]
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

@MainActor
final class AccountStore: ObservableObject {
    static let shared = AccountStore()
    @Published private(set) var accounts: [FleetAccount]
    @Published private(set) var selections: [String: String]
    @Published var launchError: String?
    @Published private(set) var launchProviderID: String?
    @Published private(set) var launchAccountID: String?
    @Published private(set) var codexSigningIn = false
    @Published private(set) var signingInProviderID: String?
    private var codexLoginOperation: CodexAuthenticationOperation?

    func cancelCodexSignIn() { codexLoginOperation?.cancel() }
    private let defaults: UserDefaults
    private let home: URL
    private var nextBadge: Int
    private var dismissedImports: Set<String> {
        get { Set(defaults.stringArray(forKey: "accounts.dismissedImports") ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: "accounts.dismissedImports") }
    }
    private func importKey(_ provider: String, _ email: String) -> String {
        provider + ":" + ConnectionIdentity.normalize(email)
    }
    private func suppressImport(_ provider: String, email: String) {
        guard ["codex", "claude"].contains(provider) else { return }
        var keys = dismissedImports; keys.insert(importKey(provider, email)); dismissedImports = keys
    }
    func importNative(_ status: ProviderStatus) {
        guard let identity = ConnectionIdentity(status: status) else { return }
        var keys = dismissedImports; keys.remove(importKey(status.providerID, identity.email)); dismissedImports = keys
        _ = globalAccount(for: status)
    }

    init(defaults: UserDefaults = .standard, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.defaults = defaults
        home = homeDirectory
        var loaded = defaults.data(forKey: "fleet.accounts")
            .flatMap { try? JSONDecoder().decode([FleetAccount].self, from: $0) }
        if loaded == nil {
            var migrated = [FleetAccount.current]
            let legacy = defaults.data(forKey: "claude.profiles")
                .flatMap { try? JSONDecoder().decode([ClaudeProfile].self, from: $0) } ?? []
            for profile in legacy where profile.id != ClaudeProfile.defaultID && profile.configDirectory?.hasPrefix("/") == true {
                migrated.append(FleetAccount(id: profile.id, badgeIndex: migrated.count, name: profile.name, email: "",
                    connections: [ProviderConnection(id: profile.id, providerID: "claude", configDirectory: profile.configDirectory)]))
            }
            loaded = migrated
        }
        var ids = Set<String>()
        var connectionIDs = Set<String>()
        var values = (loaded ?? []).filter { ids.insert($0.id).inserted }
        for index in values.indices {
            var providers = Set<String>()
            values[index].connections = values[index].connections.filter {
                ProviderCatalog.definition(for: $0.providerID) != nil && providers.insert($0.providerID).inserted
                    && ($0.configDirectory == nil || $0.configDirectory?.hasPrefix("/") == true)
                    && connectionIDs.insert($0.statusID).inserted
            }
        }
        // The internal fallback is storage metadata, not a user account or a Greek badge.
        if let index = values.firstIndex(where: { $0.id == FleetAccount.defaultID && $0.email.isEmpty }) {
            let account = values[index]
            values[index] = FleetAccount(id: account.id, badgeIndex: -1, name: account.name,
                                         email: account.email, connections: account.connections)
        }
        // Preserve one default connection per provider, even after damaged preferences.
        if !values.contains(where: { $0.id == FleetAccount.defaultID }) { values.insert(FleetAccount(id: "default", badgeIndex: -1, name: "Default", email: "", connections: []), at: 0) }
        let defaultIndex = values.firstIndex { $0.id == FleetAccount.defaultID }!
        for provider in ProviderCatalog.all where !values.contains(where: { $0.connections.contains { $0.providerID == provider.id && $0.isNativeDefault } }) {
            values[defaultIndex].connections.append(ProviderConnection(id: provider.id, providerID: provider.id, configDirectory: nil))
        }
        accounts = values
        let storedSelections = defaults.dictionary(forKey: "fleet.selections") as? [String: String] ?? [:]
        var selected: [String: String] = [:]
        for provider in ProviderCatalog.all {
            let legacy = provider.id == "claude" ? defaults.string(forKey: "claude.selectedProfile") : nil
            let candidate = storedSelections[provider.id] ?? legacy
            selected[provider.id] = values.first { $0.id == candidate && $0.connection(for: provider.id) != nil }?.id
                ?? values.first { $0.connection(for: provider.id) != nil }?.id
        }
        selections = selected
        nextBadge = 0
        renumber()
    }

    var visibleAccounts: [FleetAccount] {
        accounts.filter { $0.id != FleetAccount.defaultID || !$0.email.isEmpty }
            .sorted { $0.badgeIndex < $1.badgeIndex }
    }

    func linkedAccounts(for providerID: String) -> [FleetAccount] {
        accounts.filter { $0.connection(for: providerID) != nil }
    }
    func selected(for providerID: String) -> FleetAccount? {
        linkedAccounts(for: providerID).first { $0.id == selections[providerID] } ?? linkedAccounts(for: providerID).first
    }
    @discardableResult func add(name: String = "", email: String = "") -> FleetAccount {
        let account = FleetAccount(id: UUID().uuidString, badgeIndex: nextBadge,
                                  name: name.isEmpty ? "Account \(nextBadge + 1)" : name, email: email, connections: [])
        nextBadge += 1
        accounts.append(account)
        save()
        return account
    }
    /// Applies a new order of `visibleAccounts`; Greek letters follow the order, starting at α.
    func reorder(_ ids: [String]) {
        let order = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        for index in accounts.indices where accounts[index].badgeIndex >= 0 {
            accounts[index].badgeIndex = order[accounts[index].id] ?? ids.count + accounts[index].badgeIndex
        }
        renumber()
        save()
    }
    func moveAccounts(from source: IndexSet, to destination: Int) {
        var ids = visibleAccounts.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        reorder(ids)
    }
    func update(_ id: String, name: String, email: String) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let updatedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard accounts[index].email.isEmpty || accounts[index].connections.isEmpty || ConnectionIdentity.normalize(updatedEmail) == ConnectionIdentity.normalize(accounts[index].email) else {
            launchError = "Disconnect providers before changing this account's email. Existing logins were preserved."
            return
        }
        accounts[index].email = updatedEmail
        if accounts[index].badgeIndex < 0, !accounts[index].email.isEmpty {
            let account = accounts[index]
            accounts[index] = FleetAccount(id: account.id, badgeIndex: nextBadge, name: account.name,
                                           email: account.email, connections: account.connections)
            nextBadge += 1
        }
        renumber()
        save()
    }
    @discardableResult
    func confirmIdentity(_ identity: ConnectionIdentity, provider: String, accountID: String) -> Bool {
        guard !identity.email.isEmpty, let index = accounts.firstIndex(where: { $0.id == accountID }),
              let connection = accounts[index].connections.firstIndex(where: { $0.providerID == provider }),
              accounts[index].email.isEmpty || ConnectionIdentity.normalize(accounts[index].email) == identity.email,
              accounts[index].connections[connection].verifiedIdentity.map({ $0.matches(identity) }) != false else { return false }
        accounts[index].email = identity.email
        accounts[index].connections[connection].verifiedIdentity = identity
        save()
        return true
    }

    func select(_ accountID: String, for providerID: String) {
        guard accounts.contains(where: { $0.id == accountID && $0.connection(for: providerID) != nil }) else { return }
        selections[providerID] = accountID
        save()
    }
    func attach(_ providerID: String, to accountID: String, configDirectory: String? = nil) {
        guard let index = accounts.firstIndex(where: { $0.id == accountID }),
              ProviderCatalog.definition(for: providerID) != nil,
              accounts[index].connection(for: providerID) == nil else { return }
        let id = UUID().uuidString
        let path = configDirectory ?? home.appendingPathComponent("Library/Application Support/AI Fleet/Accounts")
            .appendingPathComponent(accountID).appendingPathComponent(providerID).path
        guard path.hasPrefix("/"), !accounts.contains(where: { $0.connections.contains { $0.providerID == providerID && $0.configDirectory == path } }) else { return }
        accounts[index].connections.append(ProviderConnection(id: id, providerID: providerID, configDirectory: path))
        save()
    }
    func attachGlobal(_ providerID: String, to accountID: String) {
        guard ProviderCatalog.definition(for: providerID) != nil,
              let index = accounts.firstIndex(where: { $0.id == accountID }),
              accounts[index].connection(for: providerID) == nil else { return }
        accounts[index].connections.append(ProviderConnection(id: UUID().uuidString, providerID: providerID,
                                                              configDirectory: nil, globalAssociation: true))
        save()
    }

    // Observed native identity, not a requested target or a stored manual selection.
    // Duplicate email labels are ambiguous; do not attribute quota to either badge.
    func globalAccount(for status: ProviderStatus) -> String? {
        if ["codex", "claude"].contains(status.providerID) {
            guard let identity = ConnectionIdentity(status: status),
                  !dismissedImports.contains(importKey(status.providerID, identity.email)) else { return nil }
            let matches = accounts.filter { ConnectionIdentity.normalize($0.email) == identity.email }
            guard matches.count <= 1 else { return nil }
            let account = matches.first ?? add(name: identity.email, email: identity.email)
            if let existing = account.connection(for: status.providerID)?.verifiedIdentity,
               !existing.matches(identity) { return nil }
            attachGlobal(status.providerID, to: account.id)
            if let index = accounts.firstIndex(where: { $0.id == account.id }),
               let connection = accounts[index].connections.firstIndex(where: { $0.providerID == status.providerID }) {
                accounts[index].connections[connection].verifiedIdentity = identity
                save()
            }
            return account.id
        }
        let email = status.account?.email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if email.isEmpty {
            return accounts.first { $0.connection(for: status.providerID)?.isNativeDefault == true }?.id
        }
        let matches = accounts.filter { $0.email.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(email) == .orderedSame }
        guard matches.count <= 1 else { return nil }
        if let match = matches.first {
            attachGlobal(status.providerID, to: match.id)
            return match.id
        }
        guard status.authentication == .signedIn else { return nil }
        let discovered = add(name: email, email: email)
        attachGlobal(status.providerID, to: discovered.id)
        return discovered.id
    }

    func signInGlobally(_ providerID: String, accountID: String? = nil) {
        guard !SwitchCoordinator.shared.active.contains(providerID), StatusService.shared.signingOutProvider == nil, !codexSigningIn else { return }
        if let accountID, let account = accounts.first(where: { $0.id == accountID }) {
            if providerID == "codex" { CodexMonitoringStore.shared.signIn(CodexMonitoringStore.shared.ensureProfile(for: account)); return }
            if providerID == "claude" { ProviderLaunchStore.shared.signIn(account, providerID: providerID); return }
        }
        launchProviderID = providerID
        launchAccountID = accountID
        guard let provider = ProviderCatalog.definition(for: providerID),
              let executable = ProviderCatalog.executableURL(for: provider) else {
            launchError = "Provider CLI is not installed."
            return
        }
        launchError = nil
        if providerID == "codex" {
            startCodexSignIn(executable: executable)
            return
        }
        guard signingInProviderID == nil else { return }
        guard ["claude", "kimi", "grok"].contains(providerID) else {
            launchError = "Complete login in the provider CLI, then refresh AI Fleet. No terminal was opened."
            return
        }
        signingInProviderID = providerID
        Task {
            let arguments = ProviderCatalog.loginArguments(for: providerID)
            let environment = providerID == "claude" ? ClaudeProfile.current.environment() : ProcessInfo.processInfo.environment
            let result = await Task.detached(priority: .userInitiated) {
                LocalCommandReader.read(executableURL: executable, arguments: arguments, timeout: 600, environment: environment)
            }.value
            self.signingInProviderID = nil
            self.launchError = result?.exitCode == 0 ? nil : "Login did not complete. Check the provider's browser login."
            StatusService.shared.refresh()
        }
    }

    func startCodexSignIn(executable: URL,
                          inventory: @escaping @Sendable () throws -> [Int32] = { try CodexProcessInventory().runningPIDs() }) {
        guard !SwitchCoordinator.shared.active.contains("codex"), !codexSigningIn, StatusService.shared.signingOutProvider == nil else { return }
        launchProviderID = "codex"
        launchError = nil
        let operation = CodexAuthenticationOperation()
        codexLoginOperation = operation
        codexSigningIn = true
        Task { [self] in
            let error = await Task.detached(priority: .userInitiated) { () -> String? in
                do { try operation.run(.login, executable: executable, inventory: inventory); return nil }
                catch { return error.localizedDescription }
            }.value
            codexLoginOperation = nil
            codexSigningIn = false
            launchError = error
            // Verify native success; a failed attempt must not claim a new identity.
            if error == nil { StatusService.shared.refresh() }
        }
    }

    func detach(_ providerID: String, from accountID: String) {
        guard let index = accounts.firstIndex(where: { $0.id == accountID }),
              accounts[index].connection(for: providerID).map({ !$0.isNativeDefault || ["codex", "claude"].contains(providerID) }) == true else { return }
        guard !SwitchCoordinator.shared.active.contains(providerID) else { return }
        suppressImport(providerID, email: accounts[index].email)
        accounts[index].connections.removeAll { $0.providerID == providerID }
        repairSelection(providerID)
        save()
    }
    func move(_ connection: ProviderConnection, to accountID: String) {
        guard let target = accounts.firstIndex(where: { $0.id == accountID }), accounts[target].connection(for: connection.providerID) == nil else { return }
        let wasSelected = selected(for: connection.providerID)?.connection(for: connection.providerID)?.id == connection.id
        for index in accounts.indices { accounts[index].connections.removeAll { $0.id == connection.id } }
        accounts[target].connections.append(connection)
        if wasSelected { selections[connection.providerID] = accountID }
        repairSelection(connection.providerID)
        save()
    }
    func remove(_ id: String) {
        guard let account = accounts.first(where: { $0.id == id }) else { return }
        if id == FleetAccount.defaultID {
            guard !account.email.isEmpty, let index = accounts.firstIndex(where: { $0.id == id }) else { return }
            for connection in account.connections { suppressImport(connection.providerID, email: account.email) }
            accounts[index] = FleetAccount(id: FleetAccount.defaultID, badgeIndex: -1, name: "Default", email: "",
                connections: account.connections.filter { $0.isNativeDefault })
            for provider in ProviderCatalog.all { repairSelection(provider.id) }
            renumber()
            save()
            return
        }
        for connection in account.connections { suppressImport(connection.providerID, email: account.email) }
        let defaultsToKeep = account.connections.filter { $0.isNativeDefault }
        accounts.removeAll { $0.id == id }
        for connection in defaultsToKeep {
            if let index = accounts.firstIndex(where: { $0.id == FleetAccount.defaultID && $0.connection(for: connection.providerID) == nil }) {
                accounts[index].connections.append(connection)
            } else {
                let recovered = add(name: "Default " + (ProviderCatalog.definition(for: connection.providerID)?.name ?? connection.providerID))
                accounts[accounts.firstIndex { $0.id == recovered.id }!].connections.append(connection)
            }
        }
        for provider in ProviderCatalog.all { repairSelection(provider.id) }
        renumber()
        save()
    }
    /// Closes gaps so labeled accounts read α, β, γ… in their current order.
    private func renumber() {
        let ordered = accounts.indices.filter { accounts[$0].badgeIndex >= 0 }
            .sorted { accounts[$0].badgeIndex < accounts[$1].badgeIndex }
        for (position, index) in ordered.enumerated() { accounts[index].badgeIndex = position }
        nextBadge = ordered.count
    }
    private func repairSelection(_ providerID: String) {
        selections[providerID] = selected(for: providerID)?.id
    }
    private func save() {
        defaults.set(try? JSONEncoder().encode(accounts), forKey: "fleet.accounts")
        defaults.set(selections, forKey: "fleet.selections")
        defaults.set(nextBadge, forKey: "fleet.nextBadge")
    }
}

enum AccountLaunch {
    static func command(connection: ProviderConnection, executable: URL, directory: URL, login: Bool, hasGeminiLogin: Bool = false) -> String {
        let quote = ClaudeProfileLaunch.shellQuote
        let unset = connection.overrideKeys.map { "-u " + quote($0) }.joined(separator: " ")
        let selector = connection.configDirectory.map { " " + quote(connection.selector + "=" + $0) } ?? ""
        let arguments: String
        switch (connection.providerID, login) {
        case ("gemini", true):
            // First run already opens native auth. Reopen its dialog only for an existing login.
            arguments = hasGeminiLogin ? " --prompt-interactive '/auth login'" : ""
        case ("claude", true), ("codex", true), ("kimi", true), ("grok", true):
            arguments = " " + ProviderCatalog.loginArguments(for: connection.providerID).joined(separator: " ")
        default: arguments = "" // Qwen performs login in its own interactive CLI.
        }
        return "cd \(quote(directory.path)) && /usr/bin/env \(unset)\(selector) \(quote(executable.path))\(arguments)"
    }
}

enum CodexProfileIdentity {
    // JWT claims are local display hints, not authorization or verified identity.
    static func read(auth: [String: Any], accountID: String?) -> ProviderAccountIdentity? {
        let tokens = auth["tokens"] as? [String: Any]
        guard let token = tokens?["id_token"] as? String ?? auth["id_token"] as? String,
              let payload = token.split(separator: ".", omittingEmptySubsequences: false).dropFirst().first else { return nil }
        var base64 = String(payload).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let claims = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let details = claims["https://api.openai.com/auth"] as? [String: Any]
        let profile = claims["https://api.openai.com/profile"] as? [String: Any]
        return ProviderAccountIdentity(email: claims["email"] as? String ?? profile?["email"] as? String,
                                       organizationID: accountID ?? details?["chatgpt_account_id"] as? String,
                                       organizationName: nil, subscriptionType: details?["chatgpt_plan_type"] as? String)
    }
}
