import Foundation

struct ProviderLimitWindow: Identifiable, Equatable {
    let id: String
    let label: String
    let remainingPercent: Int
    let resetAt: Date?
    let usedCount: Int?
    let limitCount: Int?
    let unit: String?

    init(
        id: String,
        label: String,
        remainingPercent: Int,
        resetAt: Date?,
        usedCount: Int? = nil,
        limitCount: Int? = nil,
        unit: String? = nil
    ) {
        self.id = id
        self.label = label
        self.remainingPercent = remainingPercent
        self.resetAt = resetAt
        self.usedCount = usedCount
        self.limitCount = limitCount
        self.unit = unit
    }
}

struct ProviderStatus: Identifiable, Equatable {
    let id: String
    let providerID: String
    let name: String
    let state: State
    let detail: String
    let lastUpdated: Date?
    let remainingPercent: Int?
    let windowLabel: String?
    let resetAt: Date?
    let limitWindows: [ProviderLimitWindow]
    let account: ProviderAccountIdentity?
    let notificationScope: String
    let quotaNotice: String?
    let authentication: Authentication
    let quotaState: QuotaState

    init(
        id: String,
        name: String,
        state: State,
        detail: String,
        lastUpdated: Date?,
        remainingPercent: Int? = nil,
        windowLabel: String? = nil,
        resetAt: Date? = nil,
        limitWindows: [ProviderLimitWindow] = [],
        providerID: String? = nil,
        account: ProviderAccountIdentity? = nil,
        notificationScope: String? = nil,
        quotaNotice: String? = nil,
        authentication: Authentication? = nil,
        quotaState: QuotaState? = nil
    ) {
        self.id = id
        self.providerID = providerID ?? id
        self.name = name
        self.state = state
        self.detail = detail
        self.lastUpdated = lastUpdated
        self.remainingPercent = remainingPercent
        self.windowLabel = windowLabel
        self.resetAt = resetAt
        self.limitWindows = limitWindows
        self.account = account
        self.notificationScope = notificationScope ?? id
        self.quotaNotice = quotaNotice
        self.authentication = authentication ?? {
            switch state {
            case .ok, .limited: return .signedIn
            case .noKey: return .signInRequired
            case .offline: return .unknown
            case .notInstalled: return .notInstalled
            }
        }()
        self.quotaState = quotaState ?? {
            if quotaNotice != nil { return remainingPercent == nil ? .unavailable : .stale }
            if let remainingPercent { return remainingPercent <= 0 ? .exhausted : .available }
            return state == .offline && lastUpdated != nil ? .unavailable : .unknown
        }()
    }

    enum State: Equatable {
        case ok
        case limited
        case offline
        case noKey
        case notInstalled
    }

    enum Authentication: Equatable {
        case signedIn, signInRequired, accessDenied, unknown, notInstalled

        var marker: String {
            switch self {
            case .signedIn: return "○"
            case .signInRequired, .accessDenied: return "×"
            case .unknown: return "?"
            case .notInstalled: return "-"
            }
        }
        var needsAccess: Bool { self == .signInRequired || self == .accessDenied }
    }

    enum QuotaState: Equatable {
        case available, exhausted, stale, unavailable, unsupported, unknown
    }

    var hasCurrentQuota: Bool {
        authentication == .signedIn && quotaNotice == nil && remainingPercent != nil &&
            (quotaState == .available || quotaState == .exhausted)
    }

    var isInstalled: Bool {
        state != .notInstalled
    }

    func withAccount(_ identity: ProviderAccountIdentity?) -> ProviderStatus {
        ProviderStatus(id: id, name: name, state: state, detail: detail, lastUpdated: lastUpdated,
                       remainingPercent: remainingPercent, windowLabel: windowLabel, resetAt: resetAt,
                       limitWindows: limitWindows, providerID: providerID, account: identity,
                       notificationScope: notificationScope, quotaNotice: quotaNotice,
                       authentication: authentication, quotaState: quotaState)
    }

    func withQuotaNotice(_ notice: String) -> ProviderStatus {
        ProviderStatus(id: id, name: name, state: state, detail: detail, lastUpdated: lastUpdated,
                       remainingPercent: remainingPercent, windowLabel: windowLabel, resetAt: resetAt,
                       limitWindows: limitWindows, providerID: providerID, account: account,
                       notificationScope: notificationScope, quotaNotice: notice,
                       authentication: authentication, quotaState: remainingPercent == nil ? .unavailable : .stale)
    }
    func withAuthentication(_ authentication: Authentication) -> ProviderStatus {
        ProviderStatus(id: id, name: name, state: state, detail: detail, lastUpdated: lastUpdated,
                       remainingPercent: remainingPercent, windowLabel: windowLabel, resetAt: resetAt,
                       limitWindows: limitWindows, providerID: providerID, account: account,
                       notificationScope: notificationScope, quotaNotice: quotaNotice,
                       authentication: authentication, quotaState: quotaState)
    }

}

func durationSeconds(for label: String) -> Double? {
    guard label.count >= 2,
          let value = Double(label.dropLast()) else {
        return nil
    }

    switch label.suffix(1) {
    case "s":
        return value
    case "m":
        return value * 60
    case "h":
        return value * 60 * 60
    case "d":
        return value * 60 * 60 * 24
    default:
        return nil
    }
}

// MARK: - Kimi Open Platform (pay-as-you-go balance)

struct KimiBalanceResponse: Codable {
    let data: BalanceData?

    struct BalanceData: Codable {
        let availableBalance: Double?
    }
}

// MARK: - Kimi Code subscription usage

struct KimiCodeUsageResponse: Codable {
    let usage: UsageWindow?
    let limits: [RateLimitWindow]?

    struct UsageWindow: Codable {
        let limit: Int?
        let used: Int?
        let remaining: Int?
        let resetTime: String?

        enum CodingKeys: String, CodingKey {
            case limit
            case used
            case remaining
            case resetTime
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            limit = container.decodeLossyInt(forKey: .limit)
            used = container.decodeLossyInt(forKey: .used)
            remaining = container.decodeLossyInt(forKey: .remaining)
            resetTime = try container.decodeIfPresent(String.self, forKey: .resetTime)
        }
    }

    struct RateLimitWindow: Codable {
        let window: WindowMeta?
        let detail: UsageWindow?

        struct WindowMeta: Codable {
            let duration: Int?
            let timeUnit: String?
        }
    }
}

struct KimiCodeAuth: Codable {
    var accessToken: String?
    var refreshToken: String?
    var expiresAt: TimeInterval?
    var expiresIn: Int?
    var scope: String?
    var tokenType: String?

    var needsRefresh: Bool {
        guard let expiresAt else { return false }
        return expiresAt - Date().timeIntervalSince1970 < 120
    }
}

struct KimiOAuthRefreshResponse: Codable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int
    let scope: String?
    let tokenType: String?
}

// MARK: - Codex

struct CodexUsageResponse: Codable {
    let rateLimit: RateLimit?

    struct RateLimit: Codable {
        let primaryWindow: Window?
        let secondaryWindow: Window?
    }

    struct Window: Codable {
        let usedPercent: Double?
        let limitWindowSeconds: Double?
        let resetAt: Double?

        enum CodingKeys: String, CodingKey {
            case usedPercent
            case limitWindowSeconds
            case resetAt
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            usedPercent = container.decodeLossyDouble(forKey: .usedPercent)
            limitWindowSeconds = container.decodeLossyDouble(forKey: .limitWindowSeconds)
            resetAt = container.decodeLossyDouble(forKey: .resetAt)
        }
    }
}

struct CodexAuth: Codable {
    let accessToken: String?
    let accountId: String?
    let tokens: Tokens?

    struct Tokens: Codable {
        let accessToken: String?
        let accountId: String?
    }

    var resolvedAccessToken: String? {
        accessToken ?? tokens?.accessToken
    }

    var resolvedAccountID: String? {
        accountId ?? tokens?.accountId
    }
}

extension KeyedDecodingContainer {
    func decodeLossyInt(forKey key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return Int(value)
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Int(value)
        }
        return nil
    }

    func decodeLossyDouble(forKey key: Key) -> Double? {
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return Double(value)
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Double(value)
        }
        return nil
    }
}
