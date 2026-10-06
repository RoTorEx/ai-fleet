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

    static func read(snapshot: ClaudeAuthSnapshot, profile: ClaudeProfile? = nil) -> ClaudeQuotaCredential? {
        guard snapshot.auth == .signedIn, snapshot.authMethod == "claude.ai" else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let defaultDirectory = home.appendingPathComponent(".claude")
        let directory = snapshot.configDirectory.map { URL(fileURLWithPath: $0) } ?? defaultDirectory
        if let profile, let reported = snapshot.configDirectory {
            let requested = profile.configDirectory.map { URL(fileURLWithPath: $0) } ?? defaultDirectory
            guard URL(fileURLWithPath: reported).standardizedFileURL == requested.standardizedFileURL else { return nil }
        }
        if let data = try? Data(contentsOf: directory.appendingPathComponent(".credentials.json")),
           let credential = decode(data) { return credential }
        // Named profiles use only their own scoped Keychain item.
        guard profile != nil || directory.standardizedFileURL == defaultDirectory.standardizedFileURL,
              let result = LocalCommandReader.read(
                executableURL: URL(fileURLWithPath: "/usr/bin/security"),
                arguments: ["find-generic-password", "-s", profile?.keychainService ?? "Claude Code-credentials", "-w"]),
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

    struct Result {
        let status: ProviderStatus
        var rateLimited = false
        var retryAt: Date? = nil
    }

    static func fetch(credential: ClaudeQuotaCredential, session: URLSession = liveSession) async -> ProviderStatus {
        await request(credential: credential, session: session).status
    }

    static func retryDate(_ value: String?, now: Date) -> Date? {
        guard let value else { return nil }
        if let seconds = TimeInterval(value.trimmingCharacters(in: .whitespaces)), seconds.isFinite, seconds >= 0 {
            return now.addingTimeInterval(seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value)
    }

    static func request(credential: ClaudeQuotaCredential, session: URLSession = liveSession) async -> Result {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return Result(status: unavailable("Quota unavailable")) }
            switch http.statusCode {
            case 200: return Result(status: try decode(data))
            case 401: return Result(status: unavailable("Sign in required", state: .noKey))
            case 403: return Result(status: unavailable("Signed in · quota access denied"))
            case 429:
                return Result(status: unavailable("Signed in · quota update paused", state: .ok), rateLimited: true,
                              retryAt: retryDate(http.value(forHTTPHeaderField: "Retry-After"), now: Date()))
            default: return Result(status: unavailable("Quota unavailable"))
            }
        } catch {
            return Result(status: unavailable("Quota unavailable"))
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
