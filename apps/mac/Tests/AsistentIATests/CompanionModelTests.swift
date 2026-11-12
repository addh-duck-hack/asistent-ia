import Foundation
import Testing
@testable import AsistentIA

@MainActor
struct CompanionModelTests {
    @Test func recordingProgressAndFinished() {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let model = CompanionModel(now: { now })
        let since = now
        model.apply(phase: .recording(since: since), title: "Daily")
        #expect(model.mood == .listening)
        #expect(model.current?.kind == .progress)
        #expect(model.current?.elapsedSince == since)
        #expect(model.current?.text.contains("«Daily»") == true)

        model.apply(phase: .transcribing(progress: 0.4), title: "Daily")
        #expect(model.mood == .thinking)
        #expect(model.bubbles.count == 1) // el progreso se reemplaza, no se apila
        #expect(model.current?.progress == 0.4)
        #expect(model.current?.elapsedSince == nil)

        model.apply(phase: .finished(sessionId: "s1"), title: "Daily")
        #expect(model.mood == .happy)
        #expect(model.bubbles.count == 1)
        #expect(model.takePendingFinished() == "s1")
        #expect(model.takePendingFinished() == nil)
        model.apply(phase: .finished(sessionId: "s1"), title: "Daily")
        #expect(model.bubbles.count == 1) // no repite el aviso

        now = now.addingTimeInterval(11)
        model.tick()
        #expect(model.bubbles.isEmpty)
        #expect(model.mood == .idle)
    }

    @Test func failureMicProblemAndInterrupted() {
        let model = CompanionModel()
        var restarted = false
        model.onRestartMic = { restarted = true }
        model.apply(phase: .failed("Sin permiso de micrófono"))
        #expect(model.mood == .sad)
        #expect(model.current?.kind == .error)
        model.dismissCurrent()
        #expect(model.current == nil)

        model.apply(phase: .recording(since: .now), micProblem: "Silencio")
        #expect(model.current?.mood == .alert)
        #expect(model.mood == .alert)
        model.current?.action?.perform()
        #expect(restarted)
        model.apply(phase: .recording(since: .now), micProblem: "Silencio")
        #expect(model.bubbles.filter { $0.kind == .error }.count == 1)
        model.dismissCurrent()
        #expect(model.mood == .listening)

        model.apply(phase: .idle, hasInterrupted: true)
        #expect(model.current?.text.contains("interrumpida") == true)
        model.apply(phase: .idle, hasInterrupted: true)
        #expect(model.bubbles.count == 1)
    }

    @Test func noticesAndErrorsDoNotRepeat() {
        let model = CompanionModel()
        let notice = AppStore.Notice(text: "Copiado")
        model.apply(phase: .idle, notice: notice)
        model.apply(phase: .idle, notice: notice)
        #expect(model.bubbles.count == 1)
        #expect(model.mood == .talking)
        model.apply(phase: .idle, notice: AppStore.Notice(text: "Exportado"))
        #expect(model.bubbles.count == 2)
        #expect(model.current?.text == "Copiado") // en orden
        model.dismissCurrent()
        #expect(model.current?.text == "Exportado")
        model.apply(phase: .idle, error: "Falló")
        model.apply(phase: .idle, error: "Falló")
        #expect(model.bubbles.filter { $0.kind == .error }.count == 1)
        model.dismissAll()
        #expect(model.bubbles.isEmpty)
    }

    @Test func sleepsAfterTenMinutesAndWakes() {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let model = CompanionModel(now: { now })
        now = now.addingTimeInterval(CompanionModel.sleepAfter)
        model.tick()
        #expect(model.asleep)
        #expect(model.mood == .sleeping)
        model.wake()
        #expect(model.mood == .idle)

        now = now.addingTimeInterval(CompanionModel.sleepAfter)
        model.say("Hola", dismissAfter: nil)
        model.tick()
        #expect(!model.asleep) // con un globo a la vista no duerme
        model.dismissCurrent()
        model.chatOpen = true
        #expect(model.mood == .listening)
        #expect(model.idleVariant >= 1) // el reposo cambió con el tiempo
    }

    @Test func upcomingBirthdaysText() throws {
        let json = """
        [{"_id": "p1", "name": "Tavo", "aliases": [], "birthday": "1990-11-16T12:00:00.000Z"},
         {"_id": "p2", "name": "Ana", "aliases": [], "birthday": "1992-03-02T12:00:00.000Z"}]
        """
        let people = try APIClient.decoder.decode([TeamMember].self, from: Data(json.utf8))
        let now = Date(timeIntervalSince1970: 1_700_000_000) // 14 nov 2023
        let text = try #require(CompanionModel.upcomingText(people: people, now: now))
        #expect(text.contains("Tavo"))
        #expect(text.contains("🎂"))
        #expect(!text.contains("Ana"))
        #expect(CompanionModel.upcomingText(people: [people[1]], now: now) == nil)
    }
}

struct CompanionGeometryTests {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 877)
    let character = CompanionGeometry.characterSize

    @Test func characterOnlyKeepsOrigin() {
        let layout = CompanionGeometry.layout(characterOrigin: CGPoint(x: 100, y: 50), contentSize: character, screen: screen)
        #expect(layout.frame == CGRect(origin: CGPoint(x: 100, y: 50), size: character))
        #expect(!layout.bubbleOnLeft)
        #expect(CompanionGeometry.characterOrigin(in: layout) == CGPoint(x: 100, y: 50))
    }

    @Test func bubbleGrowsToTheRightOrToTheLeft() {
        let size = CGSize(width: CompanionGeometry.bubbleWidth, height: 320)
        let right = CompanionGeometry.layout(characterOrigin: CGPoint(x: 100, y: 50), contentSize: size, screen: screen)
        #expect(right.frame == CGRect(x: 100, y: 50, width: 300, height: 320))
        #expect(!right.bubbleOnLeft)

        let origin = CompanionGeometry.defaultOrigin(in: screen)
        #expect(origin == CGPoint(x: 1440 - character.width - 24, y: 24))
        let left = CompanionGeometry.layout(characterOrigin: origin, contentSize: size, screen: screen)
        #expect(left.bubbleOnLeft)
        #expect(left.frame.maxX == origin.x + character.width)
        #expect(left.frame.minX == origin.x - (300 - character.width))
        #expect(CompanionGeometry.characterOrigin(in: left) == origin)
    }

    @Test func clampsIntoTheScreen() {
        #expect(CompanionGeometry.clamp(CGRect(x: 1400, y: -30, width: 180, height: 200), to: screen)
            == CGRect(x: 1260, y: 0, width: 180, height: 200))
        let tall = CompanionGeometry.layout(characterOrigin: CGPoint(x: 10, y: 800), contentSize: CGSize(width: 300, height: 400), screen: screen)
        #expect(tall.frame.maxY == 877)
        #expect(tall.frame.minX == 10)
        #expect(CompanionGeometry.clamp(CGRect(x: 500, y: 0, width: 2000, height: 100), to: screen).origin.x == 0)
    }
}

struct CompanionSizeAndMenuTests {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 877)

    @Test func scaleIsClampedWithAMinimum() {
        #expect(CompanionGeometry.clampScale(0.1) == CompanionGeometry.minScale)
        #expect(CompanionGeometry.clampScale(9) == CompanionGeometry.maxScale)
        #expect(CompanionGeometry.clampScale(.nan) == 1)
        #expect(CompanionGeometry.characterSize(scale: 1) == CompanionGeometry.characterSize)
        #expect(CompanionGeometry.characterSize(scale: 0.2) == CGSize(width: 108, height: 120))
        #expect(CompanionGeometry.characterSize(scale: 1.5) == CGSize(width: 270, height: 300))
    }

    @Test func biggerCharacterKeepsItsOriginAndBubble() {
        let big = CompanionGeometry.characterSize(scale: 2)
        let layout = CompanionGeometry.layout(characterOrigin: CGPoint(x: 100, y: 50),
                                              contentSize: CGSize(width: big.width, height: big.height + 120),
                                              screen: screen, character: big)
        #expect(layout.frame == CGRect(x: 100, y: 50, width: 360, height: 520))
        #expect(CompanionGeometry.characterOrigin(in: layout) == CGPoint(x: 100, y: 50))
        let corner = CompanionGeometry.defaultOrigin(in: screen, character: big)
        #expect(corner.x + big.width == screen.maxX - 24)
    }

    @Test func menuOpensToTheRightWhenItFits() {
        let character = CGRect(x: 100, y: 50, width: 180, height: 200)
        let frame = CompanionGeometry.menuFrame(size: CGSize(width: 280, height: 420), beside: character, screen: screen)
        #expect(frame.minX == character.maxX + CompanionGeometry.menuGap)
        #expect(frame.minY == 0) // alineado arriba con el personaje, sin salirse por abajo
        #expect(screen.contains(frame))
    }

    @Test func menuOpensToTheLeftNearTheRightEdgeAndIsAlwaysWhole() {
        let character = CGRect(x: 1236, y: 24, width: 180, height: 200)
        let size = CGSize(width: 280, height: 420)
        let frame = CompanionGeometry.menuFrame(size: size, beside: character, screen: screen)
        #expect(frame.maxX == character.minX - CompanionGeometry.menuGap)
        #expect(frame.size == size)
        #expect(screen.contains(frame))

        let high = CGRect(x: 100, y: 700, width: 180, height: 200)
        let top = CompanionGeometry.menuFrame(size: size, beside: high, screen: screen)
        #expect(top.maxY <= screen.maxY)
        #expect(screen.contains(top))
    }
}
