import AppKit
import CryptoKit
import UserNotifications

enum NotificationSoundEvent: String, CaseIterable, Identifiable {
    case done, needsYou, quota

    var id: String { rawValue }

    var title: String {
        switch self {
        case .done: return "Reply ready"
        case .needsYou: return "Needs you"
        case .quota: return "Quota warning"
        }
    }

    init(reason: AgentNotificationReason) {
        self = reason.needsYou ? .needsYou : .done
    }

    var preferredSoundID: String {
        switch self {
        case .done: return "agent/complete-felt-fifth.wav"
        case .needsYou: return "agent/help-chirp-pair.wav"
        case .quota: return NotificationSoundChoice.systemDefault.id
        }
    }

    var fallbackSoundID: String {
        switch self {
        case .done: return "system/Glass.aiff"
        case .needsYou: return "system/Funk.aiff"
        case .quota: return NotificationSoundChoice.systemDefault.id
        }
    }
}

struct NotificationSoundChoice: Identifiable {
    let id: String
    let title: String
    var file: URL?

    static let silent = Self(id: "silent", title: "Silent")
    static let systemDefault = Self(id: "default", title: "System default")
}

@MainActor
enum NotificationSounds {
    private static let stagedPrefix = "AIFleetSound-"
    private static var preview: NSSound?

    static func choices() -> [NotificationSoundChoice] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let folders: [(String, URL)] = [
            ("agent", home.appendingPathComponent(".codex/sounds/assets")),
            ("local", home.appendingPathComponent("Library/Sounds")),
            ("system", URL(fileURLWithPath: "/System/Library/Sounds", isDirectory: true))
        ]
        return [.silent, .systemDefault] + folders.flatMap { source, folder in
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                                      options: [.skipsHiddenFiles])) ?? []
            return files.filter { file in
                ["wav", "aiff", "aif", "caf"].contains(file.pathExtension.lowercased()) &&
                    !file.lastPathComponent.hasPrefix(stagedPrefix) &&
                    (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                .map { file in
                    let name = file.deletingPathExtension().lastPathComponent
                    let title = source == "agent" ? name.replacingOccurrences(of: "-", with: " ").capitalized : name
                    return NotificationSoundChoice(id: "\(source)/\(file.lastPathComponent)", title: title, file: file)
                }
        }
    }

    static func choice(for event: NotificationSoundEvent, selectedID: String?,
                       in choices: [NotificationSoundChoice]) -> NotificationSoundChoice {
        for id in [selectedID, event.preferredSoundID, event.fallbackSoundID].compactMap({ $0 }) {
            if let choice = choices.first(where: { $0.id == id }) { return choice }
        }
        return .systemDefault
    }

    static func notificationSound(for choice: NotificationSoundChoice) -> UNNotificationSound? {
        if choice.id == NotificationSoundChoice.silent.id { return nil }
        guard let file = choice.file, let name = try? stage(file: file, id: choice.id) else { return .default }
        return UNNotificationSound(named: UNNotificationSoundName(name))
    }

    static func playPreview(_ choice: NotificationSoundChoice) {
        preview?.stop()
        if choice.id == NotificationSoundChoice.systemDefault.id {
            NSSound.beep()
        } else if let file = choice.file {
            preview = NSSound(contentsOf: file, byReference: true)
            preview?.play()
        }
    }

    private static func stage(file: URL, id: String) throws -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let sounds = home.appendingPathComponent("Library/Sounds", isDirectory: true)
        guard let audio = NSSound(contentsOf: file, byReference: true), audio.duration > 0, audio.duration < 30 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        if file.deletingLastPathComponent() == sounds { return file.lastPathComponent }

        let digest = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
        let name = "\(stagedPrefix)\(digest).\(file.pathExtension)"
        let destination = sounds.appendingPathComponent(name)
        let contents = try Data(contentsOf: file)
        try FileManager.default.createDirectory(at: sounds, withIntermediateDirectories: true)
        if (try? Data(contentsOf: destination)) != contents {
            try contents.write(to: destination, options: .atomic)
        }
        return name
    }
}
