import CryptoKit
import Foundation
import Security

enum GLMCodingPlan {
    static let providerID = "glm"
    static let endpoint = URL(string: "https://api.z.ai/api/monitor/usage/quota/limit")!
    private static let liveSession = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)

    enum KeychainFailure: LocalizedError {
        case invalidKey, unavailable

        var errorDescription: String? {
            switch self {
            case .invalidKey: return "Enter a Z.ai Coding Plan API key."
            case .unavailable: return "Could not access the GLM API key in Keychain."
            }
        }
    }

    private static func keychainItem(_ connection: ProviderConnection) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "dev.ai-fleet.glm-coding-plan",
         kSecAttrAccount as String: connection.id]
    }

    private static func readKey(for connection: ProviderConnection) throws -> String? {
        var query = keychainItem(connection)
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        let result = SecItemCopyMatching(query as CFDictionary, &item)
        if result == errSecItemNotFound { return nil }
        guard result == errSecSuccess, let data = item as? Data, let key = String(data: data, encoding: .utf8) else {
            throw KeychainFailure.unavailable
        }
        return key
    }

    static func saveKey(_ input: String, for connection: ProviderConnection) throws {
        let key = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf8.allSatisfy({ (33...126).contains($0) }) else { throw KeychainFailure.invalidKey }
        let query = keychainItem(connection)
        let value = [kSecValueData as String: Data(key.utf8)]
        let result = SecItemUpdate(query as CFDictionary, value as CFDictionary)
        if result == errSecItemNotFound {
            let item = query.merging(value) { _, new in new }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw KeychainFailure.unavailable }
        } else if result != errSecSuccess {
            throw KeychainFailure.unavailable
        }
    }

    static func removeKey(for connection: ProviderConnection) throws {
        let result = SecItemDelete(keychainItem(connection) as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw KeychainFailure.unavailable }
    }

    static func check(_ connection: ProviderConnection) async -> ProviderStatus {
        guard !connection.isNativeDefault else { return setup }
        do {
            guard let key = try await Task.detached(priority: .utility, operation: { try readKey(for: connection) }).value else { return setup }
            let digest = SHA256.hash(data: Data(key.utf8)).description
            return await GeminiQuotaPoller.shared.status(key: "glm:\(digest)") { await fetch(key: key) }
        } catch {
            return unavailable("GLM API key unavailable", reason: .credentialsUnavailable)
        }
    }

    static var setup: ProviderStatus {
        unavailable("Add a Z.ai Coding Plan API key", auth: .signInRequired, lastUpdated: nil)
    }

    private static func unavailable(_ detail: String, auth: ProviderStatus.Authentication = .unknown,
                                    reason: ProviderStatus.QuotaFailure? = nil,
                                    account: ProviderAccountIdentity? = nil, lastUpdated: Date? = Date()) -> ProviderStatus {
        ProviderStatus(id: providerID, name: "GLM", state: auth.needsAccess ? .noKey : .offline,
                       detail: detail, lastUpdated: lastUpdated, account: account, authentication: auth,
                       quotaState: .unavailable, quotaFailure: reason)
    }

    static func fetch(key: String, session: URLSession = liveSession) async -> GeminiQuota.Result {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        // Z.ai's GLM Coding Plan usage plugin sends the key directly in Authorization.
        request.setValue(key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            return .init(status: unavailable("Quota network error", reason: .network))
        }
        guard let http = response as? HTTPURLResponse else {
            return .init(status: unavailable("Invalid quota response", reason: .invalidResponse))
        }
        if http.statusCode == 429 {
            return .init(status: unavailable("Quota requests limited", reason: .rateLimited),
                         retryAt: ClaudeQuota.retryDate(http.value(forHTTPHeaderField: "Retry-After"), now: Date()))
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            return .init(status: unavailable("Z.ai Coding Plan access denied", auth: .accessDenied))
        }
        guard http.statusCode == 200 else {
            return .init(status: unavailable("Limits unavailable", reason: .unavailable))
        }
        do {
            return .init(status: try decode(data))
        } catch {
            return .init(status: unavailable("Invalid quota response", reason: .invalidResponse))
        }
    }

    static func decode(_ data: Data, now: Date = Date()) throws -> ProviderStatus {
        struct Limit: Decodable {
            let type: String
            let unit: Int?
            let number: Int?
            let percentage: Double?
            let nextResetTime: Double?
        }
        struct Plan: Decodable {
            let level: String?
            let limits: [Limit]?
        }
        struct Response: Decodable {
            let code: Int
            let success: Bool?
            let data: Plan?
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        if response.code == 401 || response.code == 403 {
            return unavailable("Z.ai Coding Plan access denied", auth: .accessDenied)
        }
        guard response.code == 200, response.success != false, let plan = response.data else {
            return unavailable("GLM Coding Plan quota unavailable", reason: .unavailable)
        }
        let account = ProviderAccountIdentity(email: nil, organizationID: nil, organizationName: nil,
                                              subscriptionType: plan.level?.capitalized)
        var windows: [String: ProviderLimitWindow] = [:]
        for limit in plan.limits ?? [] where ["TOKENS_LIMIT", "CREDIT_LIMIT"].contains(limit.type) {
            let label: String
            switch (limit.unit, limit.number) {
            case (3, 5): label = "5h"
            case (6, 1): label = "7d"
            default: continue
            }
            guard let used = limit.percentage, (0...100).contains(used) else { continue }
            let remaining = Int((100 - used).rounded())
            if let previous = windows[label], previous.remainingPercent <= remaining { continue }
            let reset = limit.nextResetTime.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000) : nil }
            windows[label] = ProviderLimitWindow(id: label, label: label, remainingPercent: remaining, resetAt: reset)
        }
        let ordered = ["5h", "7d"].compactMap { windows[$0] }
        guard let lowest = ordered.min(by: { $0.remainingPercent < $1.remainingPercent }) else {
            return unavailable("GLM Coding Plan reported no limits", auth: .signedIn, account: account)
        }
        return ProviderStatus(id: providerID, name: "GLM", state: lowest.remainingPercent <= 10 ? .limited : .ok,
            detail: "\(lowest.remainingPercent)% left", lastUpdated: now, remainingPercent: lowest.remainingPercent,
            windowLabel: lowest.label, resetAt: lowest.resetAt, limitWindows: ordered, account: account)
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
