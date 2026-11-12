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

@MainActor
struct CompanionHideTests {
    @Test func hidingShowsTheMenuBarIconUntilTheCharacterComesBack() {
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: CompanionController.presenceKey)
        defer { defaults.set(previous, forKey: CompanionController.presenceKey) }
        defaults.set(CompanionController.Presence.character.rawValue, forKey: CompanionController.presenceKey)

        let controller = CompanionController(store: AppStore(), recorder: RecordingService())
        controller.hide(for: 3600)
        #expect(controller.isHiddenByUser)
        #expect(!controller.isVisible)
        let until = try? #require(controller.hiddenUntilDate)
        #expect(until.map { $0.timeIntervalSinceNow > 3500 } == true)

        controller.show()
        #expect(!controller.isHiddenByUser)
        #expect(controller.isVisible)
        #expect(controller.hiddenUntilDate == nil)

        controller.hide(for: nil)
        #expect(controller.isHiddenByUser)
        #expect(controller.hiddenUntilDate == nil) // hasta reiniciar
        controller.show()
        #expect(!controller.isHiddenByUser)
    }
}
