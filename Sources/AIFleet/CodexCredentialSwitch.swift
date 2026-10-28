import Foundation
import Darwin

enum CodexCredentialSwitch {
    enum Failure: LocalizedError {
        case missingLogin, wrongAccount, unsafePath, unsupportedStore, unsavedCurrent, externalChange
        var errorDescription: String? {
            switch self {
            case .missingLogin: return "This account has no saved login. Connect it before switching."
            case .wrongAccount: return "The saved credentials belong to a different account."
            case .unsafePath: return "Redirected credential paths cannot be switched. No login was changed."
            case .unsupportedStore: return "Switching requires file-backed Codex credentials. No settings or login were changed."
            case .unsavedCurrent: return "The current login has no saved account. Save that account before switching."
            case .externalChange: return "The terminal login changed outside AI Fleet. Saved account data is preserved; reconnect this account if needed."
            }
        }
    }

    struct Identity: Equatable { let email: String; let accountID: String }

    // Preserve consumers created by the withdrawn 1.3.8 launcher until they exit.
    static func checkLegacyConsumers(_ home: URL) throws {
        let directory = home.appendingPathComponent("FleetSessions")
        try check(directory)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where file.pathExtension == "pid" {
            try check(file)
            guard let pid = Int32(try String(contentsOf: file).trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else {
                throw CodexAuthenticationError.inventoryUnavailable
            }
            if kill(pid, 0) == 0 || errno == EPERM { throw CodexAuthenticationError.activeProcesses([pid]) }
        }
    }

    static func identity(at url: URL) throws -> Identity {
        try check(url)
        return try identity(data: Data(contentsOf: url))
    }

    private static func identity(data: Data) throws -> Identity {
        guard let auth = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = auth["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String, !access.isEmpty,
              let accountID = tokens["account_id"] as? String, !accountID.isEmpty,
              let email = CodexProfileIdentity.read(auth: auth, accountID: accountID)?.email, !email.isEmpty else {
            throw Failure.missingLogin
        }
        return Identity(email: email.lowercased(), accountID: accountID)
    }

    private static func check(_ url: URL) throws {
        guard url.standardizedFileURL.path == url.resolvingSymlinksInPath().path else { throw Failure.unsafePath }
    }

    private static func write(_ data: Data, to url: URL) throws {
        try check(url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        // Atomic replacement changes only auth.json, never the state/config/history directories.
        let staging = url.deletingLastPathComponent().appendingPathComponent(".fleet-auth-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        guard FileManager.default.createFile(atPath: staging.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(staging.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    static func checkpoint(shared: URL, saved: URL, expectedEmail: String) throws {
        try checkLegacyConsumers(saved)
        let source = shared.appendingPathComponent("auth.json")
        try check(source)
        let data = try Data(contentsOf: source)
        guard try identity(data: data).email.caseInsensitiveCompare(expectedEmail) == .orderedSame else { throw Failure.wrongAccount }
        try write(data, to: saved.appendingPathComponent("auth.json"))
    }

    static func activate(incoming: URL, expectedEmail: String, shared: URL,
                         inventory: () throws -> [Int32] = { try CodexProcessInventory().runningPIDs() },
                         savedHome: (String) throws -> URL?) throws {
        let source = incoming.appendingPathComponent("auth.json")
        let destination = shared.appendingPathComponent("auth.json")
        try check(source); try check(destination)
        let incomingData = try Data(contentsOf: source)
        let incomingIdentity = try identity(data: incomingData)
        guard incomingIdentity.email.caseInsensitiveCompare(expectedEmail) == .orderedSame else { throw Failure.wrongAccount }
        let config = shared.appendingPathComponent("config.toml")
        try check(config)
        if let text = try? String(contentsOf: config),
           text.range(of: #"(?m)^\s*cli_auth_credentials_store\s*=\s*["'](?:auto|keyring|ephemeral)["']"#,
                      options: .regularExpression) != nil { throw Failure.unsupportedStore }
        let currentData = try? Data(contentsOf: destination)
        if let currentData, try identity(data: currentData) == incomingIdentity { return }
        let processes = try inventory()
        guard processes.isEmpty else { throw CodexAuthenticationError.activeProcesses(processes) }
        if let currentData {
            let current = try identity(data: currentData)
            guard let outgoing = try savedHome(current.email) else { throw Failure.unsavedCurrent }
            let outgoingFile = outgoing.appendingPathComponent("auth.json")
            guard outgoingFile.standardizedFileURL.path != destination.standardizedFileURL.path,
                  outgoingFile.standardizedFileURL.path != source.standardizedFileURL.path else { throw Failure.unsafePath }
            try write(currentData, to: outgoingFile)
        }
        // Recheck immediately before writing; a concurrently launched consumer fails closed.
        let finalProcesses = try inventory()
        guard finalProcesses.isEmpty else { throw CodexAuthenticationError.activeProcesses(finalProcesses) }
        guard (try? Data(contentsOf: destination)) == currentData else { throw Failure.externalChange }
        try write(incomingData, to: destination)
    }
}
