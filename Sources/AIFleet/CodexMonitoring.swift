import Foundation

struct CodexMonitoringProfile: Codable, Identifiable, Equatable {
    let id: String
    var label: String
    var accountID: String? = nil
}

struct CodexMonitoringResult {
    let status: ProviderStatus
    let usage: CodexAccountUsage?
    let usageError: String?

}

/// Independent, monitor-only logins. Never imports or overwrites the native home.
@MainActor
final class CodexMonitoringStore: ObservableObject {
    static let shared = CodexMonitoringStore()
    @Published private(set) var profiles: [CodexMonitoringProfile]
    @Published private(set) var results: [String: CodexMonitoringResult] = [:]
    @Published private(set) var refreshing = false
    @Published private(set) var authenticatingID: String?
    @Published var error: String?
    private let defaults: UserDefaults
    private let root: URL
    private var operation: CodexAuthenticationOperation?
    private var timer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var lastRefresh: Date?
    private let measure: (URL) async -> CodexMonitoringResult
    private let authenticate: @Sendable (CodexAuthenticationOperation, CodexAuthenticationOperation.Action, URL) throws -> Void

    init(defaults: UserDefaults = .standard, root: URL? = nil,
         measure: ((URL) async -> CodexMonitoringResult)? = nil,
         authenticate: @escaping @Sendable (CodexAuthenticationOperation, CodexAuthenticationOperation.Action, URL) throws -> Void = {
             try $0.run($1, timeout: $1 == .login ? 600 : 30, profileDirectory: $2)
         }) {
        self.defaults = defaults
        self.root = (root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("AI Fleet/CodexProfiles", isDirectory: true)).standardizedFileURL
        self.authenticate = authenticate
        self.measure = measure ?? { directory in
            let beforeIdentity = codexMonitoringIdentity(directory)
            let usage = await Task.detached(priority: .utility) {
                try? CodexAccountUsageReader(profileDirectory: directory).read()
            }.value
            let connection = ProviderConnection(id: directory.lastPathComponent, providerID: "codex", configDirectory: directory.path)
            let status = await StatusService.shared.checkCodex(connection: connection)
            let sameIdentity = beforeIdentity != nil && beforeIdentity == codexMonitoringIdentity(directory)
            return CodexMonitoringResult(status: status, usage: sameIdentity ? usage : nil,
                usageError: !sameIdentity ? "Profile identity changed or is unavailable; refresh again."
                    : usage == nil ? "Account tokens unavailable; quota is shown independently." : nil)
        }
        var ids = Set<String>()
        profiles = (defaults.data(forKey: "codex.monitoringProfiles")
            .flatMap { try? JSONDecoder().decode([CodexMonitoringProfile].self, from: $0) } ?? [])
            .filter { UUID(uuidString: $0.id) != nil && ids.insert($0.id.uppercased()).inserted }
    }

    func directory(for profile: CodexMonitoringProfile) throws -> URL {
        guard UUID(uuidString: profile.id) != nil else { throw CodexAuthenticationError.failed }
        let directory = root.appendingPathComponent(profile.id, isDirectory: true)
        for url in [directory, directory.appendingPathComponent("auth.json"), directory.appendingPathComponent("config.toml")] {
            guard url.resolvingSymlinksInPath().path == url.standardizedFileURL.path else {
                throw ProviderLogout.Failure.unsafePath
            }
        }
        return directory
    }

    @discardableResult
    func add(label: String) -> CodexMonitoringProfile {
        let clean = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = CodexMonitoringProfile(id: UUID().uuidString, label: clean.isEmpty ? "Codex account" : clean)
        profiles.append(profile)
        save()
        return profile
    }

    func profile(for account: FleetAccount) -> CodexMonitoringProfile? {
        profiles.first { $0.accountID == account.id }
    }

    @discardableResult
    func ensureProfile(for account: FleetAccount) -> CodexMonitoringProfile {
        if let existing = profile(for: account) { return existing }
        let profile = CodexMonitoringProfile(id: UUID().uuidString, label: account.name, accountID: account.id)
        profiles.append(profile)
        save()
        return profile
    }

    /// Adopt metadata only; credential directories and stable account badges never move.
    func synchronizeAccounts(_ accounts: AccountStore) {
        var changed = false
        for index in profiles.indices where profiles[index].accountID == nil {
            let label = profiles[index].label.trimmingCharacters(in: .whitespacesAndNewlines)
            let matches = accounts.accounts.filter {
                (!$0.email.isEmpty && $0.email.caseInsensitiveCompare(label) == .orderedSame) ||
                $0.name.caseInsensitiveCompare(label) == .orderedSame
            }
            let account: FleetAccount
            if matches.count == 1 { account = matches[0] }
            else { account = accounts.add(name: label, email: label.contains("@") ? label : "") }
            guard !profiles.contains(where: { $0.accountID == account.id }) else { continue }
            accounts.attachGlobal("codex", to: account.id)
            profiles[index].accountID = account.id
            changed = true
        }
        if changed { save() }
    }

    func forgetAccount(_ account: FleetAccount) {
        if let profile = profile(for: account) { remove(profile) }
    }

    func status(for account: FleetAccount, global: ProviderStatus, accounts: [FleetAccount]) -> ProviderStatus {
        let status: ProviderStatus
        if let profile = profile(for: account) {
            status = results[profile.id]?.status ?? ProviderStatus(id: "codex", name: "Codex", state: .noKey,
                detail: "Sign in required", lastUpdated: nil, authentication: .signInRequired)
        } else if let email = global.account?.email, !account.email.isEmpty,
                  account.email.caseInsensitiveCompare(email) == .orderedSame,
                  accounts.filter({ !$0.email.isEmpty && $0.email.caseInsensitiveCompare(email) == .orderedSame }).count == 1 {
            status = global
        } else {
            status = ProviderStatus(id: "codex", name: "Codex", state: .noKey,
                detail: "Sign in required", lastUpdated: nil, authentication: .signInRequired)
        }
        if status.authentication == .signedIn, !account.email.isEmpty,
           status.account?.email?.caseInsensitiveCompare(account.email) != .orderedSame {
            return ProviderStatus(id: "codex", name: "Codex", state: .offline,
                detail: "Account mismatch · sign in with the expected email", lastUpdated: status.lastUpdated,
                account: status.account, authentication: .unknown, quotaState: .unavailable)
        }
        return status
    }

    func usage(for account: FleetAccount, global: ProviderStatus, accounts: [FleetAccount]) -> CodexAccountUsage? {
        guard status(for: account, global: global, accounts: accounts).authentication == .signedIn else { return nil }
        if let profile = profile(for: account) { return results[profile.id]?.usage }
        // The old shared statistics cache has no account identity. Never assign it to a badge.
        return nil
    }

    func remove(_ profile: CodexMonitoringProfile) {
        guard authenticatingID == nil, !refreshing else { return }
        profiles.removeAll { $0.id == profile.id }
        results.removeValue(forKey: profile.id)
        // Forget metadata only. Never delete credentials or session history here.
        save()
    }

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        operation?.cancel()
        refreshTask?.cancel()
    }

    func cancelAuthentication() { operation?.cancel() }

    func signIn(_ profile: CodexMonitoringProfile) { changeAuthentication(.login, profile: profile) }
    func signOut(_ profile: CodexMonitoringProfile) { changeAuthentication(.logout, profile: profile) }

    private func changeAuthentication(_ action: CodexAuthenticationOperation.Action, profile: CodexMonitoringProfile) {
        guard authenticatingID == nil, !refreshing, profiles.contains(where: { $0.id == profile.id }) else { return }
        error = nil
        let directory: URL
        do {
            directory = try self.directory(for: profile)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for url in [root, directory] {
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            }
        } catch { self.error = "Could not open this account's saved login."; return }
        let operation = CodexAuthenticationOperation()
        self.operation = operation
        authenticatingID = profile.id
        let authenticate = self.authenticate
        Task {
            let failure = await Task.detached(priority: .userInitiated) { () -> String? in
                do { try authenticate(operation, action, directory); return nil }
                catch { return error.localizedDescription }
            }.value
            var outcome = failure
            if failure == nil {
                do {
                    let auth = try self.directory(for: profile).appendingPathComponent("auth.json")
                    if FileManager.default.fileExists(atPath: auth.path) {
                        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: auth.path)
                    } else if action == .login {
                        outcome = "Codex did not save this account's login. Retry native sign-in."
                    }
                } catch {
                    outcome = "Could not verify private permissions for this account's login."
                }
            }
            self.operation = nil
            self.authenticatingID = nil
            self.error = outcome
            // Even cancellation can race with native completion: discard old identity measurements.
            self.results.removeValue(forKey: profile.id)
            self.lastRefresh = nil
            self.refresh(force: true)
        }
    }

    func refresh(force: Bool = false) {
        guard !refreshing, authenticatingID == nil, !profiles.isEmpty,
              force || lastRefresh.map({ Date().timeIntervalSince($0) >= 300 }) ?? true else { return }
        refreshing = true
        let profiles = self.profiles
        refreshTask = Task {
            for profile in profiles {
                guard !Task.isCancelled else { break }
                do {
                    let directory = try self.directory(for: profile)
                    // An unconnected profile must not launch app-server or create credentials.
                    guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("auth.json").path) else {
                        self.results[profile.id] = CodexMonitoringResult(status: LocalProviderAuth.signedOut.status(for: ProviderCatalog.codex),
                                                                       usage: nil, usageError: nil)
                        continue
                    }
                    let result = await self.measure(directory)
                    guard !Task.isCancelled else { break }
                    // Failed auth never inherits an old account's tokens; transport failure is explicit.
                    self.results[profile.id] = result
                } catch {
                    self.results.removeValue(forKey: profile.id)
                    self.error = "Could not read a redirected Codex profile directory."
                }
            }
            self.lastRefresh = Date()
            self.refreshing = false
            self.refreshTask = nil
        }
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(profiles), forKey: "codex.monitoringProfiles")
    }
}

func codexMonitoringTokens(_ usage: CodexAccountUsage?, start: Date?, end: Date?) -> Int? {
    guard let usage else { return nil }
    if start == nil, end == nil { return usage.lifetimeTokens }
    // Missing daily coverage is unknown, never a claimed zero-token period.
    guard !usage.daily.isEmpty else { return nil }
    // These are provider-reported date buckets, not locally timestamped session days.
    return usage.daily.filter { (start == nil || $0.day >= start!) && (end == nil || $0.day <= end!) }
        .reduce(0) { $0 + $1.tokens }
}

private func codexMonitoringIdentity(_ directory: URL) -> String? {
    guard let data = try? Data(contentsOf: directory.appendingPathComponent("auth.json")),
          let auth = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    let tokens = auth["tokens"] as? [String: Any]
    guard let accountID = tokens?["account_id"] as? String ?? auth["account_id"] as? String,
          !accountID.isEmpty else { return nil }
    return accountID
}
