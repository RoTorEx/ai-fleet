import Foundation

struct ProviderLimitWindow: Identifiable, Equatable {
    let id: String
    let label: String
    let context: String?
    let groupID: String
    let remainingPercent: Int
    let resetAt: Date?
    let usedCount: Int?
    let limitCount: Int?
    let unit: String?

    init(
        id: String,
        label: String,
        context: String? = nil,
        groupID: String = "default",
        remainingPercent: Int,
        resetAt: Date?,
        usedCount: Int? = nil,
        limitCount: Int? = nil,
        unit: String? = nil
    ) {
        self.id = id
        self.label = label
        self.context = context
        self.groupID = groupID
        self.remainingPercent = remainingPercent
        self.resetAt = resetAt
        self.usedCount = usedCount
        self.limitCount = limitCount
        self.unit = unit
    }

    var displayLabel: String {
        context.map { "\($0) · \(label)" } ?? label
    }
}

struct ProviderStatus: Identifiable, Equatable {
    let id: String
    let name: String
    let state: State
    let detail: String
    let lastUpdated: Date?
    let remainingPercent: Int?
    let windowLabel: String?
    let resetAt: Date?
    let limitWindows: [ProviderLimitWindow]

    init(
        id: String,
        name: String,
        state: State,
        detail: String,
        lastUpdated: Date?,
        remainingPercent: Int? = nil,
        windowLabel: String? = nil,
        resetAt: Date? = nil,
        limitWindows: [ProviderLimitWindow] = []
    ) {
        self.id = id
        self.name = name
        self.state = state
        self.detail = detail
        self.lastUpdated = lastUpdated
        self.remainingPercent = remainingPercent
        self.windowLabel = windowLabel
        self.resetAt = resetAt
        self.limitWindows = limitWindows
    }

    enum State: Equatable {
        case ok
        case limited
        case offline
        case noKey
        case notInstalled
    }

    var isInstalled: Bool {
        state != .notInstalled
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
    let additionalRateLimits: [AdditionalRateLimit]?

    struct RateLimit: Codable {
        let primaryWindow: Window?
        let secondaryWindow: Window?
    }

    struct AdditionalRateLimit: Codable {
        let limitName: String?
        let meteredFeature: String?
        let rateLimit: RateLimit?
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

struct CodexLimitDescriptor {
    let id: String
    let context: String?
    let groupID: String
    let window: CodexUsageResponse.Window
}

func codexLimitDescriptors(from response: CodexUsageResponse) -> [CodexLimitDescriptor] {
    var result: [CodexLimitDescriptor] = []

    if let window = response.rateLimit?.primaryWindow {
        result.append(CodexLimitDescriptor(id: "primary", context: nil, groupID: "base", window: window))
    }
    if let window = response.rateLimit?.secondaryWindow {
        result.append(CodexLimitDescriptor(id: "secondary", context: nil, groupID: "base", window: window))
    }

    for (index, additional) in (response.additionalRateLimits ?? []).enumerated() {
        let stableName = additional.meteredFeature ?? additional.limitName ?? "limit-\(index)"
        let groupID = "additional.\(stableName)"
        let context = compactCodexLimitName(additional.limitName ?? stableName)
        if let window = additional.rateLimit?.primaryWindow {
            result.append(CodexLimitDescriptor(
                id: "\(groupID).primary",
                context: context,
                groupID: groupID,
                window: window
            ))
        }
        if let window = additional.rateLimit?.secondaryWindow {
            result.append(CodexLimitDescriptor(
                id: "\(groupID).secondary",
                context: context,
                groupID: groupID,
                window: window
            ))
        }
    }

    return result
}

private func compactCodexLimitName(_ name: String) -> String {
    guard let marker = name.range(of: "-Codex-") else { return name }
    let suffix = String(name[marker.upperBound...])
    return suffix.isEmpty ? name : suffix
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
