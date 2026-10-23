import AVFoundation
import Foundation
import Testing
@testable import AsistentIA

/// Prueba real de la separación de voces con dos personas reales alternando
/// (clips de prueba de argmax-oss-swift: JFK en inglés y una voz en español).
/// Las voces sintéticas de `say` no sirven: el segmentador de Pyannote no
/// detecta los cambios de hablante en voz sintetizada.
/// Solo corre con:
///   TEST_RUNNER_ASISTENT_DIARIZATION_FIXTURES=<checkout>/Tests xcodebuild test …
@Test(.enabled(if: ProcessInfo.processInfo.environment["ASISTENT_DIARIZATION_FIXTURES"] != nil), .timeLimit(.minutes(20)))
func separatesTwoRealVoicesAndRecognizesOneAgain() async throws {
    let fixtures = URL(filePath: try #require(ProcessInfo.processInfo.environment["ASISTENT_DIARIZATION_FIXTURES"]))
    let jfk = fixtures.appending(path: "SpeakerKitTests/Resources/jfk.wav")
    let es = fixtures.appending(path: "WhisperKitTests/Resources/es_test_clip.wav")

    let dir = FileManager.default.temporaryDirectory.appending(path: "asistent-diarization-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    // JFK · voz en español · JFK · voz en español, con pausas como en una llamada.
    let sink = try AudioFileSink(url: dir.appending(path: "system.wav"))
    for clip in [jfk, es, jfk, es] {
        let source = try AVAudioFile(forReading: clip)
        while source.framePosition < source.length {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 4096))
            try source.read(into: buffer)
            sink.append(buffer)
        }
        let silence = try #require(AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: AVAudioFrameCount(source.processingFormat.sampleRate * 0.8)))
        silence.frameLength = silence.frameCapacity
        sink.append(silence)
    }
    sink.close()

    let started = Date()
    let texts = try await TranscriptionService.shared.transcribe(sink.url) { _ in }
    let diarization = try await DiarizationService.shared.diarize(sink.url)
    print("Diarización (\(Int(Date().timeIntervalSince(started))) s): \(diarization.centroids.count) voces")
    for turn in diarization.turns { print("  tramo \(turn.speaker): \(turn.start)–\(turn.end)") }

    let first = SpeakerLabeler.label(texts, diarization: diarization, profiles: [])
    for t in first.texts { print("  \(t.speaker ?? "?") [\(t.start)–\(t.end)]: \(t.text)") }
    #expect(Set(first.texts.compactMap(\.speaker)) == ["Voz 1", "Voz 2"])
    for (a, ca) in diarization.centroids { for (b, cb) in diarization.centroids where a < b {
        print("  distancia \(a)–\(b): \(VoiceMath.cosineDistance(ca, cb))")
    } }

    // Con la huella de JFK guardada, la siguiente vez se le reconoce por nombre.
    let jfkVoice = try #require(first.voices["Voz 1"])
    let second = SpeakerLabeler.label(texts, diarization: diarization,
                                      profiles: [VoiceProfile(personId: "u1", name: "John Kennedy", embeddings: [jfkVoice])])
    for t in second.texts { print("  2.ª vez \(t.speaker ?? "?") [\(t.start)–\(t.end)]") }
    // Las dos veces que habla JFK (0–11 s y 20–31 s) se reconocen por nombre.
    #expect(second.texts.filter { $0.start < 31 }.allSatisfy { $0.speaker == "John Kennedy" })
}
