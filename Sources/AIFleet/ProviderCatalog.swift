import Foundation

struct ProviderDefinition: Identifiable, Equatable {
    let id: String
    let name: String
    let executableNames: [String]
    let credentialPaths: [String]
}

/// Kimi Code records its login slot and region in config.toml; regions use different hosts and files.
struct KimiCodeEnvironment: Equatable {
    var credentialFile = "credentials/kimi-code.json"
    var usagesURL = URL(string: "https://api.kimi.com/coding/v1/usages")!
    var tokenURL = URL(string: "https://auth.kimi.com/api/oauth/token")!

    init(root: URL) {
        guard let config = try? String(contentsOf: root.appendingPathComponent("config.toml"), encoding: .utf8) else { return }
        var section = ""
        for raw in config.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { section = line; continue }
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[1].hasPrefix("\""), let end = parts[1].dropFirst().firstIndex(of: "\"") else { continue }
            let value = String(parts[1][parts[1].index(after: parts[1].startIndex)..<end])
            switch (section, parts[0]) {
            case ("[providers.\"managed:kimi-code\"]", "base_url"):
                if let url = Self.trusted(value, hosts: ["api.kimi.com", "api.kimi.ai"]) { usagesURL = url.appendingPathComponent("usages") }
            case ("[providers.\"managed:kimi-code\".oauth]", "oauth_host"):
                if let url = Self.trusted(value, hosts: ["auth.kimi.com", "auth.kimi.ai"]) { tokenURL = url.appendingPathComponent("api/oauth/token") }
            case ("[providers.\"managed:kimi-code\".oauth]", "key"):
                let name = value.dropFirst("oauth/".count)
                if value.hasPrefix("oauth/"), !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) {
                    credentialFile = "credentials/\(name).json"
                }
            default: break
            }
        }
    }

    // Bearer tokens only ever go to Kimi's own hosts, whatever the config says.
    private static func trusted(_ value: String, hosts: Set<String>) -> URL? {
        guard let url = URL(string: value), url.scheme == "https", let host = url.host, hosts.contains(host) else { return nil }
        return url
    }
}

enum ProviderCatalog {
    static let codex = ProviderDefinition(
        id: "codex",
        name: "Codex",
        executableNames: ["codex"],
        credentialPaths: [".codex/auth.json"]
    )

    static let kimi = ProviderDefinition(
        id: "kimi",
        name: "Kimi",
        executableNames: ["kimi", "kimi-code"],
        credentialPaths: [".kimi-code/credentials/kimi-code.json"]
    )

    static let claude = ProviderDefinition(
        id: "claude",
        name: "Claude",
        executableNames: ["claude"],
        credentialPaths: [] // Claude's CLI checks its active auth source, including Keychain.
    )

    static let qwen = ProviderDefinition(
        id: "qwen",
        name: "Qwen",
        executableNames: ["qwen"],
        credentialPaths: [
            ".qwen/oauth_creds.json",
            ".qwen/credentials.json",
            ".qwen-code/oauth_creds.json",
            ".qwen-code/credentials.json",
            ".qwen-code/credentials/qwen-code.json",
            ".config/qwen/oauth_creds.json",
            ".config/qwen/credentials.json",
            ".config/qwen-code/oauth_creds.json",
            ".config/qwen-code/credentials.json"
        ]
    )

    static let gemini = ProviderDefinition(id: "gemini", name: "Gemini", executableNames: ["gemini"],
        credentialPaths: [".gemini/oauth_creds.json"])

    static let grok = ProviderDefinition(id: "grok", name: "Grok", executableNames: ["grok"],
        credentialPaths: [".grok/auth.json"])

    static let all = [codex, kimi, claude, qwen, gemini, grok]

    static var allIDs: [String] {
        all.map(\.id)
    }

    static func definition(for providerID: String) -> ProviderDefinition? {
        all.first { $0.id == providerID }
    }

    static func isInstalled(_ provider: ProviderDefinition) -> Bool {
        executableURL(for: provider) != nil
    }

    static func isInstalled(_ providerID: String) -> Bool {
        guard let provider = definition(for: providerID) else { return false }
        return isInstalled(provider)
    }

    static func executableURL(for provider: ProviderDefinition) -> URL? {
        ProviderInstallDetector.executableURL(named: provider.executableNames)
    }

    static func credentialURLs(for provider: ProviderDefinition) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return provider.credentialPaths.map { home.appendingPathComponent($0) }
    }
}

private enum ProviderInstallDetector {
    static func executableURL(named executableNames: [String]) -> URL? {
        let fileManager = FileManager.default

        for directory in executableSearchDirectories() {
            for executableName in executableNames {
                let url = directory.appendingPathComponent(executableName)
                if fileManager.isExecutableFile(atPath: url.path) &&
                    !(executableName == "codex" && CodexTerminalLaunch.isShim(url)) && !ProviderTerminalLaunch.isShim(url) {
                    return url
                }
            }
        }

        return nil
    }

    private static func executableSearchDirectories() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let common = [
            URL(fileURLWithPath: "/opt/homebrew/bin"),
            URL(fileURLWithPath: "/usr/local/bin"),
            URL(fileURLWithPath: "/usr/bin"),
            URL(fileURLWithPath: "/bin"),
            URL(fileURLWithPath: "/usr/sbin"),
            URL(fileURLWithPath: "/sbin"),
            home.appendingPathComponent(".local/bin"),
            home.appendingPathComponent(".npm-global/bin"),
            home.appendingPathComponent(".yarn/bin"),
            home.appendingPathComponent(".config/yarn/global/node_modules/.bin"),
            home.appendingPathComponent(".bun/bin"),
            home.appendingPathComponent(".volta/bin"),
            home.appendingPathComponent("Library/pnpm")
        ]

        let pathDirectories = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)) }

        var seen = Set<String>()
        return (common + pathDirectories).filter { url in
            let path = url.standardizedFileURL.path
            guard !seen.contains(path) else { return false }
            seen.insert(path)
            return true
        }
    }
}
