import Foundation

struct ProviderDefinition: Identifiable, Equatable {
    let id: String
    let name: String
    let executableNames: [String]
    let credentialPaths: [String]
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
        credentialPaths: [
            ".claude.json",
            ".claude/credentials.json",
            ".claude/.credentials.json",
            ".config/claude/credentials.json"
        ]
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

    static let all = [codex, kimi, claude, qwen]

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

    static func hasCredentialFile(for provider: ProviderDefinition) -> Bool {
        credentialURLs(for: provider).contains { url in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? NSNumber else {
                return false
            }
            return size.intValue > 0
        }
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
                if fileManager.isExecutableFile(atPath: url.path) {
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
