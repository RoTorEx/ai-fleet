import CryptoKit
import Foundation

/// Antigravity CLI keeps its Google sign-in in the login Keychain, service `gemini`, account
/// `antigravity`. go-keyring stores it as `go-keyring-base64:` and Base64 of a JSON record.
struct AntigravityLoginSnapshot: Equatable {
    let auth: LocalProviderAuth
    var accessToken: String? = nil
    var email: String? = nil
    var expired = false

    static func read(now: Date = Date()) -> Self {
        guard let result = LocalCommandReader.read(
            executableURL: URL(fileURLWithPath: "/usr/bin/security"),
            arguments: ["find-generic-password", "-s", "gemini", "-a", "antigravity", "-w"]) else {
            return Self(auth: .unknown)
        }
        // 44 is errSecItemNotFound: the CLI has never signed in, or signed out.
        guard result.exitCode == 0 else { return Self(auth: result.exitCode == 44 ? .signedOut : .unknown) }
        return decode(result.data, now: now)
    }

    static func decode(_ data: Data, now: Date) -> Self {
        struct Record: Decodable {
            struct Token: Decodable {
                let access_token: String?
                let refresh_token: String?
                let expiry: String?
            }
            let token: Token?
            let id_token_email: String?
        }
        let raw = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "go-keyring-base64:"
        let payload = raw.hasPrefix(prefix) ? Data(base64Encoded: String(raw.dropFirst(prefix.count))) : Data(raw.utf8)
        guard let payload, let record = try? JSONDecoder().decode(Record.self, from: payload) else {
            return Self(auth: .unknown)
        }
        let access = record.token?.access_token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let refresh = record.token?.refresh_token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let expired = record.token?.expiry.flatMap(date).map { $0 <= now } ?? false
        // Only the CLI renews the hourly access token. A refresh token alone proves no access.
        let auth: LocalProviderAuth = !access.isEmpty && !expired ? .signedIn : (!refresh.isEmpty ? .unknown : .signedOut)
        return Self(auth: auth, accessToken: access.isEmpty || expired ? nil : access,
                    email: record.id_token_email, expired: expired)
    }

    /// Go writes the expiry with nanoseconds and a zone offset; the fraction is dropped.
    static func date(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression))
    }
}

enum AntigravityQuota {
    private static let liveSession = URLSession(configuration: .ephemeral, delegate: AntigravityRedirectGuard(),
                                               delegateQueue: nil)
    /// The host Antigravity CLI 1.5.15 itself calls.
    static let endpoint = "https://daily-cloudcode-pa.googleapis.com/v1internal:"

    static func status(_ detail: String, auth: ProviderStatus.Authentication = .unknown,
                       account: ProviderAccountIdentity? = nil, reason: ProviderStatus.QuotaFailure? = nil) -> ProviderStatus {
        ProviderStatus(id: "antigravity", name: "Antigravity", state: auth == .signInRequired ? .noKey : .offline,
                       detail: detail, lastUpdated: Date(), account: account, authentication: auth,
                       quotaState: auth == .signedIn ? .unavailable : .unknown, quotaFailure: reason)
    }

    static func check(read: @escaping @Sendable () -> AntigravityLoginSnapshot = { .read() }) async -> ProviderStatus {
        let snapshot = await Task.detached(priority: .utility) { read() }.value
        let account = ProviderAccountIdentity(email: snapshot.email, organizationID: nil, organizationName: nil, subscriptionType: nil)
        switch snapshot.auth {
        case .signedOut: return status("Sign in required", auth: .signInRequired, account: account)
        case .unknown:
            return status(snapshot.expired ? "Open agy to renew sign-in" : "Auth status unknown", account: account,
                          reason: snapshot.expired ? .credentialsExpired : .identityUnverified)
        case .signedIn: break // Locally usable credential; server identity still needs verification.
        }
        guard let token = snapshot.accessToken else { return status("Sign in required", account: account) }
        let key = "antigravity:" + SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
        return await GeminiQuotaPoller.shared.status(key: key) { await fetch(token: token, cachedEmail: snapshot.email) }
    }

    static func fetch(token: String, cachedEmail: String? = nil, session: URLSession = liveSession) async -> GeminiQuota.Result {
        typealias Result = GeminiQuota.Result
        var identity = cachedEmail.map {
            ProviderAccountIdentity(email: $0, organizationID: nil, organizationName: nil, subscriptionType: nil)
        }
        var identityConfirmed = false
        do {
            // Check the token's actual email instead of attributing quota to the stored label.
            let user = try await GeminiQuota.request(url: URL(string: "https://www.googleapis.com/oauth2/v2/userinfo")!,
                                                     token: token, body: nil, session: session)
            guard let email = user["email"] as? String, !email.isEmpty else {
                return Result(status: status("Sign in required", account: identity))
            }
            identityConfirmed = true
            identity = ProviderAccountIdentity(email: email, organizationID: nil, organizationName: nil, subscriptionType: nil)
            // Plan and project are labels here. The model list is requested even without them.
            var project: String?
            do {
                let load = try await GeminiQuota.request(url: URL(string: endpoint + "loadCodeAssist")!, token: token,
                    body: ["metadata": ["ideType": "IDE_UNSPECIFIED", "platform": "PLATFORM_UNSPECIFIED", "pluginType": "GEMINI"]],
                    session: session)
                let tier = load["paidTier"] as? [String: Any] ?? load["currentTier"] as? [String: Any]
                project = load["cloudaicompanionProject"] as? String
                    ?? (load["cloudaicompanionProject"] as? [String: Any])?["id"] as? String
                identity = ProviderAccountIdentity(email: email, organizationID: project, organizationName: nil,
                                                   subscriptionType: tier?["name"] as? String ?? tier?["id"] as? String)
            } catch let failure as GeminiQuota.RequestFailure where failure.code != 401 && failure.code != 429 {}
            let models = try await GeminiQuota.request(url: URL(string: endpoint + "fetchAvailableModels")!, token: token,
                                                       body: project.map { ["project": $0] } ?? [:], session: session)
            return Result(status: try decode(JSONSerialization.data(withJSONObject: models), account: identity))
        } catch let failure as GeminiQuota.RequestFailure {
            if failure.code != 401 && !identityConfirmed {
                return Result(status: status("Sign in required", account: identity),
                              retryAt: failure.code == 429 ? failure.retryAt ?? Date().addingTimeInterval(300) : nil)
            }
            switch failure.code {
            case 401: return Result(status: status("Sign in required", auth: .signInRequired, account: identity))
            case 403: return Result(status: status("Signed in · quota access denied", auth: .signedIn, account: identity, reason: .accessDenied))
            case 429: return Result(status: status("Signed in · quota update paused", auth: .signedIn, account: identity, reason: .rateLimited),
                                   retryAt: failure.retryAt ?? Date().addingTimeInterval(300))
            default: return Result(status: status("Signed in · quota unavailable", auth: .signedIn, account: identity))
            }
        } catch {
            return Result(status: status(identityConfirmed ? "Signed in · quota unavailable" : "Sign in required",
                                         auth: identityConfirmed ? .signedIn : .unknown, account: identity,
                                         reason: error is DecodingError ? .invalidResponse : .network))
        }
    }

    /// `fetchAvailableModels` maps a model id to its details. Each model carries its own quota:
    /// `quotaInfo.remainingFraction` in [0,1] and `quotaInfo.resetTime`. The response is proto3
    /// JSON, which leaves out a zero, so a quota with a reset time and no fraction is spent.
    static func decode(_ data: Data, account: ProviderAccountIdentity?, now: Date = Date()) throws -> ProviderStatus {
        struct QuotaInfo: Decodable { let remainingFraction: Double?; let resetTime: String? }
        struct Model: Decodable { let displayName: String?; let quotaInfo: QuotaInfo?; let disabled: Bool? }
        struct Response: Decodable { let models: [String: Model]? }
        let response = try JSONDecoder().decode(Response.self, from: data)
        var families: [String: [ProviderLimitWindow]] = [:]
        for (id, model) in response.models ?? [:] where model.disabled != true {
            guard let quota = model.quotaInfo else { continue }
            let reset = quota.resetTime.flatMap(AntigravityLoginSnapshot.date)
            guard let remaining = quota.remainingFraction ?? (reset == nil ? nil : 0),
                  remaining.isFinite, (0...1).contains(remaining) else { continue }
            let name = model.displayName.flatMap { $0.isEmpty ? nil : $0 } ?? id
            families[family(name), default: []].append(ProviderLimitWindow(
                id: id, label: name, remainingPercent: Int((remaining * 100).rounded()), resetAt: reset))
        }
        // "Gemini 3.8 Flash (High)", "(Medium)" and "(Low)" draw on one quota: one line when they agree.
        let windows = families.flatMap { family, variants -> [ProviderLimitWindow] in
            let sorted = variants.sorted { $0.id < $1.id }
            guard let first = sorted.first, sorted.count > 1,
                  sorted.allSatisfy({ $0.remainingPercent == first.remainingPercent && $0.resetAt == first.resetAt }) else {
                return sorted
            }
            return [ProviderLimitWindow(id: first.id, label: family, remainingPercent: first.remainingPercent, resetAt: first.resetAt)]
        }.sorted { ($0.label, $0.id) < ($1.label, $1.id) }
        guard let lowest = windows.min(by: { $0.remainingPercent < $1.remainingPercent }) else {
            return status("Signed in · no quota data", auth: .signedIn, account: account)
        }
        return ProviderStatus(id: "antigravity", name: "Antigravity", state: lowest.remainingPercent <= 10 ? .limited : .ok,
            detail: "\(lowest.remainingPercent)% left", lastUpdated: now, remainingPercent: lowest.remainingPercent,
            windowLabel: lowest.label, resetAt: lowest.resetAt, limitWindows: windows, account: account,
            authentication: .signedIn)
    }

    /// A display name without its closing parenthetical: the thinking level of one model.
    static func family(_ name: String) -> String {
        guard name.hasSuffix(")"), let open = name.lastIndex(of: "(") else { return name }
        let base = name[..<open].trimmingCharacters(in: .whitespaces)
        return base.isEmpty ? name : base
    }
}

private final class AntigravityRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
