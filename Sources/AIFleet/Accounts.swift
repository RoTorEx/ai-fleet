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

    var statusID: String { configDirectory == nil ? providerID : "\(providerID):\(id)" }
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
        default: return ""
        }
    }
    var overrideKeys: [String] {
        switch providerID {
        case "claude": return ClaudeProfile.authOverrideKeys
        case "codex": return [selector, "OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN"]
        case "kimi": return [selector, "KIMI_SHARE_DIR", "KIMI_API_KEY", "KIMI_BASE_URL", "KIMI_MODEL_NAME"]
        case "qwen": return [selector, "QWEN_RUNTIME_DIR", "QWEN_API_KEY", "OPENAI_API_KEY", "OPENAI_BASE_URL"]
        default: return []
        }
    }
    func credentialURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let directory = configDirectory.map { URL(fileURLWithPath: $0) }
        switch providerID {
        case "codex": return (directory ?? home.appendingPathComponent(".codex")).appendingPathComponent("auth.json")
        case "kimi": return (directory ?? home.appendingPathComponent(".kimi-code")).appendingPathComponent("credentials/kimi-code.json")
        case "qwen": return (directory ?? home.appendingPathComponent(".qwen")).appendingPathComponent("oauth_creds.json")
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
                       quotaNotice: source.quotaNotice)
    }
}

struct FleetAccount: Codable, Identifiable, Equatable {
    let id: String
    let badgeIndex: Int
    var name: String
    var email: String
    var connections: [ProviderConnection]

    static let defaultID = "default"
    static let current = FleetAccount(id: defaultID, badgeIndex: 0, name: "Default", email: "",
        connections: ProviderCatalog.all.map { ProviderConnection(id: $0.id, providerID: $0.id, configDirectory: nil) })
    var badge: String {
        let alphabet = Array("αβγδεζηθικλμνξοπρστυφχψω").map(String.init)
        return badgeIndex < alphabet.count ? alphabet[max(0, badgeIndex)] : "α\(badgeIndex + 1)"
    }
    func connection(for providerID: String) -> ProviderConnection? {
        connections.first { $0.providerID == providerID }
    }
    func tooltip(for connection: ProviderConnection, status: ProviderStatus?) -> String {
        let identity = status?.account?.caption ?? ""
        let metadata = identity.isEmpty ? email : identity
        return ["\(badge) · \(name)", metadata, status?.detail ?? "Checking…", status?.quotaNotice ?? ""]
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

@MainActor
final class AccountStore: ObservableObject {
    static let shared = AccountStore()
    @Published private(set) var accounts: [FleetAccount]
    @Published private(set) var selections: [String: String]
    @Published var launchError: String?
    private let defaults: UserDefaults
    private let home: URL
    private var nextBadge: Int

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
        // Preserve one default connection per provider, even after damaged preferences.
        if !values.contains(where: { $0.id == FleetAccount.defaultID }) { values.insert(FleetAccount(id: "default", badgeIndex: 0, name: "Default", email: "", connections: []), at: 0) }
        let defaultIndex = values.firstIndex { $0.id == FleetAccount.defaultID }!
        for provider in ProviderCatalog.all where !values.contains(where: { $0.connections.contains { $0.providerID == provider.id && $0.configDirectory == nil } }) {
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
        nextBadge = max(defaults.integer(forKey: "fleet.nextBadge"), (values.map(\.badgeIndex).max() ?? -1) + 1)
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
    func update(_ id: String, name: String, email: String) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        accounts[index].email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        save()
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
    func detach(_ providerID: String, from accountID: String) {
        guard let index = accounts.firstIndex(where: { $0.id == accountID }),
              accounts[index].connection(for: providerID)?.configDirectory != nil else { return }
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
        guard id != FleetAccount.defaultID, let account = accounts.first(where: { $0.id == id }) else { return }
        let defaultsToKeep = account.connections.filter { $0.configDirectory == nil }
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
        save()
    }
    private func repairSelection(_ providerID: String) {
        selections[providerID] = selected(for: providerID)?.id
    }
    private func save() {
        defaults.set(try? JSONEncoder().encode(accounts), forKey: "fleet.accounts")
        defaults.set(selections, forKey: "fleet.selections")
        defaults.set(nextBadge, forKey: "fleet.nextBadge")
    }

    func open(_ connection: ProviderConnection, account: FleetAccount, login: Bool = false) {
        guard let provider = ProviderCatalog.definition(for: connection.providerID), let executable = ProviderCatalog.executableURL(for: provider) else {
            launchError = "Provider CLI is not installed."
            return
        }
        var directory = home
        if !login {
            let panel = NSOpenPanel()
            panel.title = "Open \(provider.name) — \(account.badge)"
            panel.prompt = "Open"
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            guard panel.runModal() == .OK, let url = panel.url else { return }
            directory = url
        }
        launchError = nil
        if let path = connection.configDirectory {
            do {
                try FileManager.default.createDirectory(at: URL(fileURLWithPath: path), withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            } catch {
                launchError = "Could not create the provider configuration folder."
                return
            }
        }
        let command = AccountLaunch.command(connection: connection, executable: executable, directory: directory, login: login)
        let source = "tell application \"Terminal\"\nactivate\ndo script \(ClaudeProfileLaunch.appleScriptString(command))\nend tell"
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { launchError = "Could not prepare Terminal launch."; return }
        script.executeAndReturnError(&error)
        if error != nil { launchError = "Could not open Terminal. Check macOS Automation permission for AI Fleet." }
        else { select(account.id, for: provider.id) }
    }
}

enum AccountLaunch {
    static func command(connection: ProviderConnection, executable: URL, directory: URL, login: Bool) -> String {
        let quote = ClaudeProfileLaunch.shellQuote
        let unset = connection.overrideKeys.map { "-u " + quote($0) }.joined(separator: " ")
        let selector = connection.configDirectory.map { " " + quote(connection.selector + "=" + $0) } ?? ""
        let arguments: String
        switch (connection.providerID, login) {
        case ("claude", true): arguments = " auth login"
        case ("codex", true), ("kimi", true): arguments = " login"
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
