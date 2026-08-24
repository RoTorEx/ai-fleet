import Foundation
import Combine
@preconcurrency import UserNotifications

@MainActor
final class StatusService: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = StatusService()
    private static let kimiCodeClientID = "17e5f671-d194-4dfb-9706-5516cb48c098"

    @Published var kimi: ProviderStatus = StatusService.initialStatus(for: ProviderCatalog.kimi)
    @Published var codex: ProviderStatus = StatusService.initialStatus(for: ProviderCatalog.codex)
    @Published var claude: ProviderStatus = StatusService.initialStatus(for: ProviderCatalog.claude)
    @Published var qwen: ProviderStatus = StatusService.initialStatus(for: ProviderCatalog.qwen)
    @Published var lastError: String?
    @Published var notificationStatusText = "Checking"
    @Published var notificationsEnabled = false

    private var timer: Timer?
    private var task: Task<Void, Never>?
    private let session = URLSession(configuration: .ephemeral)
    private let config = AppConfig.load()
    private let iso8601 = ISO8601DateFormatter()
    private let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    private struct LimitCandidate {
        let id: String
        let label: String
        let remaining: Int
        let resetAt: Date?
        let usedCount: Int?
        let limitCount: Int?
        let unit: String?

        var providerWindow: ProviderLimitWindow {
            ProviderLimitWindow(
                id: id,
                label: label,
                remainingPercent: remaining,
                resetAt: resetAt,
                usedCount: usedCount,
                limitCount: limitCount,
                unit: unit
            )
        }
    }

    private override init() {
        super.init()
    }

    private static func initialStatus(for provider: ProviderDefinition) -> ProviderStatus {
        if ProviderCatalog.isInstalled(provider) {
            return ProviderStatus(
                id: provider.id,
                name: provider.name,
                state: .offline,
                detail: "Checking",
                lastUpdated: nil
            )
        }
        return notInstalledStatus(for: provider)
    }

    private static func notInstalledStatus(for provider: ProviderDefinition) -> ProviderStatus {
        ProviderStatus(
            id: provider.id,
            name: provider.name,
            state: .notInstalled,
            detail: "Not installed",
            lastUpdated: nil
        )
    }

    private static func disabledStatus(for provider: ProviderDefinition) -> ProviderStatus {
        ProviderStatus(
            id: provider.id,
            name: provider.name,
            state: .ok,
            detail: "Disabled",
            lastUpdated: nil
        )
    }

    private static func unavailableStatus(for provider: ProviderDefinition) -> ProviderStatus {
        ProviderStatus(
            id: provider.id,
            name: provider.name,
            state: .noKey,
            detail: "Unavailable · sign in",
            lastUpdated: Date()
        )
    }

    var providerStatuses: [ProviderStatus] {
        [codex, kimi, claude, qwen]
    }

    func status(for providerID: String) -> ProviderStatus {
        switch providerID {
        case ProviderCatalog.codex.id:
            return codex
        case ProviderCatalog.kimi.id:
            return kimi
        case ProviderCatalog.claude.id:
            return claude
        case ProviderCatalog.qwen.id:
            return qwen
        default:
            return ProviderStatus(
                id: providerID,
                name: providerID,
                state: .notInstalled,
                detail: "Not installed",
                lastUpdated: nil
            )
        }
    }

    private var notificationsAvailable: Bool {
        // UNUserNotificationCenter crashes when the binary runs outside an .app bundle.
        Bundle.main.bundleIdentifier != nil
    }

    func start() {
        if notificationsAvailable {
            configureNotifications()
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    func refreshNotificationSettings() {
        guard notificationsAvailable else {
            notificationStatusText = "Unavailable"
            notificationsEnabled = false
            return
        }

        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            Task { @MainActor in
                self?.applyNotificationSettings(settings)
            }
        }
    }

    func sendTestNotification() {
        sendNotification(
            identifier: "aifleet-test-\(UUID().uuidString)",
            body: "Notifications are working."
        )
    }

    func resetNotificationThresholdState() {
        let defaults = UserDefaults.standard
        for key in notificationStateKeysToReset(defaults.dictionaryRepresentation().keys) {
            defaults.removeObject(forKey: key)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        task?.cancel()
        task = nil
    }

    func refresh() {
        task?.cancel()
        task = Task { @MainActor in
            lastError = nil
            async let kimiResult = checkKimiIfEnabled()
            async let codexResult = checkCodexIfEnabled()
            async let claudeResult = checkClaudeIfEnabled()
            async let qwenResult = checkQwenIfEnabled()
            self.kimi = await kimiResult
            self.codex = await codexResult
            self.claude = await claudeResult
            self.qwen = await qwenResult
            processDrainNotifications()
        }
    }

    private func checkKimiIfEnabled() async -> ProviderStatus {
        guard ProviderCatalog.isInstalled(ProviderCatalog.kimi) else {
            return Self.notInstalledStatus(for: ProviderCatalog.kimi)
        }
        guard AppSettings.shared.kimiEnabled else {
            return Self.disabledStatus(for: ProviderCatalog.kimi)
        }
        return await checkKimi()
    }

    private func checkCodexIfEnabled() async -> ProviderStatus {
        guard ProviderCatalog.isInstalled(ProviderCatalog.codex) else {
            return Self.notInstalledStatus(for: ProviderCatalog.codex)
        }
        guard AppSettings.shared.codexEnabled else {
            return Self.disabledStatus(for: ProviderCatalog.codex)
        }
        return await checkCodex()
    }

    private func checkClaudeIfEnabled() async -> ProviderStatus {
        guard ProviderCatalog.isInstalled(ProviderCatalog.claude) else {
            return Self.notInstalledStatus(for: ProviderCatalog.claude)
        }
        guard AppSettings.shared.claudeEnabled else {
            return Self.disabledStatus(for: ProviderCatalog.claude)
        }
        return checkLocalProvider(ProviderCatalog.claude)
    }

    private func checkQwenIfEnabled() async -> ProviderStatus {
        guard ProviderCatalog.isInstalled(ProviderCatalog.qwen) else {
            return Self.notInstalledStatus(for: ProviderCatalog.qwen)
        }
        guard AppSettings.shared.qwenEnabled else {
            return Self.disabledStatus(for: ProviderCatalog.qwen)
        }
        return checkLocalProvider(ProviderCatalog.qwen)
    }

    private func checkLocalProvider(_ provider: ProviderDefinition) -> ProviderStatus {
        guard ProviderCatalog.hasCredentialFile(for: provider) else {
            return Self.unavailableStatus(for: provider)
        }
        return ProviderStatus(
            id: provider.id,
            name: provider.name,
            state: .ok,
            detail: "No quota data",
            lastUpdated: Date()
        )
    }

    // MARK: - Drain notifications

    private func configureNotifications() {
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.delegate = self
        notificationCenter.requestAuthorization(options: [.alert, .sound]) { [weak self] _, error in
            Task { @MainActor in
                if error != nil {
                    self?.lastError = "Notification permission failed"
                }
                self?.refreshNotificationSettings()
            }
        }
    }

    private func applyNotificationSettings(_ settings: UNNotificationSettings) {
        switch settings.authorizationStatus {
        case .authorized:
            notificationsEnabled = true
            notificationStatusText = "Allowed"
        case .provisional:
            notificationsEnabled = true
            notificationStatusText = "Allowed quietly"
        case .denied:
            notificationsEnabled = false
            notificationStatusText = "Denied in macOS"
        case .notDetermined:
            notificationsEnabled = false
            notificationStatusText = "Not asked"
        @unknown default:
            notificationsEnabled = false
            notificationStatusText = "Unknown"
        }
    }

    private func processDrainNotifications() {
        let settings = AppSettings.shared
        let thresholds = settings.notificationThresholds
        let defaults = UserDefaults.standard

        for provider in providerStatuses where settings.isEnabled(provider.id) {
            guard provider.state == .ok || provider.state == .limited else {
                continue
            }

            for window in provider.limitWindows {
                let remaining = max(0, min(100, window.remainingPercent))
                let keySuffix = "\(provider.id).\(window.id)"
                let lastRemainingKey = "notify.remainingLast.\(keySuffix)"
                let notifiedThresholdsKey = "notify.remainingNotifiedThresholds.\(keySuffix)"
                let previousRemaining = defaults.object(forKey: lastRemainingKey) as? Int ?? 101
                var notifiedThresholds = Set(defaults.array(forKey: notifiedThresholdsKey) as? [Int] ?? [])

                if remaining > previousRemaining {
                    // Re-arm thresholds that this quota-window reset moved back above.
                    notifiedThresholds = Set(thresholds.filter { remaining <= $0 })
                    defaults.set(Array(notifiedThresholds).sorted(by: >), forKey: notifiedThresholdsKey)
                }

                let crossedThresholds = thresholds.filter { threshold in
                    remaining <= threshold &&
                        !notifiedThresholds.contains(threshold) &&
                        (previousRemaining > threshold || remaining <= threshold)
                }

                if let threshold = crossedThresholds.min() {
                    let acceptedThresholds = Array(notifiedThresholds.union(crossedThresholds)).sorted(by: >)
                    sendLimitNotification(
                        providerName: provider.name,
                        windowLabel: window.label,
                        threshold: threshold,
                        resetAt: window.resetAt,
                        notifiedThresholdsKey: notifiedThresholdsKey,
                        acceptedThresholds: acceptedThresholds
                    )
                }

                defaults.set(remaining, forKey: lastRemainingKey)
            }
        }
    }

    private func sendLimitNotification(
        providerName: String,
        windowLabel: String,
        threshold: Int,
        resetAt: Date?,
        notifiedThresholdsKey: String,
        acceptedThresholds: [Int]
    ) {
        sendNotification(
            identifier: "aifleet-drain-\(UUID().uuidString)",
            body: limitNotificationBody(
                providerName: providerName,
                threshold: threshold,
                windowLabel: windowLabel,
                resetAt: resetAt
            )
        ) {
            UserDefaults.standard.set(acceptedThresholds, forKey: notifiedThresholdsKey)
        }
    }

    private func sendNotification(identifier: String, body: String, onAccepted: (() -> Void)? = nil) {
        guard notificationsAvailable else {
            lastError = "Notifications unavailable"
            return
        }

        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.getNotificationSettings { [weak self] settings in
            guard settings.authorizationStatus == .authorized ||
                    settings.authorizationStatus == .provisional else {
                Task { @MainActor in
                    self?.applyNotificationSettings(settings)
                    self?.lastError = "Notifications disabled in macOS"
                }
                return
            }

            Task { @MainActor in
                self?.applyNotificationSettings(settings)
            }

            let content = UNMutableNotificationContent()
            content.title = "AI Fleet"
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: identifier,
                content: content,
                trigger: nil
            )
            notificationCenter.add(request) { [weak self] error in
                Task { @MainActor in
                    if error != nil {
                        self?.lastError = "Notification failed"
                    } else {
                        self?.lastError = nil
                        onAccepted?()
                    }
                }
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    // MARK: - Kimi

    private func checkKimi() async -> ProviderStatus {
        // 1. Prefer Kimi Code subscription credentials.
        if let auth = readKimiCodeAuth() {
            let result = await checkKimiCode(auth: auth)
            if result.state != .noKey {
                return result
            }
        }

        // 2. Fall back to Open Platform API key balance.
        guard let key = config.resolvedKimiKey, !key.isEmpty else {
            return Self.unavailableStatus(for: ProviderCatalog.kimi)
        }

        let url = URL(string: "https://api.moonshot.ai/v1/users/me/balance")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return ProviderStatus(id: "kimi", name: "Kimi", state: .offline, detail: "Unavailable", lastUpdated: Date())
            }
            let decoded = try JSONDecoder().decode(KimiBalanceResponse.self, from: data)
            guard let balance = decoded.data?.availableBalance else {
                return ProviderStatus(id: "kimi", name: "Kimi", state: .offline, detail: "Bad response", lastUpdated: Date())
            }
            let state: ProviderStatus.State = balance > 0 ? .ok : .limited
            return ProviderStatus(id: "kimi", name: "Kimi", state: state, detail: String(format: "$%.2f", balance), lastUpdated: Date())
        } catch {
            return ProviderStatus(id: "kimi", name: "Kimi", state: .offline, detail: "Offline", lastUpdated: Date())
        }
    }

    private func checkKimiCode(auth: KimiCodeAuth) async -> ProviderStatus {
        var activeAuth = auth
        if auth.needsRefresh {
            switch await refreshKimiCodeAuth(auth: auth) {
            case .refreshed(let refreshed):
                activeAuth = refreshed
            case .unauthorized:
                return Self.unavailableStatus(for: ProviderCatalog.kimi)
            case .failed:
                return ProviderStatus(id: "kimi", name: "Kimi", state: .offline, detail: "Refresh failed", lastUpdated: Date())
            }
        }

        guard let token = activeAuth.accessToken, !token.isEmpty else {
            return Self.unavailableStatus(for: ProviderCatalog.kimi)
        }

        let status = await fetchKimiCodeStatus(accessToken: token)
        if status.state != .noKey {
            return status
        }

        switch await refreshKimiCodeAuth(auth: activeAuth) {
        case .refreshed(let refreshed):
            guard let token = refreshed.accessToken else { return status }
            return await fetchKimiCodeStatus(accessToken: token)
        case .unauthorized:
            return Self.unavailableStatus(for: ProviderCatalog.kimi)
        case .failed:
            return status
        }
    }

    private func fetchKimiCodeStatus(accessToken token: String) async -> ProviderStatus {
        let url = URL(string: "https://api.kimi.com/coding/v1/usages")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                if let http = response as? HTTPURLResponse, http.statusCode == 401 {
                    return Self.unavailableStatus(for: ProviderCatalog.kimi)
                }
                return ProviderStatus(id: "kimi", name: "Kimi", state: .offline, detail: "Unavailable", lastUpdated: Date())
            }
            let decoded = try decoder.decode(KimiCodeUsageResponse.self, from: data)

            var candidates: [LimitCandidate] = []
            if let usage = decoded.usage,
               let candidate = kimiLimitCandidate(from: usage, id: "weekly", label: "7d") {
                candidates.append(candidate)
            }
            for (index, limit) in (decoded.limits ?? []).enumerated() {
                guard let detail = limit.detail else { continue }
                let label = kimiWindowLabel(for: limit.window) ?? "window"
                if let candidate = kimiLimitCandidate(
                    from: detail,
                    id: "rolling-\(index)-\(label)",
                    label: label
                ) {
                    candidates.append(candidate)
                }
            }
            guard let selected = candidates.min(by: { $0.remaining < $1.remaining }) else {
                return ProviderStatus(id: "kimi", name: "Kimi", state: .ok, detail: "No usage data", lastUpdated: Date())
            }

            let state: ProviderStatus.State = selected.remaining <= 10 ? .limited : .ok
            return ProviderStatus(
                id: "kimi",
                name: "Kimi",
                state: state,
                detail: "\(selected.remaining)% left",
                lastUpdated: Date(),
                remainingPercent: selected.remaining,
                windowLabel: selected.label,
                resetAt: selected.resetAt,
                limitWindows: candidates.map(\.providerWindow)
            )
        } catch {
            return ProviderStatus(id: "kimi", name: "Kimi", state: .offline, detail: "Offline", lastUpdated: Date())
        }
    }

    private enum KimiRefreshResult {
        case refreshed(KimiCodeAuth)
        case unauthorized
        case failed
    }

    private func refreshKimiCodeAuth(auth: KimiCodeAuth) async -> KimiRefreshResult {
        guard let refreshToken = auth.refreshToken, !refreshToken.isEmpty else {
            return .unauthorized
        }

        let url = URL(string: "https://auth.kimi.com/api/oauth/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (field, value) in kimiDeviceHeaders() {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.timeoutInterval = 15

        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "client_id", value: Self.kimiCodeClientID),
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken)
        ]
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failed }
            if http.statusCode == 401 || http.statusCode == 403 {
                return .unauthorized
            }
            guard (200..<300).contains(http.statusCode) else { return .failed }

            let refresh = try decoder.decode(KimiOAuthRefreshResponse.self, from: data)
            let nextAuth = KimiCodeAuth(
                accessToken: refresh.accessToken,
                refreshToken: refresh.refreshToken ?? refreshToken,
                expiresAt: Date().timeIntervalSince1970 + TimeInterval(refresh.expiresIn),
                expiresIn: refresh.expiresIn,
                scope: refresh.scope ?? auth.scope,
                tokenType: refresh.tokenType ?? auth.tokenType
            )
            saveKimiCodeAuth(nextAuth)
            return .refreshed(nextAuth)
        } catch {
            return .failed
        }
    }

    // MARK: - Codex

    private func checkCodex() async -> ProviderStatus {
        guard let credentials = readCodexCredentials() else {
            return Self.unavailableStatus(for: ProviderCatalog.codex)
        }

        let url = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        if let accountId = credentials.accountID {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-ID")
        }
        request.timeoutInterval = 15

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                if let http = response as? HTTPURLResponse, http.statusCode == 401 {
                    return Self.unavailableStatus(for: ProviderCatalog.codex)
                }
                return ProviderStatus(id: "codex", name: "Codex", state: .offline, detail: "Unavailable", lastUpdated: Date())
            }
            let decoded = try decoder.decode(CodexUsageResponse.self, from: data)
            let candidates = [
                ("primary", decoded.rateLimit?.primaryWindow),
                ("secondary", decoded.rateLimit?.secondaryWindow)
            ]
                .compactMap { id, window in
                    window.flatMap { codexLimitCandidate(from: $0, id: id) }
                }
            guard let selected = candidates.min(by: { $0.remaining < $1.remaining }) else {
                return ProviderStatus(id: "codex", name: "Codex", state: .ok, detail: "No limit data", lastUpdated: Date())
            }

            let state: ProviderStatus.State = selected.remaining <= 10 ? .limited : .ok
            return ProviderStatus(
                id: "codex",
                name: "Codex",
                state: state,
                detail: "\(selected.remaining)% left",
                lastUpdated: Date(),
                remainingPercent: selected.remaining,
                windowLabel: selected.label,
                resetAt: selected.resetAt,
                limitWindows: candidates.map(\.providerWindow)
            )
        } catch {
            return ProviderStatus(id: "codex", name: "Codex", state: .offline, detail: "Offline", lastUpdated: Date())
        }
    }

    // MARK: - Auth readers

    private func readCodexCredentials() -> (accessToken: String, accountID: String?)? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let auth = object as? [String: Any] else {
            return nil
        }

        let nestedTokens = auth["tokens"] as? [String: Any]
        let token = auth["access_token"] as? String ?? nestedTokens?["access_token"] as? String
        let accountID = auth["account_id"] as? String ?? nestedTokens?["account_id"] as? String

        guard let accessToken = token?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines),
              !accessToken.isEmpty else {
            return nil
        }
        return (accessToken, accountID)
    }

    private func readKimiCodeAuth() -> KimiCodeAuth? {
        let url = kimiCodeCredentialsURL()
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(KimiCodeAuth.self, from: data)
    }

    private func saveKimiCodeAuth(_ auth: KimiCodeAuth) {
        do {
            let url = kimiCodeCredentialsURL()
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(auth)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            // The next refresh will retry; do not surface credential write details in UI.
        }
    }

    private func kimiCodeCredentialsURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kimi-code/credentials/kimi-code.json")
    }

    private func kimiDeviceHeaders() -> [String: String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kimi-code", isDirectory: true)
        let deviceIDURL = home.appendingPathComponent("device_id")
        let rawDeviceID = (try? String(contentsOf: deviceIDURL))?
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        let deviceID = rawDeviceID?.isEmpty == false ? rawDeviceID! : UUID().uuidString

        return [
            "User-Agent": "AI-Fleet/1.0",
            "X-Msh-Platform": "kimi_code_cli",
            "X-Msh-Version": "1.0",
            "X-Msh-Device-Name": Host.current().localizedName ?? "Mac",
            "X-Msh-Device-Model": "Mac",
            "X-Msh-Os-Version": ProcessInfo.processInfo.operatingSystemVersionString,
            "X-Msh-Device-Id": deviceID
        ]
    }

    private func remainingPercent(limit: Int, used: Int) -> Int {
        guard limit > 0 else { return 0 }
        return max(0, min(100, 100 - Int((Double(used) / Double(limit)) * 100)))
    }

    private func remainingPercent(usedPercent: Double) -> Int {
        let clampedUsed = max(0, min(100, usedPercent))
        return max(0, min(100, Int((100 - clampedUsed).rounded(.down))))
    }

    private func kimiLimitCandidate(
        from window: KimiCodeUsageResponse.UsageWindow,
        id: String,
        label: String
    ) -> LimitCandidate? {
        let remaining: Int
        let usedCount: Int?
        let limitCount: Int?
        if let limit = window.limit, let used = window.used, limit > 0 {
            remaining = remainingPercent(limit: limit, used: used)
            usedCount = used
            limitCount = limit
        } else if let limit = window.limit, let remainingCount = window.remaining, limit > 0 {
            remaining = max(0, min(100, Int((Double(remainingCount) / Double(limit)) * 100)))
            usedCount = max(0, limit - remainingCount)
            limitCount = limit
        } else if let remainingCount = window.remaining {
            remaining = max(0, min(100, remainingCount))
            usedCount = nil
            limitCount = nil
        } else {
            return nil
        }

        return LimitCandidate(
            id: id,
            label: label,
            remaining: remaining,
            resetAt: parseISO8601(window.resetTime),
            usedCount: usedCount,
            limitCount: limitCount,
            unit: usedCount == nil ? nil : "quota"
        )
    }

    private func codexLimitCandidate(from window: CodexUsageResponse.Window, id: String) -> LimitCandidate? {
        guard let used = window.usedPercent else { return nil }
        let label = compactDurationLabel(seconds: window.limitWindowSeconds) ?? "window"
        return LimitCandidate(
            id: id,
            label: label,
            remaining: remainingPercent(usedPercent: used),
            resetAt: window.resetAt.map { Date(timeIntervalSince1970: $0) },
            usedCount: nil,
            limitCount: nil,
            unit: nil
        )
    }

    private func kimiWindowLabel(for window: KimiCodeUsageResponse.RateLimitWindow.WindowMeta?) -> String? {
        guard let duration = window?.duration, let unit = window?.timeUnit else { return nil }

        let seconds: Double
        switch unit {
        case "TIME_UNIT_SECOND":
            seconds = Double(duration)
        case "TIME_UNIT_MINUTE":
            seconds = Double(duration * 60)
        case "TIME_UNIT_HOUR":
            seconds = Double(duration * 60 * 60)
        case "TIME_UNIT_DAY":
            seconds = Double(duration * 60 * 60 * 24)
        default:
            return nil
        }
        return compactDurationLabel(seconds: seconds)
    }

    private func compactDurationLabel(seconds: Double?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        let rounded = Int(seconds.rounded())
        let day = 60 * 60 * 24
        let hour = 60 * 60
        let minute = 60

        if rounded >= day, rounded % day == 0 {
            return "\(rounded / day)d"
        }
        if rounded >= hour, rounded % hour == 0 {
            return "\(rounded / hour)h"
        }
        if rounded >= minute, rounded % minute == 0 {
            return "\(rounded / minute)m"
        }
        return "\(rounded)s"
    }

    private func parseISO8601(_ value: String?) -> Date? {
        guard let value else { return nil }
        return iso8601Fractional.date(from: value) ?? iso8601.date(from: value)
    }
}

func limitNotificationBody(
    providerName: String,
    threshold: Int,
    windowLabel: String,
    resetAt: Date? = nil,
    now: Date = Date(),
    calendar: Calendar = .current
) -> String {
    let headline = "\(providerName) reached \(threshold)% threshold (\(windowLabel))."
    guard let resetAt else { return headline }

    let seconds = resetAt.timeIntervalSince(now)
    guard seconds > 0 else { return "\(headline)\nResets now." }

    let totalMinutes = max(1, Int(ceil(seconds / 60)))
    let days = totalMinutes / (24 * 60)
    let hours = (totalMinutes % (24 * 60)) / 60
    let minutes = totalMinutes % 60
    let relative: String
    if days > 0 {
        relative = hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
    } else if hours > 0 {
        relative = minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
    } else {
        relative = "\(minutes)m"
    }

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "MMM d 'at' HH:mm"
    return "\(headline)\nResets in \(relative) · \(formatter.string(from: resetAt))."
}

func notificationStateKeysToReset<S: Sequence>(_ keys: S) -> [String] where S.Element == String {
    let prefixes = [
        "notify.remainingLast.",
        "notify.remainingNotifiedThresholds."
    ]
    return keys.filter { key in
        prefixes.contains { key.hasPrefix($0) }
    }
}
