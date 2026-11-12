import Foundation
import Testing
@testable import AsistentIA

@Test func decodesCharacterPackWithBaseAndClipForms() throws {
    let json = """
    {"id": "robi", "name": "Robi", "base": "robi.usdz",
     "clips": {"idle": ["idle.usdz", "idle2.usdz"], "listening": "listen.usdz",
               "thinking": {"file": "all.usdz", "start": 0, "end": 2.5}, "desconocido": "x.usdz"},
     "fallbacks": {"happy": "thinking"}}
    """
    let pack = try JSONDecoder().decode(CharacterPack.self, from: Data(json.utf8))
    #expect(pack.format == CharacterPack.currentFormat)
    #expect(pack.baseFile == "robi.usdz")
    #expect(pack.clips[.idle]?.count == 2)
    #expect(pack.clips[.listening] == [ClipSource(file: "listen.usdz")])
    #expect(pack.clips[.thinking] == [ClipSource(file: "all.usdz", start: 0, end: 2.5)])
    #expect(pack.clips.count == 3) // la clave desconocida se ignora
    #expect(pack.camera.distance == 2.3)
    #expect(pack.resolvedMood(for: .happy) == .thinking) // fallback explícito
    #expect(pack.resolvedMood(for: .sad) == .idle) // sin fallback: idle
    #expect(pack.files == ["robi.usdz", "idle.usdz", "idle2.usdz", "listen.usdz", "all.usdz"])
}

@Test func packWithoutBaseUsesFirstClipAndRoundTrips() throws {
    let pack = CharacterPack(id: "p", name: "P", clips: [.talking: [ClipSource(file: "talk.usdz")],
                                                        .idle: [ClipSource(file: "idle.usdz"), ClipSource(file: "all.usdz", start: 1, end: 2)]])
    #expect(pack.baseFile == "idle.usdz")
    let decoded = try JSONDecoder().decode(CharacterPack.self, from: JSONEncoder().encode(pack))
    #expect(decoded == pack)
}

@Test func resolvesFallbackChainAndNil() {
    let pack = CharacterPack(id: "p", name: "P", clips: [.talking: [ClipSource(file: "talk.usdz")]])
    #expect(pack.resolvedMood(for: .talking) == .talking)
    #expect(pack.resolvedMood(for: .happy) == .talking) // happy → talking
    #expect(pack.resolvedMood(for: .alert) == .talking)
    #expect(pack.resolvedMood(for: .sleeping) == nil) // sleeping → idle (no hay) → nada
    #expect(pack.resolveClips(for: .sleeping).isEmpty)
    let cyclic = CharacterPack(id: "c", name: "C", clips: [:], fallbacks: [.idle: .sad, .sad: .idle])
    #expect(cyclic.resolvedMood(for: .idle) == nil) // un ciclo en los fallbacks no cuelga
}

@Test func builtInDuckCoversAllMoods() {
    for mood in CompanionMood.allCases {
        #expect(CharacterPack.builtInDuck.resolvedMood(for: mood) == mood)
    }
    #expect(CharacterPack.builtInDuck.isBuiltIn)
    #expect(InstalledCharacter.duck.isBuiltIn)
    #expect(InstalledCharacter.duck.url(for: "idle") == nil)
}

@Test func mapsFilesByName() {
    let (clips, unmatched) = CharacterImporter.mapByName([
        "Idle.usdz", "sad_idle.usdz", "Happy Jump.usdz", "Waving.usdz", "Thinking.usdz",
        "sleeping_01.usdz", "Talking.usdz", "Escuchando.usdz", "walk.usdz", "textura.png",
    ])
    #expect(clips[.idle] == [ClipSource(file: "Idle.usdz")])
    #expect(clips[.sad] == [ClipSource(file: "sad_idle.usdz")]) // "idle" no gana a "sad"
    #expect(clips[.happy] == [ClipSource(file: "Happy Jump.usdz")])
    #expect(clips[.alert] == [ClipSource(file: "Waving.usdz")])
    #expect(clips[.thinking] == [ClipSource(file: "Thinking.usdz")])
    #expect(clips[.sleeping] == [ClipSource(file: "sleeping_01.usdz")])
    #expect(clips[.talking] == [ClipSource(file: "Talking.usdz")])
    #expect(clips[.listening] == [ClipSource(file: "Escuchando.usdz")])
    #expect(unmatched == ["textura.png", "walk.usdz"])
    #expect(CharacterImporter.slug("Mi Robot Ñoño 2") == "mi-robot-nono-2")
}

@Test func importsFolderWithoutJSONAndRejectsEmpty() throws {
    let base = FileManager.default.temporaryDirectory.appending(path: "characters-\(UUID().uuidString)")
    let source = base.appending(path: "Mi Robot")
    let library = base.appending(path: "library")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try Data("usd".utf8).write(to: source.appending(path: "idle.usdz"))
    try Data("usd".utf8).write(to: source.appending(path: "wave.usdz"))
    try Data("png".utf8).write(to: source.appending(path: "textura.png"))
    defer { try? FileManager.default.removeItem(at: base) }

    let result = try CharacterImporter.importFolder(source, into: library)
    #expect(result.character.id == "mi-robot")
    #expect(result.character.name == "Mi Robot")
    #expect(result.character.folder == library.appending(path: "mi-robot", directoryHint: .isDirectory))
    #expect(result.character.pack.clips[.idle] == [ClipSource(file: "idle.usdz")])
    #expect(result.character.pack.clips[.alert] == [ClipSource(file: "wave.usdz")])
    #expect(result.unmatched.isEmpty)
    #expect(FileManager.default.fileExists(atPath: library.appending(path: "mi-robot/character.json").path))
    #expect(FileManager.default.fileExists(atPath: library.appending(path: "mi-robot/wave.usdz").path))
    // Se vuelve a importar sin error (reemplaza) y la biblioteca lo lista.
    _ = try CharacterImporter.importFolder(source, into: library)
    #expect(CharacterLibrary.packs(in: library).map(\.id) == ["mi-robot"])

    let empty = base.appending(path: "Vacio")
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    try Data("usd".utf8).write(to: empty.appending(path: "walk.usdz"))
    #expect(throws: CharacterImporter.ImportError.self) { try CharacterImporter.importFolder(empty, into: library) }
}
