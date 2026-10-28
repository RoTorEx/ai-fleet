import Foundation

enum CodexAuthenticationError: LocalizedError {
    case busy, activeProcesses([Int32]), inventoryUnavailable, unavailable, failed, timedOut, cancelled

    var errorDescription: String? {
        switch self {
        case .busy:
            return "Codex statistics or sign-in is still running. Wait for it to finish and retry. Your login was not changed."
        case .activeProcesses(let pids):
            return "Codex is still running (PIDs: \(pids.map(String.init).joined(separator: ", "))). Changing the shared login can break these sessions. Finish their tasks, exit Codex in those terminals and close Codex IDE/desktop connections, then retry. After signing in, reopen saved conversations with codex resume. AI Fleet has not changed your login or stopped any agent."
        case .inventoryUnavailable:
            return "Could not check running Codex processes. Login was not changed. Retry after checking local process access."
        case .unavailable:
            return "Codex CLI is not installed."
        case .failed:
            return "Native Codex authentication did not complete. Check browser login and retry. No session history was removed."
        case .timedOut:
            return "Codex sign-in timed out. Retry and complete the browser flow. No session history was removed."
        case .cancelled:
            return "Codex sign-in cancelled. No session history was removed."
        }
    }
}

/// Serializes Fleet's native auth consumers. Never changes credentials itself.
enum CodexCredentialAccess {
    private static let registryLock = NSLock()
    private static var locks: [String: NSLock] = [:]

    static func perform<T>(scope: String = "native", _ body: () throws -> T) throws -> T {
        registryLock.lock()
        let lock = locks[scope] ?? NSLock()
        locks[scope] = lock
        registryLock.unlock()
        guard lock.try() else { throw CodexAuthenticationError.busy }
        defer { lock.unlock() }
        return try body()
    }
}

struct CodexProcessInventory {
    func runningPIDs() throws -> [Int32] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        // Command names only: never read arguments, environment or terminal text.
        process.arguments = ["-U", String(getuid()), "-o", "pid=,comm="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw CodexAuthenticationError.inventoryUnavailable }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CodexAuthenticationError.inventoryUnavailable }
        return Self.parse(String(decoding: data, as: UTF8.self))
    }

    static func parse(_ output: String) -> [Int32] {
        output.split(separator: "\n").compactMap { line -> Int32? in
            let parts = line.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard parts.count == 2, let pid = Int32(parts[0]),
                  URL(fileURLWithPath: String(parts[1])).lastPathComponent == "codex" else { return nil }
            return pid
        }.sorted()
    }
}

/// Owns only the login/logout process it starts; never signals another Codex process.
final class CodexAuthenticationOperation: @unchecked Sendable {
    enum Action: String { case login, logout }
    private static let browserLoginLock = NSLock()
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        if let process, process.isRunning { process.terminate() }
        lock.unlock()
    }

    func run(_ action: Action,
             executable: URL? = ProviderCatalog.executableURL(for: ProviderCatalog.codex),
             environment: [String: String] = ProcessInfo.processInfo.environment,
             inventory: () throws -> [Int32] = { try CodexProcessInventory().runningPIDs() },
             timeout: TimeInterval = 600,
             profileDirectory: URL? = nil) throws {
        let browserLock = action == .login ? Self.browserLoginLock : nil
        if let browserLock, !browserLock.try() { throw CodexAuthenticationError.busy }
        defer { browserLock?.unlock() }
        try CodexCredentialAccess.perform(scope: profileDirectory?.standardizedFileURL.path ?? "native") {
            guard let executable else { throw CodexAuthenticationError.unavailable }
            if profileDirectory == nil {
                let pids = try inventory()
                guard pids.isEmpty else { throw CodexAuthenticationError.activeProcesses(pids) }
            }
            let child = Process()
            child.executableURL = executable
            child.arguments = profileDirectory == nil ? [action.rawValue]
                : ["-c", "cli_auth_credentials_store=\"file\"", action.rawValue]
            var nativeEnvironment = environment
            for key in ProviderConnection.global("codex").overrideKeys { nativeEnvironment.removeValue(forKey: key) }
            if let profileDirectory { nativeEnvironment["CODEX_HOME"] = profileDirectory.path }
            child.environment = nativeEnvironment
            child.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
            child.standardInput = FileHandle.nullDevice
            child.standardOutput = FileHandle.nullDevice
            child.standardError = FileHandle.nullDevice
            let exited = DispatchSemaphore(value: 0)
            child.terminationHandler = { _ in exited.signal() }
            lock.lock()
            if cancelled { lock.unlock(); throw CodexAuthenticationError.cancelled }
            do { try child.run() } catch { lock.unlock(); throw CodexAuthenticationError.failed }
            process = child
            lock.unlock()
            defer {
                lock.lock()
                process = nil
                lock.unlock()
            }
            if exited.wait(timeout: .now() + timeout) == .timedOut {
                if child.isRunning { child.terminate() }
                child.waitUntilExit()
                throw CodexAuthenticationError.timedOut
            }
            child.waitUntilExit()
            lock.lock()
            let wasCancelled = cancelled
            lock.unlock()
            if wasCancelled { throw CodexAuthenticationError.cancelled }
            guard child.terminationStatus == 0 else { throw CodexAuthenticationError.failed }
        }
    }
}
