import Foundation
import Testing
@testable import AsistentIA

private let octavio: [Float] = [1, 0, 0, 0]
private let ana: [Float] = [0, 1, 0, 0]
private let stranger: [Float] = [0, 0, 1, 0]

@Test func assignsEachTextToTheMostOverlappingVoice() {
    let texts = [
        TimedText(start: 0, end: 4, text: "Buenos días"),
        TimedText(start: 4, end: 9, text: "Hoy con los crash"),
        TimedText(start: 20, end: 22, text: "sin diarización aquí"),
    ]
    let turns = [DiarizedTurn(start: 0, end: 3.5, speaker: 0), DiarizedTurn(start: 3.5, end: 5, speaker: 1), DiarizedTurn(start: 5, end: 10, speaker: 0)]
    // El segundo se solapa 1.5 s con la voz 1 y 4 s con la voz 0; el tercero hereda la anterior.
    #expect(SpeakerLabeler.assign(texts, turns: turns) == [0, 0, 0])
    #expect(SpeakerLabeler.assign([TimedText(start: 3.6, end: 4.8, text: "sí")], turns: turns) == [1])
    #expect(SpeakerLabeler.assign([TimedText(start: 50, end: 51, text: "x")], turns: turns) == [nil])
}

@Test func matchesKnownVoicesBelowThreshold() {
    let profiles = [
        VoiceProfile(personId: "u1", name: "Octavio Ramírez", embeddings: [[0.9, 0.1, 0, 0]]),
        VoiceProfile(personId: "u2", name: "Ana López", embeddings: [[0.2, 0.2, 0, 1], ana]),
    ]
    let matched = SpeakerLabeler.match([0: octavio, 1: ana, 2: stranger], profiles: profiles)
    #expect(matched[0]?.name == "Octavio Ramírez")
    #expect(matched[1]?.name == "Ana López") // usa la muestra más parecida
    #expect(matched[2] == nil)
    // La misma persona partida en dos grupos: las dos voces llevan su nombre.
    let split = SpeakerLabeler.match([0: [0.95, 0.05, 0, 0], 1: octavio], profiles: profiles)
    #expect(split[0]?.personId == "u1")
    #expect(split[1]?.personId == "u1")
}

@Test func labelsKnownPeopleAndNumbersUnknownVoicesByAppearance() {
    let texts = [
        TimedText(start: 0, end: 2, text: "Hola"),
        TimedText(start: 2, end: 4, text: "Yo sigo bloqueado"),
        TimedText(start: 4, end: 6, text: "Yo reviso"),
        TimedText(start: 6, end: 8, text: "Ok"),
    ]
    let diarization = Diarization(
        turns: [DiarizedTurn(start: 0, end: 2, speaker: 7), DiarizedTurn(start: 2, end: 4, speaker: 3),
                DiarizedTurn(start: 4, end: 6, speaker: 5), DiarizedTurn(start: 6, end: 8, speaker: 7)],
        centroids: [7: stranger, 3: octavio, 5: [0, 0, 0, 1]]
    )
    let profiles = [VoiceProfile(personId: "u1", name: "Octavio Ramírez", embeddings: [octavio])]
    let (labeled, voices) = SpeakerLabeler.label(texts, diarization: diarization, profiles: profiles)
    #expect(labeled.map(\.speaker) == ["Voz 1", "Octavio Ramírez", "Voz 2", "Voz 1"])
    #expect(voices["Octavio Ramírez"] == octavio)
    #expect(voices["Voz 1"] == stranger)

    // El merger respeta las etiquetas y deja "me" para el micrófono.
    let merged = TranscriptMerger.merge(me: [TimedText(start: 9, end: 10, text: "Gracias a todos")], others: labeled)
    #expect(merged.map(\.speaker) == ["Voz 1", "Octavio Ramírez", "Voz 2", "Voz 1", "me"])
}

@Test func enrollsForgetsAndMovesMisattributedSamples() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "voices-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = VoiceStore(root: root)
    try store.enroll(personId: "u1", name: "Octavio", embedding: octavio)
    try store.enroll(personId: "u1", name: "Octavio Ramírez", embedding: octavio) // repetida: no duplica
    try store.enroll(personId: "u2", name: "Ana", embedding: ana)
    #expect(store.profiles().map(\.name) == ["Octavio Ramírez", "Ana"])
    #expect(store.profiles()[0].embeddings.count == 1)

    // Se había reconocido mal: la muestra de Octavio era de Ana. Pasa a Ana y Octavio se queda sin muestras.
    try store.enroll(personId: "u2", name: "Ana", embedding: octavio)
    #expect(store.profiles().map(\.personId) == ["u2"])
    #expect(store.profiles()[0].embeddings.count == 2)

    for i in 0..<15 { try store.enroll(personId: "u2", name: "Ana", embedding: [Float(i), 1, 1, 1]) }
    #expect(store.profiles()[0].embeddings.count == VoiceStore.maxEmbeddingsPerPerson)

    try store.saveSessionVoices("s1", ["Voz 1": stranger])
    #expect(store.sessionVoices("s1") == ["Voz 1": stranger])
    try store.forget(personId: "u2")
    #expect(store.profiles().isEmpty)
    try store.forgetAll()
    #expect(store.sessionVoices("s1").isEmpty)
}
