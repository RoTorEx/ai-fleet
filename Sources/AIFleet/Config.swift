import Foundation

struct AppConfig: Codable {
    var kimiApiKey: String?

    static let `default` = AppConfig(kimiApiKey: nil)

    private static var url: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("AI Fleet", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    private static var directoryURL: URL {
        url.deletingLastPathComponent()
    }

    private static func protectLocalCredentials() {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    static func load() -> AppConfig {
        do {
            let data = try Data(contentsOf: url)
            protectLocalCredentials()
            return try JSONDecoder().decode(AppConfig.self, from: data)
        } catch {
            return .default
        }
    }

    func save() {
        do {
            try FileManager.default.createDirectory(
                at: Self.directoryURL,
                withIntermediateDirectories: true
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: Self.directoryURL.path
            )
            let data = try JSONEncoder().encode(self)
            try data.write(to: Self.url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: Self.url.path
            )
        } catch {
            // Silent: missing config is fine.
        }
    }

    var resolvedKimiKey: String? {
        if let key = kimiApiKey, !key.isEmpty { return key }
        return ProcessInfo.processInfo.environment["KIMI_API_KEY"]
    }
}
