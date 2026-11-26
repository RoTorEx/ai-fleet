import XCTest
@testable import AIFleet

final class NotificationSoundsTests: XCTestCase {
    @MainActor
    func testSoundSelectionUsesTheEventAndKeepsSilentExplicit() {
        let done = NotificationSoundChoice(id: "agent/complete-felt-fifth.wav", title: "Agent done")
        let help = NotificationSoundChoice(id: "agent/help-chirp-pair.wav", title: "Agent needs you")
        let choices: [NotificationSoundChoice] = [.silent, .systemDefault, done, help]

        for reason in [AgentNotificationReason.approval, .question, .blocked] {
            let event = NotificationSoundEvent(reason: reason)
            XCTAssertEqual(NotificationSounds.choice(for: event, selectedID: nil, in: choices).id, help.id)
        }
        XCTAssertEqual(NotificationSounds.choice(for: .init(reason: .replyReady), selectedID: "removed", in: choices).id, done.id)
        let silent = NotificationSounds.choice(for: .quota, selectedID: "silent", in: choices)
        XCTAssertNil(NotificationSounds.notificationSound(for: silent))
    }
}
