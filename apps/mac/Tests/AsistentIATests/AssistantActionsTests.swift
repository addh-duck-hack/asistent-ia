import Foundation
import Testing
@testable import AsistentIA

@MainActor
struct AssistantActionsTests {
    @Test func idleMenuHasRecordAndNoStop() {
        let items = AssistantActions.items(store: AppStore(), recorder: RecordingService())
        #expect(items.map(\.id) == ["open", "record", "audio-test", "ask", "settings", "quit"])
        #expect(items.first { $0.id == "settings" }?.separatorBefore == true)
        #expect(items.last?.shortcut == "q")
        #expect(items.first { $0.id == "record" }?.enabled == true)
    }

    @Test func askUsesTheCompanionCallbackWhenGiven() {
        var asked = false
        let items = AssistantActions.items(store: AppStore(), recorder: RecordingService(), ask: { asked = true })
        items.first { $0.id == "ask" }?.perform()
        #expect(asked)
    }

    @Test func presenceDecidesIconAndCharacter() {
        #expect(CompanionController.Presence.character.showsCharacter)
        #expect(!CompanionController.Presence.character.showsMenuBar)
        #expect(!CompanionController.Presence.menuBar.showsCharacter)
        #expect(CompanionController.Presence.menuBar.showsMenuBar)
        #expect(CompanionController.Presence.both.showsCharacter && CompanionController.Presence.both.showsMenuBar)
    }
}
