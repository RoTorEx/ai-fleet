import AppKit
import Combine
import CryptoKit
import Foundation

struct ClaudeProfile: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    // nil is the existing default CLI profile; stored paths retain the exact Keychain selector.
    let configDirectory: String?

    static let defaultID = "default"
    static let current = ClaudeProfile(id: defaultID, name: "Claude", configDirectory: nil)
    var statusID: String { id == Self.defaultID ? "claude" : "claude:\(id)" }

    var keychainService: String {
        guard let configDirectory else { return "Claude Code-credentials" }
        let digest = SHA256.hash(data: Data(configDirectory.precomposedStringWithCanonicalMapping.utf8))
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-\(hash.prefix(8))"
    }

    // Environment overrides must not silently select a different subscription.
    static let authOverrideKeys = [
        "CLAUDE_CONFIG_DIR", "CLAUDE_SECURESTORAGE_CONFIG_DIR", "CLAUDE_CODE_OAUTH_TOKEN",
        "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_PROFILE",
        "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY"
    ]

    func environment(inheriting source: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = source
        for key in Self.authOverrideKeys { environment.removeValue(forKey: key) }
        if let configDirectory { environment["CLAUDE_CONFIG_DIR"] = configDirectory }
        return environment
    }

    func status(from status: ProviderStatus, account: ProviderAccountIdentity?) -> ProviderStatus {
        ProviderStatus(id: statusID, name: name, state: status.state, detail: status.detail,
                       lastUpdated: status.lastUpdated, remainingPercent: status.remainingPercent,
                       windowLabel: status.windowLabel, resetAt: status.resetAt, limitWindows: status.limitWindows,
                       providerID: "claude", account: account,
                       notificationScope: "claude.\(id).\(account?.scope ?? "unidentified")")
    }
}

enum ClaudeProfileLaunch {
    static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func appleScriptString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
    static func command(profile: ClaudeProfile, executable: URL, directory: URL, login: Bool) -> String {
        let unset = ClaudeProfile.authOverrideKeys.map { "-u " + shellQuote($0) }.joined(separator: " ")
        let selector = profile.configDirectory.map { " " + shellQuote("CLAUDE_CONFIG_DIR=" + $0) } ?? ""
        let arguments = login ? " auth login" : ""
        return "cd \(shellQuote(directory.path)) && /usr/bin/env \(unset)\(selector) \(shellQuote(executable.path))\(arguments)"
    }
}
