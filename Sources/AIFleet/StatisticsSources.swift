import Foundation

/// Physical aliases collapse. Independent names never do. Logical Codex copies need a proven prefix.
func canonicalUsageFiles(_ files: [CodexLogFile]) -> [CodexLogFile] {
    var physical = Set<String>(), groups: [String: [CodexLogFile]] = [:], independent: [CodexLogFile] = []
    for file in files.sorted(by: { $0.url.path < $1.url.path }) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.url.path)
        let physicalID = attributes?[.systemFileNumber].map { "\(attributes?[.systemNumber] ?? 0):\($0)" } ?? file.url.resolvingSymlinksInPath().path
        guard physical.insert(physicalID).inserted else { continue }
        guard let handle = try? FileHandle(forReadingFrom: file.url) else {
            var unavailable = file; unavailable.issue = "Unreadable source: " + file.url.path; independent.append(unavailable); continue
        }
        let prefix = try? handle.read(upToCount: 1_048_576)
        try? handle.close()
        guard let prefix, let line = prefix.split(separator: 10).first,
              let header = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              header["type"] as? String == "session_meta",
              let payload = header["payload"] as? [String: Any], let id = payload["id"] as? String,
              UUID(uuidString: id) != nil else { independent.append(file); continue }
        groups[id, default: []].append(file)
    }
    for copies in groups.values {
        guard copies.count > 1 else { independent += copies; continue }
        let sorted = copies.sorted {
            if $0.size != $1.size { return $0.size > $1.size }
            let a = $0.url.pathComponents.contains("archived_sessions"), b = $1.url.pathComponents.contains("archived_sessions")
            return a == b ? $0.url.path < $1.url.path : !a
        }
        guard let longest = sorted.first, let data = try? Data(contentsOf: longest.url, options: .mappedIfSafe),
              sorted.dropFirst().allSatisfy({ copy in
                  guard let other = try? Data(contentsOf: copy.url, options: .mappedIfSafe) else { return false }
                  return data.starts(with: other)
              }) else {
            independent += sorted.map { file in var marked = file; marked.issue = "Conflicting transcript copies: " + file.url.path; return marked }
            continue
        }
        independent.append(longest)
    }
    return independent.sorted { $0.url.path < $1.url.path }
}

struct StatisticsProviderReport {
    let provider: String
    let accountID: String
    let identity: ConnectionIdentity
    let fetchedAt: Date?
    let accountUsage: CodexAccountUsage?
    let limits: [ProviderLimitWindow]
    let quotaAuthentication: ProviderStatus.Authentication
    let quotaState: ProviderStatus.QuotaState

    static func make(account: FleetAccount, connection: ProviderConnection, status: ProviderStatus,
                     measurement: CodexMonitoringResult? = nil) -> StatisticsProviderReport? {
        let quotaIdentity = ConnectionIdentity(status: status)
        let usageIdentity = measurement?.usage != nil ? measurement?.usageIdentity.map {
            ConnectionIdentity(email: $0.email, organizationID: $0.accountID)
        } : nil
        guard let identity = usageIdentity ?? quotaIdentity,
              identity.email == ConnectionIdentity.normalize(account.email),
              connection.verifiedIdentity.map({ $0.matches(identity) }) != false else { return nil }
        let quotaMatches = quotaIdentity.map { identity.matches($0) } ?? false
        return StatisticsProviderReport(provider: connection.providerID, accountID: account.id, identity: identity,
            fetchedAt: status.lastUpdated, accountUsage: usageIdentity == nil ? nil : measurement?.usage,
            limits: quotaMatches ? status.limitWindows : [], quotaAuthentication: quotaIdentity.map({ !identity.matches($0) }) == true ? .unknown : status.authentication,
            quotaState: quotaIdentity.map({ !identity.matches($0) }) == true ? .unknown : status.quotaState)
    }
}

extension UsageAnalyticsService {
    func providerReports(providers: Set<StatisticsProvider>? = nil) -> [StatisticsProviderReport] {
        let providers = providers ?? selectedProviders
        let accounts = AccountStore.shared.visibleAccounts
        let codex = CodexMonitoringStore.shared
        return accounts.flatMap { account in
            account.connections.compactMap { connection -> StatisticsProviderReport? in
                guard let provider = StatisticsProvider(rawValue: connection.providerID), providers.contains(provider) else { return nil }
                let result = provider == .codex ? codex.profile(for: account).flatMap { codex.results[$0.id] } : nil
                guard let status = result?.status ?? StatusService.shared.status(for: connection) else { return nil }
                return StatisticsProviderReport.make(account: account, connection: connection, status: status, measurement: result)
            }
        }
    }
}

func checkedStatisticsSum(_ values: [Int]) -> Int? {
    var total = 0
    for value in values {
        let result = total.addingReportingOverflow(max(0, value))
        guard !result.overflow else { return nil }
        total = result.partialValue
    }
    return total
}

extension CodexUsageAnalytics {
    func withUnverifiedPrices() -> CodexUsageAnalytics {
        func strip(_ totals: UsageTotals) -> UsageTotals {
            var value = totals; value.estimatedCostUSD = 0; value.costEstimateAvailable = false; value.pricedTokens = 0
            return value
        }
        var result = self
        result.total = strip(total); result.today = strip(today); result.sevenDays = strip(sevenDays); result.thirtyDays = strip(thirtyDays)
        for i in result.models.indices { result.models[i].totals = strip(result.models[i].totals) }
        for i in result.daily.indices { result.daily[i].totals = strip(result.daily[i].totals) }
        for i in result.dailyModels.indices { result.dailyModels[i].totals = strip(result.dailyModels[i].totals) }
        return result
    }
}

func statisticsProvider(for path: String) -> StatisticsProvider {
    let url = URL(fileURLWithPath: path)
    if let provider = LocalUsageProvider.allCases.first(where: { $0.contains(url) }), let result = StatisticsProvider(rawValue: provider.rawValue) { return result }
    return ClaudeUsageLogReader.isClaudeLog(url) ? .claude : .codex
}

func malformedAccountingLine(_ line: String, kinds: Set<String>) -> Bool {
    guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return true }
    return (object["type"] as? String).map(kinds.contains) ?? false
}
