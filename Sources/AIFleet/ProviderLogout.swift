import Foundation
import Security

/// Uses native Codex logout; other providers remove only their monitored local login.
struct ProviderLogout {
    var home = FileManager.default.homeDirectoryForCurrentUser
    var environment = ProcessInfo.processInfo.environment
    var removeClaudeKeychain: () throws -> Void = {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: "Claude Code-credentials"]
        let result = SecItemDelete(query as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw Failure.keychain }
        var unused: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &unused) == errSecItemNotFound else {
            throw Failure.keychain
        }
    }

    var signOutCodex: () throws -> Void = {
        try CodexAuthenticationOperation().run(.logout, timeout: 30)
    }

    enum Failure: LocalizedError {
        case unsupported, keychain, environmentKey, unsafePath
        var errorDescription: String? {
            switch self {
            case .unsupported: return "This provider's local sign-out is unsupported."
            case .keychain: return "Could not remove Claude login from Keychain. Check Keychain access and retry."
            case .environmentKey: return "Remove KIMI_API_KEY from the app environment and restart before signing out."
            case .unsafePath: return "Sign-out cannot modify a redirected credential path. Use the provider's native account settings."
            }
        }
    }

    func signOut(_ providerID: String) throws {
        guard let provider = ProviderCatalog.definition(for: providerID) else { throw Failure.unsupported }
        if providerID == "kimi", !(environment["KIMI_API_KEY"] ?? "").isEmpty { throw Failure.environmentKey }
        let files = providerID == "claude" ? [".claude/.credentials.json"] : provider.credentialPaths
        // Validate every destination before the first mutation; never follow redirected directories.
        let metadata: [(String, String)] = providerID == "claude" ? [(".claude.json", "oauthAccount")]
            : providerID == "gemini" ? [(".gemini/google_accounts.json", "active")]
            : providerID == "kimi" ? [("Library/Application Support/AI Fleet/config.json", "kimiApiKey")] : []
        for path in files + metadata.map(\.0) { try validate(path) }
        // Parse metadata before deleting credentials so malformed settings cannot cause a partial logout.
        let updates = try metadata.compactMap { path, key -> (URL, Data)? in
            let url = home.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            guard var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
                throw Failure.unsupported
            }
            json.removeValue(forKey: key)
            return (url, try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]))
        }
        if providerID == "codex" {
            // The native CLI owns file/keyring cleanup and token revocation.
            try signOutCodex()
            return
        }
        if providerID == "claude" { try removeClaudeKeychain() }
        for path in files {
            let url = home.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            guard !FileManager.default.fileExists(atPath: url.path) else { throw Failure.unsafePath }
        }
        for (url, data) in updates {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            guard try Data(contentsOf: url) == data else { throw Failure.unsafePath }
        }
    }

    private func validate(_ path: String) throws {
        let url = home.appendingPathComponent(path)
        guard url.resolvingSymlinksInPath().path == home.resolvingSymlinksInPath().appendingPathComponent(path).path else {
            throw Failure.unsafePath
        }
    }
}
