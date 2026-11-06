import AppKit
import Darwin
import Foundation

// One policy per provider; existing account and credential storage is unchanged.
enum SwitchPolicy: String, CaseIterable, Identifiable {
    case nextLaunch, wait, graceful, force
    var id: String { rawValue }
    var title: String {
        switch self {
        case .nextLaunch: return "Next launch only"
        case .wait: return "Wait for exit"
        case .graceful: return "Stop gracefully"
        case .force: return "Force quit"
        }
    }
}

struct FleetSessionOwner: Codable, Equatable {
    let providerID: String
    let accountID: String
    let profileID: String
    let pid: Int32
    let started: String
}

enum SwitchRecoveryError: LocalizedError {
    case unknownProcesses, timedOut, identity, cancelled
    var errorDescription: String? {
        switch self {
        case .unknownProcesses: return "Some provider processes have no verified account. Review them in Processes, stop only the processes you choose, then retry. Account selection was not changed."
        case .timedOut: return "Processes remain or restarted. Account selection was not changed. Review Processes; Force Quit requires a separate confirmation."
        case .identity: return "The target login is unavailable or has another identity. Use Sign in, then retry."
        case .cancelled: return "Switch cancelled. Any processes already stopped remain stopped."
        }
    }
}

/// Shared by manual recovery and account switching. Never uses a project path as identity.
enum SwitchRecovery {
    static func owner(of process: CodexProcess, roots: [URL]) -> FleetSessionOwner? {
        var matches: [FleetSessionOwner] = []
        for root in roots {
            guard root.standardizedFileURL == root.resolvingSymlinksInPath(),
                  let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { continue }
            for file in files where file.pathExtension == "owner" {
                guard file.standardizedFileURL == file.resolvingSymlinksInPath(),
                      let data = try? Data(contentsOf: file),
                      let owner = try? JSONDecoder().decode(FleetSessionOwner.self, from: data),
                      owner.pid == process.pid, owner.started == process.started,
                      owner.providerID == process.providerID else { continue }
                matches.append(owner)
            }
        }
        return matches.count == 1 ? matches[0] : nil
    }

    static func targets(_ processes: [CodexProcess], providerID: String, accountID: String?,
                        owner: (CodexProcess) -> FleetSessionOwner?) throws -> [CodexProcess] {
        let rows = processes.filter { $0.providerID == providerID }
        guard rows.isEmpty || accountID != nil else { throw SwitchRecoveryError.unknownProcesses }
        var result: [CodexProcess] = []
        for row in rows {
            guard let binding = owner(row) else { throw SwitchRecoveryError.unknownProcesses }
            if binding.accountID == accountID { result.append(row) }
        }
        return result
    }

    @MainActor
    static func transition(policy: SwitchPolicy, validate: () async throws -> Void,
                           read: @escaping () throws -> [CodexProcess], confirm: ([CodexProcess], Bool) -> Bool,
                           stop: (CodexProcess, Bool) throws -> Void,
                           wait: (TimeInterval, () throws -> [CodexProcess]) async throws -> Void,
                           commit: () throws -> Void) async throws {
        try await validate()
        try Task.checkCancellation()
        if policy != .nextLaunch {
            let targets = try read()
            if !targets.isEmpty && policy != .wait {
                guard confirm(targets, policy == .force) else { throw SwitchRecoveryError.cancelled }
                for process in targets {
                    try Task.checkCancellation()
                    try stop(process, policy == .force)
                }
            }
            try await wait(policy == .wait ? 60 : policy == .force ? 3 : 10, read)
        }
        try await validate()
        try Task.checkCancellation()
        if policy != .nextLaunch, !(try read()).isEmpty { throw SwitchRecoveryError.timedOut }
        try commit()
    }

    static func waitForExit(timeout: TimeInterval, read: () throws -> [CodexProcess],
                            sleep: (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var emptyChecks = 0
        while Date() < deadline {
            try Task.checkCancellation()
            if try read().isEmpty { emptyChecks += 1 } else { emptyChecks = 0 }
            if emptyChecks == 2 { return }
            try await sleep(500_000_000)
        }
        throw SwitchRecoveryError.timedOut
    }
}

/// Advisory lock shared with Fleet command shims; descriptor closes on exec or process exit.
final class ProviderTransitionLock {
    let descriptor: Int32
    init(provider: String, home: URL, exclusive: Bool) throws {
        let folder = CodexTerminalLaunch.support(home: home).appendingPathComponent("SwitchLocks")
        try CodexTerminalLaunch.checkPath(folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = folder.appendingPathComponent(provider + ".lock")
        try CodexTerminalLaunch.checkPath(file)
        descriptor = open(file.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CodexProcessControl.Failure.inventory }
        guard flock(descriptor, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 else {
            close(descriptor)
            throw CodexAuthenticationError.busy
        }
    }
    deinit { close(descriptor) }
}

@MainActor
final class SwitchCoordinator: ObservableObject {
    static let shared = SwitchCoordinator()
    @Published private(set) var active = Set<String>()
    @Published private(set) var detail: String?
    private var tasks: [String: Task<Void, Never>] = [:]

    static func policy(_ provider: String) -> SwitchPolicy {
        SwitchPolicy(rawValue: UserDefaults.standard.string(forKey: "switch.policy.\(provider)") ?? "") ?? .graceful
    }

    func cancel(_ provider: String) { tasks[provider]?.cancel() }

    func perform(provider: String, current: String?, validate: @escaping () async throws -> Void,
                 commit: @escaping () throws -> Void, failure: @escaping (Error) -> Void) {
        guard !active.contains(provider) else { return }
        guard StatusService.shared.signingOutProvider == nil,
              !AccountStore.shared.codexSigningIn,
              CodexMonitoringStore.shared.authenticatingID == nil,
              !ProviderLaunchStore.shared.busy else {
            failure(CodexAuthenticationError.busy)
            return
        }
        active.insert(provider)
        tasks[provider] = Task {
            defer { active.remove(provider); tasks.removeValue(forKey: provider); StatusService.shared.refresh() }
            do {
                detail = "Checking target login…"
                await StatusService.shared.joinRefreshBeforeAccountAuth()
                await CodexMonitoringStore.shared.joinRefreshForSwitch()
                let transition = try ProviderTransitionLock(provider: provider, home: FileManager.default.homeDirectoryForCurrentUser, exclusive: true)
                defer { withExtendedLifetime(transition) {} }
                let home = FileManager.default.homeDirectoryForCurrentUser
                let roots = Self.sessionRoots(home: home)
                let read = {
                    try SwitchRecovery.targets(CodexProcessControl.allInventory(), providerID: provider,
                                               accountID: current) { SwitchRecovery.owner(of: $0, roots: roots) }
                }
                try await SwitchRecovery.transition(policy: Self.policy(provider), validate: validate, read: read,
                    confirm: { targets, force in
                        let alert = NSAlert()
                        alert.messageText = force ? "Force quit this account's processes?" : "Stop this account's processes?"
                        alert.informativeText = "PIDs: \(targets.map { String($0.pid) }.joined(separator: ", ")). Current requests can be interrupted. Saved history is retained."
                        alert.addButton(withTitle: force ? "Force Quit" : "Stop")
                        alert.addButton(withTitle: "Cancel")
                        // Keep the confirmation above the menu panel it was opened from.
                        alert.window.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
                        return alert.runModal() == .alertFirstButtonReturn
                    }, stop: { process, force in
                        try CodexProcessControl.stop(process, force: force, read: CodexProcessControl.allInventory)
                    }, wait: { timeout, read in
                        self.detail = "Waiting for provider processes to exit…"
                        try await SwitchRecovery.waitForExit(timeout: timeout, read: read)
                    }, commit: commit)
                detail = "Account selected for the next command. Refreshing limits…"
            } catch { detail = error.localizedDescription; failure(error) }
        }
    }

    static func sessionRoots(home: URL) -> [URL] {
        let support = CodexTerminalLaunch.support(home: home)
        var homes = [home.appendingPathComponent(".codex"), home.appendingPathComponent(".claude")]
        for root in [support.appendingPathComponent("CodexProfiles"), support.appendingPathComponent("ProviderProfiles/claude")] {
            homes += (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        }
        return homes.map { $0.appendingPathComponent("FleetSessions") }
    }
}
