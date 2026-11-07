import Darwin
import Foundation

/// A launch preference, never a replacement for credentials used by existing processes.
struct CodexLaunchSelection: Codable, Equatable {
    let accountID: String
    let profileID: String
    let email: String
    let workspaceID: String
    let usesStandardHome: Bool
}

enum CodexTerminalLaunch {
    static let shimMarker = "# AI Fleet Codex command integration v1"
    static let selectionKey = "codex.nextLaunchAccountID"
    static let sharedEntries = [
        "config.toml", "AGENTS.md", "AGENTS.override.md", "rules", "skills", "plugins", "packages",
        "sessions", "archived_sessions", "history.jsonl", "session_index.jsonl", "memories",
        "thread-writer-locks", "tui-thread-reference-capabilities", "shell_snapshots"
    ]

    enum Failure: LocalizedError {
        case integrationConflict, redirectedPath, invalidSelection, missingCLI, preparationFailed, conflictingOverride
        var errorDescription: String? {
            switch self {
            case .integrationConflict:
                return "The codex command path is already owned by another tool. No command or login was replaced."
            case .redirectedPath:
                return "A launch path is redirected. No account was selected."
            case .invalidSelection:
                return "The selected Codex login is missing or belongs to another account. Reconnect it in AI Fleet."
            case .missingCLI:
                return "The native Codex CLI could not be found. Install Codex before selecting an account."
            case .preparationFailed:
                return "Could not prepare shared Codex settings. Existing files were preserved."
            case .conflictingOverride:
                return "This command overrides account isolation. Use an explicit CODEX_HOME for custom authentication or server connections."
            }
        }
    }

    static func support(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/AI Fleet")
    }

    static func selectionURL(home: URL) -> URL {
        support(home: home).appendingPathComponent("CodexLaunch/default.json")
    }

    static func profileDirectory(_ selection: CodexLaunchSelection, home: URL) throws -> URL {
        guard UUID(uuidString: selection.profileID) != nil, UUID(uuidString: selection.accountID) != nil,
              !selection.email.isEmpty else { throw Failure.invalidSelection }
        let directory = support(home: home).appendingPathComponent("CodexProfiles/\(selection.profileID)")
        try checkPath(directory)
        try checkPath(directory.appendingPathComponent("auth.json"))
        return directory
    }

    static func readSelection(home: URL) throws -> CodexLaunchSelection? {
        let url = selectionURL(home: home)
        try checkPath(url)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let selection = try JSONDecoder().decode(CodexLaunchSelection.self, from: Data(contentsOf: url))
        _ = try profileDirectory(selection, home: home)
        return selection
    }

    static func choose(_ selection: CodexLaunchSelection, home: URL, application: URL,
                       environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        guard nativeExecutable(environment: environment) != nil else { throw Failure.missingCLI }
        let saved = try profileDirectory(selection, home: home)
        let directory = selection.usesStandardHome ? home.appendingPathComponent(".codex") : saved
        try validateIdentity(selection, directory: directory)
        // Preflight before preparing the profile; preserve unrelated command installations.
        let shim = home.appendingPathComponent(".local/bin/codex")
        try checkShim(shim)
        if directory != home.appendingPathComponent(".codex") {
            try prepareSharedState(directory: directory, home: home)
        }
        try installShim(home: home, application: application)
        try atomicWrite(JSONEncoder().encode(selection), to: selectionURL(home: home), mode: 0o600)
    }

    static func validateIdentity(_ selection: CodexLaunchSelection, directory: URL) throws {
        let identity = try CodexCredentialSwitch.identity(at: directory.appendingPathComponent("auth.json"))
        guard identity.email.caseInsensitiveCompare(selection.email) == .orderedSame,
              identity.accountID == selection.workspaceID else {
            throw Failure.invalidSelection
        }
    }

    static func isSharedConfig(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let standard = home.appendingPathComponent(".codex/config.toml")
        return url.lastPathComponent == "config.toml" &&
            url.standardizedFileURL != url.resolvingSymlinksInPath() &&
            url.resolvingSymlinksInPath() == standard.standardizedFileURL &&
            standard.resolvingSymlinksInPath() == standard.standardizedFileURL
    }

    /// Keep pre-existing profile assets for recovery; shared history stays in its original home.
    static func prepareSharedState(directory: URL, home: URL) throws {
        try checkPath(directory)
        let standard = home.appendingPathComponent(".codex")
        try checkPath(standard)
        let manager = FileManager.default
        let profiles = (try? manager.contentsOfDirectory(at: standard, includingPropertiesForKeys: nil)) ?? []
        let names = sharedEntries + profiles.filter { $0.lastPathComponent.hasSuffix(".config.toml") }.map(\.lastPathComponent)
        var installed: [(URL, URL?)] = []
        do {
            for name in names {
                let source = standard.appendingPathComponent(name)
                guard manager.fileExists(atPath: source.path) else { continue }
                let target = directory.appendingPathComponent(name)
                let attributes = try? manager.attributesOfItem(atPath: target.path)
                if attributes?[.type] as? FileAttributeType == .typeSymbolicLink {
                    guard try manager.destinationOfSymbolicLink(atPath: target.path) == source.path else {
                        throw Failure.redirectedPath
                    }
                    continue
                }
                var backup: URL?
                if attributes != nil {
                    let originals = directory.appendingPathComponent(".fleet-before-shared", isDirectory: true)
                    try checkPath(originals)
                    try manager.createDirectory(at: originals, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
                    let retained = originals.appendingPathComponent(name)
                    guard !manager.fileExists(atPath: retained.path) else { throw Failure.preparationFailed }
                    try manager.moveItem(at: target, to: retained)
                    backup = retained
                }
                installed.append((target, backup))
                try manager.createSymbolicLink(atPath: target.path, withDestinationPath: source.path)
            }
        } catch {
            for (target, backup) in installed.reversed() {
                if (try? manager.attributesOfItem(atPath: target.path)[.type]) as? FileAttributeType == .typeSymbolicLink {
                    try? manager.removeItem(at: target)
                }
                if let backup { try? manager.moveItem(at: backup, to: target) }
            }
            throw error
        }
    }

    static func nativeExecutable(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init) +
            ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        for directory in directories {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("codex")
            guard FileManager.default.isExecutableFile(atPath: url.path), !isShim(url),
                  url.resolvingSymlinksInPath() != Bundle.main.executableURL?.resolvingSymlinksInPath() else { continue }
            return url
        }
        return nil
    }

    static func isShim(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let prefix = (try? handle.read(upToCount: 256)) ?? Data()
        return String(data: prefix, encoding: .utf8)?.contains(shimMarker) == true
    }

    private static func checkShim(_ url: URL) throws {
        try checkPath(url)
        if FileManager.default.fileExists(atPath: url.path), !isShim(url) { throw Failure.integrationConflict }
    }

    static func installShim(home: URL, application: URL) throws {
        let shim = home.appendingPathComponent(".local/bin/codex")
        try checkShim(shim)
        let executable = application.appendingPathComponent("Contents/MacOS/AIFleet")
        let quote = ClaudeProfileLaunch.shellQuote
        let script = "#!/bin/sh\n\(shimMarker)\nexec \(quote(executable.path)) --fleet-codex \"$@\"\n"
        try atomicWrite(Data(script.utf8), to: shim, mode: 0o700)
    }

    static func checkPath(_ url: URL) throws {
        guard url.resolvingSymlinksInPath().path == url.standardizedFileURL.path else { throw Failure.redirectedPath }
        // Foundation may leave dangling links unresolved. Inspect each existing component too.
        var component = URL(fileURLWithPath: "/")
        for name in url.standardizedFileURL.pathComponents.dropFirst() {
            component.appendPathComponent(name)
            var info = stat()
            if lstat(component.path, &info) != 0 {
                guard errno == ENOENT else { throw Failure.preparationFailed }
                break
            }
            if info.st_mode & S_IFMT == S_IFLNK,
               !FileManager.default.fileExists(atPath: component.path) { throw Failure.redirectedPath }
        }
    }

    static func atomicWrite(_ data: Data, to url: URL, mode: Int) throws {
        try checkPath(url)
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        let staging = url.deletingLastPathComponent().appendingPathComponent(".fleet-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: staging) }
        guard manager.createFile(atPath: staging.path, contents: data, attributes: [.posixPermissions: mode]),
              rename(staging.path, url.path) == 0 else { throw Failure.preparationFailed }
    }

    static func subcommand(_ arguments: [String]) -> String? {
        let takesValue = ["-c", "--config", "--enable", "--disable", "--remote", "--remote-auth-token-env",
                          "-i", "--image", "-m", "--model", "-p", "--profile", "-s", "--sandbox",
                          "-C", "--cd", "--add-dir", "-a", "--ask-for-approval", "--local-provider"]
        var index = 0
        while index < arguments.count {
            let value = arguments[index]
            if value == "--" { return nil }
            if takesValue.contains(value) { index += 2; continue }
            if value.hasPrefix("-") { index += 1; continue }
            return value
        }
        return nil
    }

    static func shouldRoute(_ arguments: [String], environment: [String: String]) -> Bool {
        if ProviderConnection.global("codex").overrideKeys.contains(where: { environment[$0] != nil }) { return false }
        if arguments.contains(where: { $0 == "--remote" || $0.hasPrefix("--remote=") }) { return false }
        // Server control and diagnostics retain their native scope. User-supplied prompts
        // and option values must not accidentally be interpreted as subcommands.
        if arguments.contains("--help") || arguments.contains("-h") || arguments.contains("--version") || arguments.contains("-V") { return false }
        let nativeCommands = ["agents", "queue", "app-server", "remote-control", "app", "update", "completion", "doctor", "help"]
        return !nativeCommands.contains(subcommand(arguments) ?? "")
    }

    struct Plan {
        let executable: URL
        let arguments: [String]
        let environment: [String: String]
        let selection: CodexLaunchSelection?
        let directory: URL
        let routed: Bool
    }

    static func plan(arguments: [String], home: URL, environment: [String: String]) throws -> Plan {
        guard let native = nativeExecutable(environment: environment) else { throw Failure.missingCLI }
        let standard = home.appendingPathComponent(".codex")
        guard shouldRoute(arguments, environment: environment), let selection = try readSelection(home: home) else {
            return Plan(executable: native, arguments: arguments, environment: environment,
                        selection: nil, directory: standard, routed: false)
        }
        let directory = selection.usesStandardHome ? standard : try profileDirectory(selection, home: home)
        try validateIdentity(selection, directory: directory)
        // Explicit CLI overrides must not escape file-backed, account-scoped authentication.
        for argument in arguments {
            let value = argument.replacingOccurrences(of: "--config=", with: "")
                .replacingOccurrences(of: "-c", with: "")
            if ["cli_auth_credentials_store", "forced_chatgpt_workspace_id", "sqlite_home"].contains(where: {
                value.trimmingCharacters(in: .whitespaces).hasPrefix($0 + "=") ||
                    value.trimmingCharacters(in: .whitespaces).hasPrefix($0 + " ")
            }) { throw Failure.conflictingOverride }
        }
        var scoped = environment
        for key in ProviderConnection.global("codex").overrideKeys { scoped.removeValue(forKey: key) }
        scoped["CODEX_HOME"] = directory.path
        scoped["CODEX_SQLITE_HOME"] = standard.path
        let args = ["--no-daemon", "-c", "cli_auth_credentials_store=\"file\"", "-c",
                    "sqlite_home=" + jsonString(standard.path), "-c",
                    "forced_chatgpt_workspace_id=" + jsonString(selection.workspaceID)] + arguments
        return Plan(executable: native, arguments: args, environment: scoped,
                    selection: selection, directory: directory, routed: true)
    }

    /// The marker follows this PID through exec; stale files are pruned on the next launch.
    static func registerSession(directory: URL, owner: (String, String, String)? = nil) throws -> URL {
        let folder = directory.appendingPathComponent("FleetSessions", isDirectory: true)
        try checkPath(folder)
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for file in try manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) where file.pathExtension == "pid" {
            try checkPath(file)
            let lines = try String(contentsOf: file).split(whereSeparator: { $0.isNewline })
            if let first = lines.first, let pid = Int32(first), pid > 1 {
                if kill(pid, 0) != 0, errno == ESRCH {
                    try manager.removeItem(at: file)
                    try? manager.removeItem(at: file.deletingPathExtension().appendingPathExtension("owner"))
                }
                else if lines.count == 2, let current = CodexProcessControl.startIdentity(pid), current != String(lines[1]) {
                    try manager.removeItem(at: file)
                    try? manager.removeItem(at: file.deletingPathExtension().appendingPathExtension("owner"))
                }
            }
        }
        let marker = folder.appendingPathComponent("terminal-\(getpid()).pid")
        guard let start = CodexProcessControl.startIdentity(getpid()) else { throw Failure.preparationFailed }
        try atomicWrite(Data("\(getpid())\n\(start)\n".utf8), to: marker, mode: 0o600)
        if let owner {
            let record = FleetSessionOwner(providerID: owner.0, accountID: owner.1, profileID: owner.2, pid: getpid(), started: start)
            try atomicWrite(JSONEncoder().encode(record), to: marker.deletingPathExtension().appendingPathExtension("owner"), mode: 0o600)
        }
        return marker
    }

    static func run(arguments: [String], home: URL = FileManager.default.homeDirectoryForCurrentUser,
                    environment: [String: String] = ProcessInfo.processInfo.environment) -> Never {
        var marker: URL?
        do {
            let info = arguments == ["--fleet-launch-info"]
            let transition = !info && shouldRoute(arguments, environment: environment) ? try ProviderTransitionLock(provider: "codex", home: home, exclusive: false) : nil
            defer { withExtendedLifetime(transition) {} }
            let plan = try plan(arguments: info ? [] : arguments, home: home, environment: environment)
            if info {
                let data = try JSONSerialization.data(withJSONObject: [
                    "accountID": plan.selection?.accountID ?? "native", "email": plan.selection?.email ?? "",
                    "credentialHome": plan.directory.path, "historyHome": home.appendingPathComponent(".codex").path,
                    "nativeExecutable": plan.executable.path
                ], options: [.sortedKeys])
                FileHandle.standardOutput.write(data + Data([10]))
                exit(0)
            }
            if plan.routed {
                if plan.directory != home.appendingPathComponent(".codex") {
                    try prepareSharedState(directory: plan.directory, home: home)
                }
                let command = subcommand(arguments)
                let loginStatus = command == "login" && arguments.last == "status"
                if command == "logout" || (command == "login" && !loginStatus) {
                    try CodexCredentialSwitch.checkLegacyConsumers(plan.directory)
                    if plan.selection?.usesStandardHome == true {
                        let pids = try CodexProcessInventory().runningPIDs()
                        guard pids.isEmpty else { throw CodexAuthenticationError.activeProcesses(pids) }
                    }
                } else if !loginStatus { marker = try registerSession(directory: plan.directory, owner: plan.selection.map { ("codex", $0.accountID, $0.profileID) }) }
            }
            for key in environment.keys where plan.environment[key] == nil { unsetenv(key) }
            for (key, value) in plan.environment { setenv(key, value, 1) }
            let values = ([plan.executable.path] + plan.arguments).map { strdup($0) }
            defer { for value in values { free(value) } }
            var argv = values + [nil]
            execv(plan.executable.path, &argv)
            throw Failure.missingCLI
        } catch {
            if let marker { try? FileManager.default.removeItem(at: marker) }
            FileHandle.standardError.write(Data("AI Fleet: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    /// A TOML basic string. TOML has no `\/` escape, so slashes stay literal; otherwise Codex
    /// read `sqlite_home` as a relative `\/Users\/…` directory under the working directory.
    private static func jsonString(_ value: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return String(data: try! encoder.encode(value), encoding: .utf8)!
    }
}
