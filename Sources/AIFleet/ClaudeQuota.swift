import Foundation

struct ClaudeQuotaCredential {
    let accessToken: String
    let expiresAt: Date?

    static func decode(_ data: Data, now: Date = Date()) -> ClaudeQuotaCredential? {
        struct OAuth: Decodable {
            let accessToken: String
            let expiresAt: Double?
            let scopes: [String]?
        }
        struct Credentials: Decodable { let claudeAiOauth: OAuth? }
        guard let oauth = try? JSONDecoder().decode(Credentials.self, from: data).claudeAiOauth,
              !oauth.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              oauth.scopes?.contains("user:profile") != false else { return nil }
        let expiry = oauth.expiresAt.map { Date(timeIntervalSince1970: $0 / 1000) }
        guard expiry.map({ $0 > now }) ?? true else { return nil }
        return ClaudeQuotaCredential(accessToken: oauth.accessToken, expiresAt: expiry)
    }

    static func read(snapshot: ClaudeAuthSnapshot) -> ClaudeQuotaCredential? {
        guard snapshot.auth == .signedIn, snapshot.authMethod == "claude.ai" else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let defaultDirectory = home.appendingPathComponent(".claude")
        let directory = snapshot.configDirectory.map { URL(fileURLWithPath: $0) } ?? defaultDirectory
        if let data = try? Data(contentsOf: directory.appendingPathComponent(".credentials.json")),
           let credential = decode(data) { return credential }
        // A custom profile must never borrow the default account's Keychain token.
        guard directory.standardizedFileURL == defaultDirectory.standardizedFileURL,
              let result = LocalCommandReader.read(
                executableURL: URL(fileURLWithPath: "/usr/bin/security"),
                arguments: ["find-generic-password", "-s", "Claude Code-credentials", "-w"]),
              result.exitCode == 0 else { return nil }
        return decode(result.data)
    }
}

enum ClaudeQuota {
    private static let liveSession = URLSession(configuration: .ephemeral, delegate: ClaudeQuotaRedirectGuard(),
                                               delegateQueue: nil)
    static func unavailable(_ detail: String, state: ProviderStatus.State = .offline) -> ProviderStatus {
        ProviderStatus(id: "claude", name: "Claude", state: state, detail: detail, lastUpdated: Date())
    }

    static func decode(_ data: Data, now: Date = Date()) throws -> ProviderStatus {
        struct Window: Decodable { let utilization: Double?; let resets_at: String? }
        struct Usage: Decodable {
            let five_hour: Window?
            let seven_day: Window?
        }
        let usage = try JSONDecoder().decode(Usage.self, from: data)
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        let windows = [("five_hour", "5h", usage.five_hour), ("seven_day", "7d", usage.seven_day)]
            .compactMap { id, label, window -> ProviderLimitWindow? in
                guard let window, let used = window.utilization, used.isFinite,
                      (0...100).contains(used) else { return nil }
                let reset = window.resets_at.flatMap { fractional.date(from: $0) ?? plain.date(from: $0) }
                return ProviderLimitWindow(id: id, label: label,
                                           remainingPercent: Int((100 - used).rounded()), resetAt: reset)
            }
        guard let selected = windows.min(by: { $0.remainingPercent < $1.remainingPercent }) else {
            return unavailable("Signed in · no quota data", state: .ok)
        }
        return ProviderStatus(id: "claude", name: "Claude",
                              state: selected.remainingPercent <= 10 ? .limited : .ok,
                              detail: "\(selected.remainingPercent)% left", lastUpdated: now,
                              remainingPercent: selected.remainingPercent, windowLabel: selected.label,
                              resetAt: selected.resetAt, limitWindows: windows)
    }

    static func fetch(credential: ClaudeQuotaCredential, session: URLSession = liveSession) async -> ProviderStatus {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return unavailable("Quota unavailable") }
            switch http.statusCode {
            case 200: return try decode(data)
            case 401: return unavailable("Sign in required", state: .noKey)
            case 403: return unavailable("Signed in · quota access denied")
            case 429: return unavailable("Quota refresh rate limited")
            default: return unavailable("Quota unavailable")
            }
        } catch {
            return unavailable("Quota unavailable")
        }
    }
}

private final class ClaudeQuotaRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
