import CryptoKit
import Foundation

struct GeminiLoginSnapshot {
    let auth: LocalProviderAuth
    let accessToken: String?
    let email: String?
    let expired: Bool
    let supported: Bool

    static func read(home: URL = FileManager.default.homeDirectoryForCurrentUser, now: Date = Date()) -> Self {
        let folder = home.appendingPathComponent(".gemini")
        let settingsURL = folder.appendingPathComponent("settings.json")
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            guard let data = try? Data(contentsOf: settingsURL),
                  let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return Self(auth: .unknown, accessToken: nil, email: nil, expired: false, supported: true)
            }
            let security = settings["security"] as? [String: Any]
            let auth = security?["auth"] as? [String: Any]
            if let type = auth?["selectedType"] as? String, type != "oauth-personal" {
                return Self(auth: .unknown, accessToken: nil, email: nil, expired: false, supported: false)
            }
        }
        let accounts = (try? Data(contentsOf: folder.appendingPathComponent("google_accounts.json")))
            .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        let email = accounts?["active"] as? String
        let url = folder.appendingPathComponent("oauth_creds.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Self(auth: email == nil ? .signedOut : .unknown, accessToken: nil, email: nil, expired: false, supported: true)
        }
        guard let data = try? Data(contentsOf: url) else {
            return Self(auth: .unknown, accessToken: nil, email: nil, expired: false, supported: true)
        }
        return decode(data, email: email, now: now)
    }

    static func decode(_ data: Data, email: String?, now: Date) -> Self {
        struct Credentials: Decodable {
            let access_token: String?
            let refresh_token: String?
            let expiry_date: Double?
        }
        guard let value = try? JSONDecoder().decode(Credentials.self, from: data) else {
            return Self(auth: .unknown, accessToken: nil, email: nil, expired: false, supported: true)
        }
        let access = value.access_token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let refresh = value.refresh_token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let expired = value.expiry_date.map { $0 <= now.timeIntervalSince1970 * 1000 } ?? false
        let auth: LocalProviderAuth = !refresh.isEmpty || (!access.isEmpty && !expired) ? .signedIn : .signedOut
        return Self(auth: auth, accessToken: access.isEmpty || expired ? nil : access, email: email,
                    expired: expired, supported: true)
    }
}

enum GeminiQuota {
    private static let liveSession = URLSession(configuration: .ephemeral, delegate: GeminiRedirectGuard(), delegateQueue: nil)
    static let endpoint = "https://cloudcode-pa.googleapis.com/v1internal:"

    static func status(_ detail: String, auth: ProviderStatus.Authentication = .signedIn,
                       account: ProviderAccountIdentity? = nil) -> ProviderStatus {
        ProviderStatus(id: "gemini", name: "Gemini", state: auth == .signInRequired ? .noKey : .offline,
                       detail: detail, lastUpdated: Date(), account: account, authentication: auth,
                       quotaState: auth == .signedIn ? .unavailable : .unknown)
    }

    static func check(home: URL = FileManager.default.homeDirectoryForCurrentUser) async -> ProviderStatus {
        let snapshot = await Task.detached(priority: .utility) { GeminiLoginSnapshot.read(home: home) }.value
        guard snapshot.supported else { return status("API/Vertex login · quota unsupported", auth: .unknown) }
        switch snapshot.auth {
        case .signedOut: return status("Sign in required", auth: .signInRequired)
        case .unknown: return status("Auth status unknown", auth: .unknown)
        case .signedIn: break
        }
        let account = ProviderAccountIdentity(email: snapshot.email, organizationID: nil, organizationName: nil, subscriptionType: nil)
        guard let token = snapshot.accessToken else {
            return status(snapshot.expired ? "Open Gemini to refresh credentials" : "Signed in · quota unavailable", account: account)
        }
        let key = SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
        return await GeminiQuotaPoller.shared.status(key: key) { await fetch(token: token, cachedEmail: snapshot.email) }
    }

    struct Result {
        let status: ProviderStatus
        var retryAt: Date? = nil
    }
    private struct RequestFailure: Error { let code: Int; let retryAt: Date? }

    static func fetch(token: String, cachedEmail: String? = nil, session: URLSession = liveSession) async -> Result {
        var identity = cachedEmail.map {
            ProviderAccountIdentity(email: $0, organizationID: nil, organizationName: nil, subscriptionType: nil)
        }
        do {
            // Check the token's actual email instead of attributing quota to a stale cached label.
            let user = try await request(url: URL(string: "https://www.googleapis.com/oauth2/v2/userinfo")!,
                                         token: token, body: nil, session: session)
            guard let email = user["email"] as? String, !email.isEmpty else {
                return Result(status: status("Signed in · account identity unavailable"))
            }
            identity = ProviderAccountIdentity(email: email, organizationID: nil, organizationName: nil, subscriptionType: nil)
            let load = try await request(url: URL(string: endpoint + "loadCodeAssist")!, token: token,
                body: ["metadata": ["ideType": "IDE_UNSPECIFIED", "platform": "PLATFORM_UNSPECIFIED", "pluginType": "GEMINI"]], session: session)
            let tier = load["paidTier"] as? [String: Any] ?? load["currentTier"] as? [String: Any]
            let project = load["cloudaicompanionProject"] as? String
                ?? (load["cloudaicompanionProject"] as? [String: Any])?["id"] as? String
            identity = ProviderAccountIdentity(email: email, organizationID: project, organizationName: nil,
                                               subscriptionType: tier?["name"] as? String ?? tier?["id"] as? String)
            guard let project, !project.isEmpty else {
                return Result(status: status("Complete Gemini CLI project setup", account: identity))
            }
            let quota = try await request(url: URL(string: endpoint + "retrieveUserQuota")!, token: token,
                                          body: ["project": project], session: session)
            return Result(status: try decode(JSONSerialization.data(withJSONObject: quota), account: identity))
        } catch let failure as RequestFailure {
            switch failure.code {
            case 401: return Result(status: status("Sign in required", auth: .signInRequired, account: identity))
            case 403: return Result(status: status("Signed in · quota access denied", account: identity))
            case 429: return Result(status: status("Signed in · quota update paused", account: identity),
                                   retryAt: failure.retryAt ?? Date().addingTimeInterval(300))
            default: return Result(status: status("Signed in · quota unavailable", account: identity))
            }
        } catch { return Result(status: status("Signed in · quota unavailable", account: identity)) }
    }

    private static func request(url: URL, token: String, body: [String: Any]?, session: URLSession) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw RequestFailure(code: 0, retryAt: nil) }
        guard response.statusCode == 200 else {
            throw RequestFailure(code: response.statusCode,
                                 retryAt: ClaudeQuota.retryDate(response.value(forHTTPHeaderField: "Retry-After"), now: Date()))
        }
        guard let value = (try JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw RequestFailure(code: 0, retryAt: nil)
        }
        return value
    }

    static func decode(_ data: Data, account: ProviderAccountIdentity?, now: Date = Date()) throws -> ProviderStatus {
        struct Bucket: Decodable { let modelId: String?; let remainingFraction: Double?; let resetTime: String? }
        struct Quota: Decodable { let buckets: [Bucket]? }
        let quota = try JSONDecoder().decode(Quota.self, from: data)
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var models: [String: ProviderLimitWindow] = [:]
        for bucket in quota.buckets ?? [] {
            guard let model = bucket.modelId, !model.isEmpty, let remaining = bucket.remainingFraction,
                  remaining.isFinite, (0...1).contains(remaining) else { continue }
            let percent = Int((remaining * 100).rounded())
            if let previous = models[model], previous.remainingPercent <= percent { continue }
            models[model] = ProviderLimitWindow(id: model, label: model, remainingPercent: percent,
                resetAt: bucket.resetTime.flatMap { fractional.date(from: $0) ?? plain.date(from: $0) })
        }
        let windows = models.values.sorted { $0.id < $1.id }
        guard let lowest = windows.min(by: { $0.remainingPercent < $1.remainingPercent }) else {
            return status("Signed in · no quota data", account: account)
        }
        return ProviderStatus(id: "gemini", name: "Gemini", state: lowest.remainingPercent <= 10 ? .limited : .ok,
            detail: "\(lowest.remainingPercent)% left", lastUpdated: now, remainingPercent: lowest.remainingPercent,
            windowLabel: lowest.label, resetAt: lowest.resetAt, limitWindows: windows, account: account,
            authentication: .signedIn)
    }
}

actor GeminiQuotaPoller {
    static let shared = GeminiQuotaPoller()
    private var entries: [String: (status: ProviderStatus, next: Date)] = [:]
    private var inFlight: [String: Task<ProviderStatus, Never>] = [:]
    func status(key: String, now: Date = Date(), fetch: @escaping @Sendable () async -> GeminiQuota.Result) async -> ProviderStatus {
        if let task = inFlight[key] { return await task.value }
        if let entry = entries[key], now < entry.next { return entry.status }
        let task = Task { () -> ProviderStatus in
            let result = await fetch()
            let next = max(now.addingTimeInterval(300), result.retryAt ?? now)
            entries[key] = (result.status, next)
            return result.status
        }
        inFlight[key] = task
        let value = await task.value
        inFlight[key] = nil
        return value
    }
}

private final class GeminiRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
