import AppKit
import Carbon.HIToolbox
import Combine
import Foundation

struct HotkeyCombo: Equatable {
    let keyCode: UInt32
    let carbonModifiers: UInt32
    let keyDisplay: String

    static let `default` = HotkeyCombo(
        keyCode: UInt32(kVK_ANSI_I),
        carbonModifiers: UInt32(cmdKey | shiftKey),
        keyDisplay: "I"
    )

    var displayString: String {
        var result = ""
        if carbonModifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result + keyDisplay
    }
}

func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
    var modifiers: UInt32 = 0
    if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
    if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
    if flags.contains(.option) { modifiers |= UInt32(optionKey) }
    if flags.contains(.control) { modifiers |= UInt32(controlKey) }
    return modifiers
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    @Published var kimiEnabled: Bool {
        didSet { defaults.set(kimiEnabled, forKey: "provider.kimi.enabled") }
    }
    @Published var codexEnabled: Bool {
        didSet { defaults.set(codexEnabled, forKey: "provider.codex.enabled") }
    }
    @Published var claudeEnabled: Bool {
        didSet { defaults.set(claudeEnabled, forKey: "provider.claude.enabled") }
    }
    @Published var qwenEnabled: Bool {
        didSet { defaults.set(qwenEnabled, forKey: "provider.qwen.enabled") }
    }
    @Published var notifyStepPercent: Int {
        didSet { defaults.set(notifyStepPercent, forKey: "notify.stepPercent") }
    }
    @Published var analyticsAutoRefreshEnabled: Bool {
        didSet { defaults.set(analyticsAutoRefreshEnabled, forKey: "analytics.autoRefresh.enabled") }
    }
    @Published private(set) var analyticsRefreshMinutes: Int
    @Published private(set) var notificationThresholds: [Int]
    @Published var isRecordingHotkey = false
    @Published var hotkey: HotkeyCombo {
        didSet {
            defaults.set(Int(hotkey.keyCode), forKey: "hotkey.keyCode")
            defaults.set(Int(hotkey.carbonModifiers), forKey: "hotkey.carbonModifiers")
            defaults.set(hotkey.keyDisplay, forKey: "hotkey.keyDisplay")
        }
    }

    private init() {
        kimiEnabled = defaults.object(forKey: "provider.kimi.enabled") as? Bool ?? true
        codexEnabled = defaults.object(forKey: "provider.codex.enabled") as? Bool ?? true
        claudeEnabled = defaults.object(forKey: "provider.claude.enabled") as? Bool ?? true
        qwenEnabled = defaults.object(forKey: "provider.qwen.enabled") as? Bool ?? true

        let storedStep = defaults.integer(forKey: "notify.stepPercent")
        notifyStepPercent = storedStep > 0 ? storedStep : 10
        analyticsAutoRefreshEnabled = defaults.object(forKey: "analytics.autoRefresh.enabled") as? Bool ?? true
        if defaults.object(forKey: "analytics.autoRefresh.minutes") != nil {
            analyticsRefreshMinutes = Self.normalizedRefreshMinutes(
                defaults.integer(forKey: "analytics.autoRefresh.minutes")
            )
        } else {
            analyticsRefreshMinutes = 12 * 60
        }
        let storedThresholds = defaults.array(forKey: "notify.remainingThresholds") as? [Int] ?? []
        notificationThresholds = Self.normalizedThresholds(storedThresholds.isEmpty ? [50, 25, 10, 5, 0] : storedThresholds)

        if defaults.object(forKey: "hotkey.keyCode") != nil {
            hotkey = HotkeyCombo(
                keyCode: UInt32(defaults.integer(forKey: "hotkey.keyCode")),
                carbonModifiers: UInt32(defaults.integer(forKey: "hotkey.carbonModifiers")),
                keyDisplay: defaults.string(forKey: "hotkey.keyDisplay") ?? "?"
            )
        } else {
            hotkey = .default
        }
    }

    func isEnabled(_ providerID: String) -> Bool {
        switch providerID {
        case "kimi":
            return kimiEnabled
        case "codex":
            return codexEnabled
        case "claude":
            return claudeEnabled
        case "qwen":
            return qwenEnabled
        default:
            return true
        }
    }

    func setEnabled(_ isEnabled: Bool, for providerID: String) {
        switch providerID {
        case "kimi":
            kimiEnabled = isEnabled
        case "codex":
            codexEnabled = isEnabled
        case "claude":
            claudeEnabled = isEnabled
        case "qwen":
            qwenEnabled = isEnabled
        default:
            break
        }
    }

    func addNotificationThreshold(_ threshold: Int) {
        setNotificationThresholds(notificationThresholds + [threshold])
    }

    func removeNotificationThreshold(_ threshold: Int) {
        let next = notificationThresholds.filter { $0 != threshold }
        setNotificationThresholds(next.isEmpty ? [0] : next)
    }

    func setAnalyticsRefreshTime(_ date: Date, calendar: Calendar = .autoupdatingCurrent) {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let minutes = (components.hour ?? 12) * 60 + (components.minute ?? 0)
        analyticsRefreshMinutes = Self.normalizedRefreshMinutes(minutes)
        defaults.set(analyticsRefreshMinutes, forKey: "analytics.autoRefresh.minutes")
    }

    func analyticsRefreshTime(on date: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> Date {
        calendar.date(
            bySettingHour: analyticsRefreshMinutes / 60,
            minute: analyticsRefreshMinutes % 60,
            second: 0,
            of: date
        ) ?? date
    }

    private func setNotificationThresholds(_ thresholds: [Int]) {
        let normalized = Self.normalizedThresholds(thresholds)
        notificationThresholds = normalized
        defaults.set(normalized, forKey: "notify.remainingThresholds")
    }

    private static func normalizedThresholds(_ thresholds: [Int]) -> [Int] {
        Array(Set(thresholds.map { max(0, min(100, $0)) })).sorted(by: >)
    }

    private static func normalizedRefreshMinutes(_ minutes: Int) -> Int {
        max(0, min((24 * 60) - 1, minutes))
    }
}
