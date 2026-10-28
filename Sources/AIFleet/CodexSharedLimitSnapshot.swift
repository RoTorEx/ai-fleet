import Foundation

/// Historical measurements only. Never stores credentials or claims a live login.
struct CodexSharedLimitSnapshot: Codable {
    let email: String
    let measuredAt: Date
    let remaining: Int
    let windows: [ProviderLimitWindow]

    init?(status: ProviderStatus) {
        guard status.hasCurrentQuota, let email = status.account?.email,
              let date = status.lastUpdated, let remaining = status.remainingPercent else { return nil }
        self.email = email
        measuredAt = date
        self.remaining = remaining
        windows = status.limitWindows
    }

    var status: ProviderStatus {
        ProviderStatus(id: "codex", name: "Codex", state: .offline,
            detail: "Terminal account changed", lastUpdated: measuredAt,
            remainingPercent: remaining, limitWindows: windows,
            quotaNotice: "Last checked \(measuredAt.formatted(date: .abbreviated, time: .shortened)) · saved limits",
            authentication: .unknown, quotaState: .stale)
    }
}
