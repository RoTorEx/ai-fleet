import CryptoKit
import Foundation

actor ClaudeQuotaPoller {
    static let shared = ClaudeQuotaPoller()
    static let pollInterval: TimeInterval = 300
    static let maxBackoff: TimeInterval = 3600

    private struct Entry {
        let status: ProviderStatus
        let lastGood: ProviderStatus?
        let nextAttempt: Date
        let rateLimitFailures: Int
    }
    private var entries: [String: Entry] = [:]
    private var inFlight: [String: Task<ProviderStatus, Never>] = [:]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    static func key(profile: ClaudeProfile, identity: ProviderAccountIdentity?, credential: ClaudeQuotaCredential) -> String {
        // No raw tokens, emails, or organization IDs are stored as cache keys.
        let source = profile.statusID + "\n" + (identity?.scope ?? "unknown") + "\n" + credential.accessToken
        return SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func status(key: String, now: Date = Date(),
                fetch: @escaping @Sendable () async -> ClaudeQuota.Result) async -> ProviderStatus {
        if let existing = inFlight[key] { return await existing.value }
        if let entry = entries[key], now < entry.nextAttempt { return entry.status }
        let prefix = "claude.quota.retry.\(key)"
        let saved = defaults.double(forKey: prefix + ".at")
        if entries[key] == nil, saved > now.timeIntervalSince1970 {
            let deadline = Date(timeIntervalSince1970: saved)
            let failures = defaults.integer(forKey: prefix + ".failures")
            let status = paused(lastGood: nil, retryAt: deadline)
            entries[key] = Entry(status: status, lastGood: nil, nextAttempt: deadline, rateLimitFailures: failures)
            return status
        }
        // The shared request survives a cancelled menu refresh; subsequent opens join it.
        let request = Task { () -> ProviderStatus in
            let result = await fetch()
            return self.record(result, key: key, startedAt: now)
        }
        inFlight[key] = request
        let result = await request.value
        inFlight[key] = nil
        return result
    }

    private func record(_ result: ClaudeQuota.Result, key: String, startedAt: Date) -> ProviderStatus {
        let prefix = "claude.quota.retry.\(key)"
        let previous = entries[key]
        if result.rateLimited {
            let failures = min(5, (previous?.rateLimitFailures ?? defaults.integer(forKey: prefix + ".failures")) + 1)
            let delay = min(Self.maxBackoff, Self.pollInterval * pow(2, Double(failures - 1)))
            let deadline = max(startedAt.addingTimeInterval(delay), result.retryAt ?? startedAt)
            let status = paused(lastGood: previous?.lastGood, retryAt: deadline)
            entries[key] = Entry(status: status, lastGood: previous?.lastGood, nextAttempt: deadline, rateLimitFailures: failures)
            defaults.set(deadline.timeIntervalSince1970, forKey: prefix + ".at")
            defaults.set(failures, forKey: prefix + ".failures")
            return status
        }
        defaults.removeObject(forKey: prefix + ".at")
        defaults.removeObject(forKey: prefix + ".failures")
        let good = result.status.remainingPercent != nil ? result.status : nil
        entries[key] = Entry(status: result.status, lastGood: good,
                            nextAttempt: startedAt.addingTimeInterval(Self.pollInterval), rateLimitFailures: 0)
        return result.status
    }

    private func paused(lastGood: ProviderStatus?, retryAt: Date) -> ProviderStatus {
        let time = retryAt.formatted(date: .omitted, time: .shortened)
        if let lastGood {
            let measured = lastGood.lastUpdated?.formatted(date: .omitted, time: .shortened) ?? "unknown"
            return lastGood.withQuotaNotice("Last known at \(measured) · retry at \(time)")
        }
        return ProviderStatus(id: "claude", name: "Claude", state: .ok,
                              detail: "Signed in · waiting for quota", lastUpdated: nil,
                              quotaNotice: "Update paused · retry at \(time)")
    }
}
