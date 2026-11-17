import Foundation
import Testing
@testable import AsistentIA

// Fase 7: reacciones, comportamiento y la lógica de gestos del personaje.

@Test func decodesReactionsBehaviorAndClipSpeed() throws {
    let json = """
    {"id": "robi", "base": "robi.usdz",
     "clips": {"idle": "idle.usdz"},
     "reactions": {"head": ["pat.usdz", {"file": "dizzy.usdz", "speed": 1.5}], "feet": "kick.usdz",
                   "random": ["stretch.usdz", "yawn.usdz"], "desconocida": "x.usdz"},
     "behavior": {"randomEnabled": false, "randomEvery": [30, 90], "headZone": 0.3, "feetZone": 0.9}}
    """
    let pack = try JSONDecoder().decode(CharacterPack.self, from: Data(json.utf8))
    #expect(pack.reactions[.head] == [ClipSource(file: "pat.usdz"), ClipSource(file: "dizzy.usdz", speed: 1.5)])
    #expect(pack.reactions[.feet] == [ClipSource(file: "kick.usdz")])
    #expect(pack.reactions.count == 3) // la clave desconocida se ignora
    #expect(pack.behavior.randomEnabled == false)
    #expect(pack.behavior.randomRange == 30 ... 90)
    #expect(pack.behavior.headZone == 0.3)
    #expect(pack.behavior.feetZone == CharacterPack.Behavior.zoneRange.upperBound) // fuera de rango: se acota
    #expect(pack.files.contains("yawn.usdz"))
    #expect(pack.allClips.count == 6)

    let decoded = try JSONDecoder().decode(CharacterPack.self, from: JSONEncoder().encode(pack))
    #expect(decoded == pack)
}

@Test func olderPacksKeepWorkingAndStaySmall() throws {
    let json = #"{"id": "zombie", "clips": {"idle": "idle.usdz"}}"#
    let pack = try JSONDecoder().decode(CharacterPack.self, from: Data(json.utf8))
    #expect(pack.reactions.isEmpty)
    #expect(pack.behavior == CharacterPack.Behavior())
    // Sin reacciones ni cambios de comportamiento, el JSON no gana claves nuevas.
    let text = String(decoding: try JSONEncoder().encode(pack), as: UTF8.self)
    #expect(!text.contains("reactions"))
    #expect(!text.contains("behavior"))
}

@Test func clipSpeedIsClampedAndIgnoredForLoading() {
    #expect(ClipSource(file: "a.usdz").playbackSpeed == 1)
    #expect(ClipSource(file: "a.usdz", speed: 100).playbackSpeed == ClipSource.speedRange.upperBound)
    #expect(ClipSource(file: "a.usdz", speed: 0).playbackSpeed == ClipSource.speedRange.lowerBound)
    #expect(ClipSource(file: "a.usdz", start: 1, end: 2, speed: 2).resourceKey == ClipSource(file: "a.usdz", start: 1, end: 2))
    #expect(ClipSource(file: "Wave Hello.usdz").name == "Wave Hello")
}

@Test func slotsAssignAndRemoveFiles() {
    var pack = CharacterPack(id: "p", name: "P", clips: [.idle: [ClipSource(file: "idle.usdz")]])
    pack.setClips([ClipSource(file: "wave.usdz"), ClipSource(file: "idle.usdz")], in: .reaction(.head))
    pack.setClips([ClipSource(file: "wave.usdz")], in: .mood(.alert))
    #expect(pack.slots(using: "wave.usdz") == [.mood(.alert), .reaction(.head)])
    #expect(pack.slots(using: "idle.usdz") == [.mood(.idle), .reaction(.head)])
    pack.removeFile("wave.usdz")
    #expect(pack.clips[.alert] == nil)
    #expect(pack.reactions[.head] == [ClipSource(file: "idle.usdz")])
    pack.setClips([], in: .reaction(.head))
    #expect(pack.reactions.isEmpty)
}

@Test func importerRecognizesReactionsByName() {
    let result = CharacterImporter.mapAllByName(["idle.usdz", "head_pat.usdz", "Cabeza2.usdz", "pies.usdz", "body-poke.usdz",
                                                 "random_stretch.usdz", "gesto bostezo.usdz", "wake.usdz", "drag.usdz",
                                                 "greet.usdz", "happy.usdz", "otro.usdz"])
    #expect(result.reactions[.head]?.map(\.file) == ["Cabeza2.usdz", "head_pat.usdz"])
    #expect(result.reactions[.feet]?.map(\.file) == ["pies.usdz"])
    #expect(result.reactions[.body]?.map(\.file) == ["body-poke.usdz"])
    #expect(result.reactions[.random]?.count == 2)
    #expect(result.reactions[.wake] != nil && result.reactions[.drag] != nil && result.reactions[.greet] != nil)
    #expect(result.clips[.idle]?.map(\.file) == ["idle.usdz"])
    #expect(result.clips[.happy]?.map(\.file) == ["happy.usdz"])
    #expect(result.unmatched == ["otro.usdz"])
    // Los nombres de estado de siempre no se confunden con reacciones.
    let moods = CharacterImporter.mapAllByName(["sleep.usdz", "thinking.usdz", "wave.usdz", "sad_idle.usdz"])
    #expect(moods.reactions.isEmpty)
}

@Test func savesPackAndAddsAnimationFiles() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appending(path: "anim-\(UUID().uuidString)")
    let folder = root.appending(path: "personaje")
    let downloads = root.appending(path: "descargas")
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    try Data("uno".utf8).write(to: downloads.appending(path: "wave.usdz"))
    try Data("nota".utf8).write(to: downloads.appending(path: "leeme.txt"))
    try Data("viejo".utf8).write(to: folder.appending(path: "wave.usdz"))

    let added = try CharacterLibrary.addAnimations([downloads.appending(path: "wave.usdz"), downloads.appending(path: "leeme.txt")], to: folder)
    #expect(added == ["wave.usdz"]) // solo modelos; el que se llama igual se reemplaza
    #expect(try Data(contentsOf: folder.appending(path: "wave.usdz")) == Data("uno".utf8))
    #expect(!fm.fileExists(atPath: folder.appending(path: "leeme.txt").path))

    var pack = CharacterPack(id: "personaje", name: "Personaje", clips: [.idle: [ClipSource(file: "wave.usdz")]])
    pack.reactions[.head] = [ClipSource(file: "wave.usdz", speed: 2)]
    pack.behavior.randomMin = 20
    try CharacterLibrary.save(pack, in: folder)
    let loaded = try CharacterLibrary.load(folder: folder)
    #expect(loaded.pack == pack)
    #expect(loaded.isEditable)
    #expect(!InstalledCharacter.duck.isEditable)
}

@Test func builtInDuckReactsToEverything() {
    for reaction in CompanionReaction.allCases {
        let clips = CharacterPack.builtInDuck.reactions[reaction] ?? []
        #expect(!clips.isEmpty)
        // Sus "clips" son sus propios estados.
        #expect(clips.allSatisfy { CompanionMood(rawValue: $0.name) != nil })
    }
}

@MainActor
struct CompanionGestureTests {
    private func pack(_ reactions: [CompanionReaction: [ClipSource]], behavior: CharacterPack.Behavior = .init()) -> CharacterPack {
        CharacterPack(id: "p", name: "P", clips: [.idle: [ClipSource(file: "idle.usdz")]], reactions: reactions, behavior: behavior)
    }

    @Test func clickZonesFollowTheBehavior() {
        var behavior = CharacterPack.Behavior()
        #expect(CompanionModel.zone(atHeight: 0.95, behavior: behavior) == .head)
        #expect(CompanionModel.zone(atHeight: 0.5, behavior: behavior) == .body)
        #expect(CompanionModel.zone(atHeight: 0.05, behavior: behavior) == .feet)
        #expect(CompanionModel.zone(atHeight: 0.7, behavior: behavior) == .body)
        behavior.headZone = 0.4
        #expect(CompanionModel.zone(atHeight: 0.7, behavior: behavior) == .head)
    }

    @Test func onlyReactUsesAnotherZoneWhenTheClickedOneHasNoAnimation() {
        let model = CompanionModel()
        let head = ClipSource(file: "head.usdz")
        model.pack = pack([.head: [head]])
        // "Reacciona y abre el menú": sin animación en los pies, no reacciona (y se abre el menú).
        #expect(model.performClick(on: .feet, anyZone: false) == false)
        #expect(model.gesture == nil)
        // "Solo reacciona": usa la de la cabeza.
        #expect(model.performClick(on: .feet, anyZone: true))
        #expect(model.gesture?.clip == head)
        // Sin ninguna animación de clic no hay nada que hacer (el clic abre el menú).
        model.stopGesture()
        model.pack = pack([:])
        #expect(model.performClick(on: .body, anyZone: true) == false)
    }

    @Test func reactionsPlayOnceAndDoNotRepeatTheSameClip() {
        let model = CompanionModel()
        let a = ClipSource(file: "a.usdz"), b = ClipSource(file: "b.usdz")
        model.pack = pack([.head: [a, b]])
        #expect(model.perform(.feet) == false) // sin animación para los pies
        #expect(model.gesture == nil)

        #expect(model.perform(.head))
        let first = model.gesture
        #expect(first?.reaction == .head)
        #expect(first?.loops == false)
        for _ in 0 ..< 6 {
            let previous = model.gesture?.clip
            model.perform(.head)
            #expect(model.gesture?.clip != previous) // con dos, alterna
        }
        // La escena avisa que terminó: solo cuenta el gesto vigente.
        if let first { model.endGesture(first.id) }
        #expect(model.gesture != nil)
        if let current = model.gesture { model.endGesture(current.id) }
        #expect(model.gesture == nil)
        #expect(model.mood == .idle) // un gesto no cambia el estado
    }

    @Test func dragLoopsUntilReleasedAndStuckGesturesExpire() {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let model = CompanionModel(now: { now })
        var behavior = CharacterPack.Behavior()
        behavior.randomEnabled = false
        model.pack = pack([.drag: [ClipSource(file: "hang.usdz")], .body: [ClipSource(file: "poke.usdz")]], behavior: behavior)

        model.perform(.drag)
        #expect(model.gesture?.loops == true)
        now = now.addingTimeInterval(120)
        model.tick()
        #expect(model.gesture?.reaction == .drag) // en bucle mientras se arrastra
        model.endGesture(of: .body)
        #expect(model.gesture != nil)
        model.endGesture(of: .drag)
        #expect(model.gesture == nil)

        // Si la escena nunca avisa (personaje oculto), el gesto se da por terminado solo.
        model.perform(.body)
        now = now.addingTimeInterval(CompanionModel.gestureTimeout + 1)
        model.tick()
        #expect(model.gesture == nil)
    }

    @Test func randomGesturesOnlyWhenQuietAndDoNotPreventSleep() {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let model = CompanionModel(now: { now })
        var behavior = CharacterPack.Behavior()
        behavior.randomMin = 10
        behavior.randomMax = 10
        model.pack = pack([.random: [ClipSource(file: "stretch.usdz")]], behavior: behavior)

        now = now.addingTimeInterval(9)
        model.tick()
        #expect(model.gesture == nil) // todavía no toca
        now = now.addingTimeInterval(2)
        model.tick()
        #expect(model.gesture?.reaction == .random)
        model.stopGesture()

        // Grabando no hace gestos.
        model.apply(phase: .recording(since: now))
        now = now.addingTimeInterval(11)
        model.tick()
        #expect(model.gesture == nil)
        model.apply(phase: .idle)

        // Apagados en el paquete, tampoco.
        behavior.randomEnabled = false
        model.pack = pack([.random: [ClipSource(file: "stretch.usdz")]], behavior: behavior)
        now = now.addingTimeInterval(11)
        model.tick()
        #expect(model.gesture == nil)

        // Los gestos al azar no cuentan como actividad: se duerme igual y dormido no hace gestos.
        behavior.randomEnabled = true
        model.pack = pack([.random: [ClipSource(file: "stretch.usdz")]], behavior: behavior)
        model.wake()
        for _ in 0 ..< Int(CompanionModel.defaultSleepAfter / 10) + 2 {
            now = now.addingTimeInterval(10)
            model.tick()
            model.stopGesture()
        }
        #expect(model.mood == .sleeping)
        now = now.addingTimeInterval(11)
        model.tick()
        #expect(model.gesture == nil)
    }

    @Test func wakingUpPlaysItsReactionOnce() {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let model = CompanionModel(now: { now })
        var behavior = CharacterPack.Behavior()
        behavior.randomEnabled = false
        model.pack = pack([.wake: [ClipSource(file: "stretch.usdz")]], behavior: behavior)
        model.wake()
        #expect(model.gesture == nil) // ya estaba despierto
        now = now.addingTimeInterval(CompanionModel.defaultSleepAfter + 1)
        model.tick()
        #expect(model.mood == .sleeping)
        model.wake()
        #expect(model.mood == .idle)
        #expect(model.gesture?.reaction == .wake)
    }

    @Test func previewingAClipLoopsForAWhile() {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let model = CompanionModel(now: { now })
        let clip = ClipSource(file: "dance.usdz")
        model.play(clip, loopingFor: 6)
        #expect(model.gesture?.clip == clip)
        #expect(model.gesture?.loops == true)
        #expect(model.gesture?.reaction == nil)
        now = now.addingTimeInterval(7)
        model.tick()
        #expect(model.gesture == nil)
        model.play(clip)
        #expect(model.gesture?.loops == false)
    }
}
