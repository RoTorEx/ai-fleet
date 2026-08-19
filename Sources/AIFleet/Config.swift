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

    static func load() -> AppConfig {
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(AppConfig.self, from: data)
        } catch {
            return .default
        }
    }

    func save() {
        do {
            try FileManager.default.createDirectory(
                at: Self.url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(self)
            try data.write(to: Self.url, options: .atomic)
        } catch {
            // Silent: missing config is fine.
        }
    }

    var resolvedKimiKey: String? {
        if let key = kimiApiKey, !key.isEmpty { return key }
        return ProcessInfo.processInfo.environment["KIMI_API_KEY"]
    }
}
