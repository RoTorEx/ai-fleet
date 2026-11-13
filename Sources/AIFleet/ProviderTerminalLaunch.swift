import Darwin
import Foundation

struct ProviderLaunchProfile: Codable, Equatable {
    let providerID: String
    let accountID: String
    var email: String
    let native: Bool
    var credentialHomeID: String? = nil
}

/// Provider adapters keep Switch semantics identical without replacing live credentials.
enum ProviderTerminalLaunch {
    enum Failure: LocalizedError {
        case missingCLI(String), invalidProfile, commandConflict(String)
        var errorDescription: String? {
            switch self {
            case .missingCLI(let name): return "The native \(name) CLI is not installed or could not be found."
            case .invalidProfile: return "The selected provider account profile is invalid. Reconnect it in Settings → Accounts."
            case .commandConflict(let name): return "The \(name) command path belongs to another tool. No executable was replaced."
            }
        }
    }
    static let marker = "# AI Fleet provider command integration v1"
    static let providers = ["claude", "kimi", "qwen", "gemini"]
    static let defaultsKey = "terminal.providerProfiles"

    static func directory(_ profile: ProviderLaunchProfile, home: URL) throws -> URL {
        // The migrated native account retains its reserved ID when it gains an email.
        guard providers.contains(profile.providerID),
              profile.accountID == FleetAccount.defaultID || UUID(uuidString: profile.accountID) != nil else {
            throw Failure.invalidProfile
        }
        guard profile.credentialHomeID == nil || UUID(uuidString: profile.credentialHomeID!) != nil else { throw Failure.invalidProfile }
        let base: URL
        if profile.native {
            base = home
        } else {
            base = CodexTerminalLaunch.support(home: home).appendingPathComponent("ProviderProfiles/\(profile.providerID)/\(profile.credentialHomeID ?? profile.accountID)")
        }
        let result = profile.native ? base.appendingPathComponent(nativeName(profile.providerID)) :
            profile.providerID == "gemini" ? base.appendingPathComponent(".gemini") : base
        try CodexTerminalLaunch.checkPath(result)
        return result
    }

    static func nativeName(_ providerID: String) -> String {
        ["claude": ".claude", "kimi": ".kimi-code", "qwen": ".qwen", "gemini": ".gemini"][providerID] ?? ""
    }

    static func selectionURL(_ providerID: String, home: URL) throws -> URL {
        guard providers.contains(providerID) else { throw Failure.invalidProfile }
        return CodexTerminalLaunch.support(home: home).appendingPathComponent("ProviderLaunch/\(providerID).json")
    }

    static func read(_ providerID: String, home: URL) throws -> ProviderLaunchProfile? {
        let file = try selectionURL(providerID, home: home)
        try CodexTerminalLaunch.checkPath(file)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let profile = try JSONDecoder().decode(ProviderLaunchProfile.self, from: Data(contentsOf: file))
        guard profile.providerID == providerID else { throw Failure.invalidProfile }
        _ = try directory(profile, home: home)
        return profile
    }

    static func isShim(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return String(data: (try? handle.read(upToCount: 256)) ?? Data(), encoding: .utf8)?.contains(marker) == true
    }

    static func nativeExecutable(_ providerID: String, environment: [String: String]) -> URL? {
        guard let definition = ProviderCatalog.definition(for: providerID) else { return nil }
        let paths = (environment["PATH"] ?? "").split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin"]
        for path in paths {
            for name in definition.executableNames {
                let url = URL(fileURLWithPath: path).appendingPathComponent(name)
                if FileManager.default.isExecutableFile(atPath: url.path), !isShim(url) { return url }
            }
        }
        return nil
    }

    static func environment(_ profile: ProviderLaunchProfile, home: URL,
                            inheriting source: [String: String]) throws -> [String: String] {
        let connection = ProviderConnection.global(profile.providerID)
        var result = source
        for key in connection.overrideKeys { result.removeValue(forKey: key) }
        // Even spelling the default directory explicitly selects a different Claude Keychain item.
        if profile.native && profile.providerID == "claude" { return result }
        let directory = try directory(profile, home: home)
        // Gemini's selector is a parent home, unlike the direct config homes of other CLIs.
        result[connection.selector] = profile.providerID == "gemini" ? directory.deletingLastPathComponent().path : directory.path
        return result
    }

    static func prepare(_ profile: ProviderLaunchProfile, home: URL) throws {
        let directory = try directory(profile, home: home)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try validateCredentialPaths(profile, home: home)
        guard !profile.native else { return }
        let common: [String]
        switch profile.providerID {
        case "claude": common = ["projects", "history.jsonl", "skills", "commands", "agents", "CLAUDE.md"]
        case "kimi": common = ["sessions", "skills", "AGENTS.md", "agents", "mcp.json", "tui.toml"]
        case "qwen": common = ["projects", "conversations", "skills", "commands", "QWEN.md"]
        case "gemini": common = ["tmp", "history", "skills", "commands", "GEMINI.md"]
        default: common = []
        }
        let native = home.appendingPathComponent(nativeName(profile.providerID))
        for name in common {
            let source = native.appendingPathComponent(name), target = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            if let type = try? FileManager.default.attributesOfItem(atPath: target.path)[.type] as? FileAttributeType {
                if type == .typeSymbolicLink {
                    guard try FileManager.default.destinationOfSymbolicLink(atPath: target.path) == source.path else {
                        throw CodexTerminalLaunch.Failure.redirectedPath
                    }
                }
                // Existing independent state is never overwritten or migrated implicitly.
                continue
            }
            try FileManager.default.createSymbolicLink(atPath: target.path, withDestinationPath: source.path)
        }
    }

    static func validateCredentialPaths(_ profile: ProviderLaunchProfile, home: URL) throws {
        let root = try directory(profile, home: home)
        let names: [String]
        switch profile.providerID {
        case "claude": names = [".credentials.json", ".claude.json"]
        case "kimi": names = ["credentials", "credentials/kimi-code.json", "config.toml"]
        case "qwen": names = ["oauth_creds.json", "credentials.json"]
        case "gemini": names = ["oauth_creds.json", "google_accounts.json"]
        default: throw Failure.invalidProfile
        }
        for name in names { try CodexTerminalLaunch.checkPath(root.appendingPathComponent(name)) }
    }

    static func choose(_ profile: ProviderLaunchProfile, home: URL, application: URL,
                       environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        guard nativeExecutable(profile.providerID, environment: environment) != nil else { throw Failure.missingCLI(profile.providerID) }
        try installShim(profile.providerID, home: home, application: application)
        try prepare(profile, home: home)
        try CodexTerminalLaunch.atomicWrite(JSONEncoder().encode(profile), to: selectionURL(profile.providerID, home: home), mode: 0o600)
    }

    static func installShim(_ providerID: String, home: URL, application: URL) throws {
        guard providers.contains(providerID) else { throw Failure.invalidProfile }
        let names = ProviderCatalog.definition(for: providerID)?.executableNames ?? [providerID]
        let paths = names.map { home.appendingPathComponent(".local/bin/\($0)") }
        for shim in paths {
            try CodexTerminalLaunch.checkPath(shim)
            if FileManager.default.fileExists(atPath: shim.path), !isShim(shim) { throw Failure.commandConflict(providerID) }
        }
        let executable = application.appendingPathComponent("Contents/MacOS/AIFleet")
        let script = "#!/bin/sh\n\(marker)\nexec \(ClaudeProfileLaunch.shellQuote(executable.path)) --fleet-provider \(providerID) \"$@\"\n"
        for shim in paths { try CodexTerminalLaunch.atomicWrite(Data(script.utf8), to: shim, mode: 0o700) }
    }

    struct Plan {
        let executable: URL
        let arguments: [String]
        let environment: [String: String]
        let profile: ProviderLaunchProfile?
        let directory: URL?
    }

    static func shouldRoute(_ providerID: String, arguments: [String], environment: [String: String]) -> Bool {
        let connection = ProviderConnection.global(providerID)
        let explicit = connection.overrideKeys.contains { environment[$0] != nil }
        let nativeCommand = arguments.contains("--help") || arguments.contains("--version") || arguments.contains("-h") || arguments.contains("-V") || arguments.contains("-v") ||
            ["update", "upgrade", "completion", "serve", "daemon", "remote-control"].contains(arguments.first ?? "")
        return !explicit && !nativeCommand
    }

    static func plan(_ providerID: String, arguments: [String], home: URL,
                     environment: [String: String]) throws -> Plan {
        guard let executable = nativeExecutable(providerID, environment: environment) else { throw Failure.missingCLI(providerID) }
        guard shouldRoute(providerID, arguments: arguments, environment: environment), let profile = try read(providerID, home: home) else {
            return Plan(executable: executable, arguments: arguments, environment: environment, profile: nil, directory: nil)
        }
        let directory = try directory(profile, home: home)
        try validateCredentialPaths(profile, home: home)
        return Plan(executable: executable, arguments: arguments,
                    environment: try self.environment(profile, home: home, inheriting: environment), profile: profile, directory: directory)
    }

    static func run(_ providerID: String, arguments: [String]) -> Never {
        var marker: URL?
        do {
            let home = FileManager.default.homeDirectoryForCurrentUser, source = ProcessInfo.processInfo.environment
            let info = arguments == ["--fleet-launch-info"]
            let transition = !info && providerID == "claude" && shouldRoute(providerID, arguments: arguments, environment: source) ? try ProviderTransitionLock(provider: providerID, home: home, exclusive: false) : nil
            defer { withExtendedLifetime(transition) {} }
            let plan = try plan(providerID, arguments: info ? [] : arguments, home: home, environment: source)
            if info {
                print(String(data: try JSONSerialization.data(withJSONObject: ["providerID": providerID,
                    "accountID": plan.profile?.accountID ?? "native", "email": plan.profile?.email ?? "",
                    "credentialHome": plan.directory?.path ?? "native"], options: [.sortedKeys]), encoding: .utf8)!)
                exit(0)
            }
            if let profile = plan.profile, let directory = plan.directory {
                try prepare(profile, home: home)
                if providerID == "claude", !arguments.prefix(1).elementsEqual(["auth"]) {
                    let snapshot = ClaudeAuthReader(executableURL: plan.executable, environment: plan.environment).readSnapshot()
                    guard snapshot.auth == .signedIn,
                          snapshot.account?.email.map(ConnectionIdentity.normalize) == ConnectionIdentity.normalize(profile.email) else {
                        throw Failure.invalidProfile
                    }
                }
                if arguments.first == "logout" || arguments.first == "login" || arguments.prefix(2).elementsEqual(["auth", "logout"]) || arguments.prefix(2).elementsEqual(["auth", "login"]) {
                    try CodexCredentialSwitch.checkLegacyConsumers(directory)
                } else { marker = try CodexTerminalLaunch.registerSession(directory: directory, owner: (providerID, profile.accountID, profile.accountID)) }
            }
            for key in source.keys where plan.environment[key] == nil { unsetenv(key) }
            for (key, value) in plan.environment { setenv(key, value, 1) }
            let values = ([plan.executable.path] + plan.arguments).map { strdup($0) }
            defer { for value in values { free(value) } }
            var argv = values + [nil]
            execv(plan.executable.path, &argv)
            throw Failure.missingCLI(providerID)
        } catch {
            if let marker { try? FileManager.default.removeItem(at: marker) }
            FileHandle.standardError.write(Data("AI Fleet: \(error.localizedDescription)\n".utf8)); exit(1)
        }
    }
}

@MainActor
final class ProviderLaunchStore: ObservableObject {
    static let shared = ProviderLaunchStore()
    @Published private(set) var profiles: [ProviderLaunchProfile]
    @Published private(set) var selected: [String: String]
    @Published private(set) var message: String? {
        didSet { messageIsError = false }
    }
    /// Set after `message` for failures; confirmations stay out of the menu.
    @Published private(set) var messageIsError = false
    @Published private(set) var messageAccountID: String?
    @Published private(set) var messageProviderID: String?
    @Published private(set) var busy = false
    private let defaults: UserDefaults
    private let home: URL

    init(defaults: UserDefaults = .standard, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.defaults = defaults; self.home = home
        profiles = defaults.data(forKey: ProviderTerminalLaunch.defaultsKey)
            .flatMap { try? JSONDecoder().decode([ProviderLaunchProfile].self, from: $0) } ?? []
        selected = defaults.dictionary(forKey: "terminal.providerSelections") as? [String: String] ?? [:]
    }

    func profile(_ providerID: String, accountID: String) -> ProviderLaunchProfile? {
        profiles.first { $0.providerID == providerID && $0.accountID == accountID }
    }

    func installCommandIntegration() {
        do { try CodexTerminalLaunch.refreshShimIfInstalled(home: home, application: Bundle.main.bundleURL) }
        catch { messageProviderID = "codex"; message = "codex: \(error.localizedDescription)"; messageIsError = true }
        for provider in ProviderTerminalLaunch.providers {
            do { try ProviderTerminalLaunch.installShim(provider, home: home, application: Bundle.main.bundleURL) }
            catch { messageProviderID = provider; message = "\(provider): \(error.localizedDescription)"; messageIsError = true }
        }
    }

    func connection(_ profile: ProviderLaunchProfile, accounts: [FleetAccount]) -> ProviderConnection? {
        guard let original = accounts.first(where: { $0.id == profile.accountID })?.connection(for: profile.providerID),
              !profile.native, let directory = try? ProviderTerminalLaunch.directory(profile, home: home) else { return nil }
        return ProviderConnection(id: original.id, providerID: profile.providerID, configDirectory: directory.path, globalAssociation: true)
    }

    func switchAccount(_ account: FleetAccount, providerID: String, global: ProviderStatus,
                       environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard !busy, !SwitchCoordinator.shared.active.contains(providerID) else { return }
        messageAccountID = account.id; messageProviderID = providerID
        do {
            let existing = profile(providerID, accountID: account.id)
            let matches = global.authentication == .signedIn && !account.email.isEmpty &&
                global.account?.email?.caseInsensitiveCompare(account.email) == .orderedSame
            let profile = existing ?? ProviderLaunchProfile(providerID: providerID, accountID: account.id,
                                                           email: account.email, native: matches)
            if providerID == "claude" {
                SwitchCoordinator.shared.perform(provider: providerID, current: selected[providerID], validate: {
                    guard let executable = ProviderTerminalLaunch.nativeExecutable(providerID, environment: environment) else {
                        throw SwitchRecoveryError.identity
                    }
                    let scoped = try ProviderTerminalLaunch.environment(profile, home: self.home, inheriting: environment)
                    let snapshot = await Task.detached(priority: .utility) {
                        ClaudeAuthReader(executableURL: executable, environment: scoped).readSnapshot()
                    }.value
                    guard snapshot.auth == .signedIn,
                          snapshot.account?.email?.caseInsensitiveCompare(account.email) == .orderedSame else {
                        throw SwitchRecoveryError.identity
                    }
                }, commit: { [self] in
                    try ProviderTerminalLaunch.choose(profile, home: home, application: Bundle.main.bundleURL, environment: environment)
                    if existing == nil { profiles.append(profile) }
                    selected[providerID] = account.id
                    save()
                    message = "Account selected for the next Claude command."
                }, resolved: { [weak self] in
                    guard let self, self.message == SwitchRecoveryError.unknownProcesses.localizedDescription ||
                        self.message == SwitchRecoveryError.timedOut.localizedDescription else { return }
                    self.message = nil
                }, failure: { [weak self] error in self?.message = error.localizedDescription; self?.messageIsError = true })
            } else {
            try ProviderTerminalLaunch.choose(profile, home: home, application: Bundle.main.bundleURL, environment: environment)
            if existing == nil { profiles.append(profile) }
            selected[providerID] = account.id
            save()
            message = "Default for the next \(providerID) launch. Running agents keep their accounts."
            }
        } catch { message = error.localizedDescription; messageIsError = true }
    }

    func signIn(_ account: FleetAccount, providerID: String, executable: URL? = nil) {
        guard !busy, !SwitchCoordinator.shared.active.contains(providerID) else { return }
        // Providers without per-account launch profiles share the native CLI login.
        guard ProviderTerminalLaunch.providers.contains(providerID) || providerID == "codex" else {
            AccountStore.shared.signInGlobally(providerID); return
        }
        messageAccountID = account.id; messageProviderID = providerID
        do {
            var profile = ProviderLaunchProfile(providerID: providerID, accountID: account.id, email: account.email, native: false)
            if providerID == "claude" {
                let key = "accounts.pendingClaude.\(account.id)"
                profile.credentialHomeID = defaults.string(forKey: key) ?? UUID().uuidString
                defaults.set(profile.credentialHomeID, forKey: key)
            }
            let directory = try ProviderTerminalLaunch.directory(profile, home: home)
            try CodexCredentialSwitch.checkLegacyConsumers(directory)
            try ProviderTerminalLaunch.validateCredentialPaths(profile, home: home)
            try ProviderTerminalLaunch.prepare(profile, home: home)
            guard ["claude", "kimi"].contains(providerID) else {
                message = "Complete native sign-in on the first \(providerID) launch after Switch. Existing sessions and their logins are unchanged."
                return
            }
            guard let executable = executable ?? ProviderCatalog.executableURL(for: ProviderCatalog.definition(for: providerID)!) else {
                throw ProviderTerminalLaunch.Failure.missingCLI(providerID)
            }
            let environment = try ProviderTerminalLaunch.environment(profile, home: home, inheriting: ProcessInfo.processInfo.environment)
            busy = true; message = "Complete \(providerID) sign-in in your browser. The default launch account is unchanged."
            Task {
                defer { busy = false; StatusService.shared.refresh() }
                await StatusService.shared.joinRefreshBeforeAccountAuth()
                let result = await Task.detached(priority: .utility) {
                    LocalCommandReader.read(executableURL: executable, arguments: providerID == "claude" ? ["auth", "login"] : ["login"],
                                            timeout: 600, environment: environment)
                }.value
                let verified: Bool
                if providerID == "claude", result?.exitCode == 0 {
                    let snapshot = await Task.detached(priority: .utility) {
                        ClaudeAuthReader(executableURL: executable, environment: environment).readSnapshot()
                    }.value
                    if snapshot.auth == .signedIn, let email = snapshot.account?.email {
                        let identity = ConnectionIdentity(email: email, organizationID: snapshot.account?.organizationID)
                        verified = AccountStore.shared.confirmIdentity(identity, provider: providerID, accountID: account.id)
                        if verified { profile.email = identity.email }
                    } else { verified = false }
                } else { verified = result?.exitCode == 0 }
                if verified {
                    defaults.removeObject(forKey: "accounts.pendingClaude.\(account.id)")
                    profiles.removeAll { $0.providerID == providerID && $0.accountID == account.id }
                    profiles.append(profile); save()
                }
                message = verified ? "Sign-in finished. Use Switch to choose this account for new launches." : "Sign-in failed or identity did not match. Previous connection is preserved. Retry native browser sign-in."
                messageIsError = !verified
                StatusService.shared.refresh()
            }
        } catch { message = error.localizedDescription; messageIsError = true }
    }

    func signOut(_ account: FleetAccount, providerID: String) {
        guard !busy, !SwitchCoordinator.shared.active.contains(providerID) else { return }
        messageAccountID = account.id; messageProviderID = providerID
        guard let profile = profile(providerID, accountID: account.id), !profile.native else {
            Task { await StatusService.shared.signOutGlobally(providerID) }
            return
        }
        do {
            let directory = try ProviderTerminalLaunch.directory(profile, home: home)
            try CodexCredentialSwitch.checkLegacyConsumers(directory)
            try ProviderTerminalLaunch.validateCredentialPaths(profile, home: home)
            let environment = try ProviderTerminalLaunch.environment(profile, home: home, inheriting: ProcessInfo.processInfo.environment)
            busy = true
            Task {
                await StatusService.shared.joinRefreshBeforeAccountAuth()
                let result = await Task.detached(priority: .utility) { () -> String? in
                    do {
                        if ["claude", "kimi"].contains(providerID) {
                            guard let executable = ProviderTerminalLaunch.nativeExecutable(providerID, environment: environment),
                                  let result = LocalCommandReader.read(executableURL: executable,
                                    arguments: providerID == "claude" ? ["auth", "logout"] : ["logout"], timeout: 30,
                                    environment: environment), result.exitCode == 0 else {
                                return "Native sign-out did not complete. Credentials were not removed by AI Fleet."
                            }
                        } else {
                            let names = providerID == "gemini" ? ["oauth_creds.json"] : ["oauth_creds.json", "credentials.json"]
                            for name in names { try CodexTerminalLaunch.checkPath(directory.appendingPathComponent(name)) }
                            for name in names {
                                let file = directory.appendingPathComponent(name)
                                if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
                            }
                        }
                        return nil
                    } catch { return error.localizedDescription }
                }.value
                busy = false; message = result ?? "This account's local login was cleared. Other account homes were retained."
                StatusService.shared.refresh()
            }
        } catch { message = error.localizedDescription; messageIsError = true }
    }

    func forget(_ accountID: String) throws {
        guard !busy, SwitchCoordinator.shared.active.isEmpty else { throw CodexAuthenticationError.busy }
        for (providerID, selectedID) in selected where selectedID == accountID {
            let file = try ProviderTerminalLaunch.selectionURL(providerID, home: home)
            try CodexTerminalLaunch.checkPath(file)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            selected.removeValue(forKey: providerID)
        }
        profiles.removeAll { $0.accountID == accountID }; save()
    }

    func forgetProvider(_ provider: String, accountID: String) throws {
        guard !busy, !SwitchCoordinator.shared.active.contains(provider) else { throw CodexAuthenticationError.busy }
        if selected[provider] == accountID {
            let file = try ProviderTerminalLaunch.selectionURL(provider, home: home)
            try CodexTerminalLaunch.checkPath(file)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            selected.removeValue(forKey: provider)
        }
        profiles.removeAll { $0.providerID == provider && $0.accountID == accountID }
        save()
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(profiles), forKey: ProviderTerminalLaunch.defaultsKey)
        defaults.set(selected, forKey: "terminal.providerSelections")
    }
}
