import Darwin
import Foundation

struct CodexJournalHeader: Codable, Equatable {
    let sessionID: UUID?
}

func discoverUsageLogs(in roots: [URL], accepts: (URL) -> Bool = { _ in true }) -> [CodexLogFile] {
    let manager = FileManager.default
    var files: [CodexLogFile] = []
    for root in roots {
        guard let enumerator = manager.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]) else {
            if manager.fileExists(atPath: root.path) {
                files.append(CodexLogFile(url: root, modifiedAt: .distantPast, size: 0,
                                          issue: "Unreadable history root: " + root.path))
            }
            continue
        }
        for case let url as URL in enumerator where url.pathExtension == "jsonl" && accepts(url) {
            if let file = autoreleasepool(invoking: { usageLogMetadata(url) }) { files.append(file) }
        }
    }
    return files
}

private func usageLogMetadata(_ url: URL) -> CodexLogFile? {
    guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]),
          values.isRegularFile == true else { return nil }
    var attributes = stat()
    let found = url.withUnsafeFileSystemRepresentation { path in
        path.map { fstatat(AT_FDCWD, $0, &attributes, 0) == 0 } ?? false
    }
    let identity = found ? "\(attributes.st_dev):\(attributes.st_ino):\(attributes.st_birthtimespec.tv_sec).\(attributes.st_birthtimespec.tv_nsec)" : nil
    let change = found ? Double(attributes.st_ctimespec.tv_sec) + Double(attributes.st_ctimespec.tv_nsec) / 1e9 : nil
    let issue = FileManager.default.isReadableFile(atPath: url.path) ? nil : "Unreadable source: " + url.path
    return CodexLogFile(url: url, modifiedAt: values.contentModificationDate ?? .distantPast,
                       size: values.fileSize ?? 0, issue: issue, identity: identity, changeEpoch: change)
}

/// Physical aliases collapse. Independent names never do. Logical Codex copies need a proven prefix.
func canonicalUsageFiles(_ files: [CodexLogFile], codexCopies: Bool,
                         known: [String: CodexFileUsageRecord] = [:]) -> [CodexLogFile] {
    var physical = Set<String>(), groups: [UUID: [CodexLogFile]] = [:], independent: [CodexLogFile] = []
    for var file in files.sorted(by: { $0.url.path < $1.url.path }) {
        guard physical.insert(file.identity ?? file.url.resolvingSymlinksInPath().path).inserted else { continue }
        if codexCopies && file.issue == nil {
            if let record = known[file.url.path], let header = record.codexHeader, record.matchesMetadata(file) {
                file.codexHeader = header
            } else {
                do { file.codexHeader = try readCodexJournalHeader(file.url) }
                catch { file.issue = "Unreadable source: " + file.url.path }
            }
        }
        if let id = file.codexHeader?.sessionID {
            groups[id, default: []].append(file)
        } else {
            independent.append(file)
        }
    }
    for copies in groups.values {
        guard copies.count > 1 else { independent += copies; continue }
        let sorted = copies.sorted {
            if $0.size != $1.size { return $0.size > $1.size }
            let a = $0.url.pathComponents.contains("archived_sessions"), b = $1.url.pathComponents.contains("archived_sessions")
            return a == b ? $0.url.path < $1.url.path : !a
        }
        guard let longest = sorted.first, sorted.dropFirst().allSatisfy({ sameUsagePrefix(longest, $0) }) else {
            independent += sorted.map { file in var marked = file; marked.issue = "Conflicting transcript copies: " + file.url.path; return marked }
            continue
        }
        independent.append(longest)
    }
    return independent.sorted { $0.url.path < $1.url.path }
}

private func readCodexJournalHeader(_ url: URL) throws -> CodexJournalHeader {
    try autoreleasepool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var prefix = try handle.read(upToCount: 8 * 1024) ?? Data()
        let headerLine: Data?
        if let start = prefix.firstIndex(where: { $0 != 10 }), let end = prefix[start...].firstIndex(of: 10) {
            headerLine = prefix[start..<end]
        } else {
            if let rest = try handle.read(upToCount: 1_048_576 - prefix.count) { prefix.append(rest) }
            headerLine = prefix.split(separator: 10, maxSplits: 1).first
        }
        guard let headerLine, let header = try? JSONSerialization.jsonObject(with: headerLine) as? [String: Any],
              header["type"] as? String == "session_meta",
              let payload = header["payload"] as? [String: Any], let id = payload["id"] as? String else {
            return CodexJournalHeader(sessionID: nil)
        }
        return CodexJournalHeader(sessionID: UUID(uuidString: id))
    }
}

private func sameUsagePrefix(_ longer: CodexLogFile, _ shorter: CodexLogFile) -> Bool {
    do {
        let a = try FileHandle(forReadingFrom: longer.url)
        defer { try? a.close() }
        let b = try FileHandle(forReadingFrom: shorter.url)
        defer { try? b.close() }
        let length = try b.seekToEnd()
        guard length <= (try a.seekToEnd()), let count = Int(exactly: length) else { return false }
        try a.seek(toOffset: 0)
        try b.seek(toOffset: 0)
        try readUsageBytes(b, count: count) { data in
            guard let other = try autoreleasepool(invoking: { try a.read(upToCount: data.count) }), other == data else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        return true
    } catch {
        return false
    }
}

struct StatisticsProviderReport: Equatable {
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

extension MenuAccountConnection {
    @MainActor
    func statisticsReport(codex: CodexMonitoringStore) -> StatisticsProviderReport? {
        guard !isSetup, !account.badge.isEmpty, StatisticsProvider(rawValue: connection.providerID) != nil else { return nil }
        let result = connection.providerID == "codex" ? codex.profile(for: account).flatMap { codex.results[$0.id] } : nil
        return StatisticsProviderReport.make(account: account, connection: connection, status: status, measurement: result)
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

func malformedAccountingLine(_ line: Data, kinds: Set<String>) -> Bool {
    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return true }
    return (object["type"] as? String).map(kinds.contains) ?? false
}
