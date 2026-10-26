import AVFoundation
import Foundation
import Testing
@testable import AsistentIA

private let line = "Yo estuve trabajando en la London de Buenfin, de México, de Petco y también unos ajustes para CRM, no, para Tox, las cards de producto."

@Test func replacePreviewFollowsTheBackendRule() {
    // Palabra completa y sin distinguir mayúsculas, igual que el backend.
    #expect(TranscriptReplace.count("Tox", in: "lo de TOX, el tóxico y Tox.") == 2)
    #expect(TranscriptReplace.count("tox", in: "Toxico") == 0)
    var text = TranscriptReplace.apply("London", "Landing", to: line)
    text = TranscriptReplace.apply("CRM, no, para Tox", "CRM, para Toks", to: text)
    #expect(text == "Yo estuve trabajando en la Landing de Buenfin, de México, de Petco y también unos ajustes para CRM, para Toks, las cards de producto.")
    #expect(TranscriptReplace.apply("API", "$1 API", to: "la API") == "la $1 API") // literal
    #expect(TranscriptReplace.count("  ", in: line) == 0)
}

@Test func picksTheLongestSamplesOfAVoice() {
    let segments = [
        Segment(startSec: 0, endSec: 2, speaker: "Voz 1", text: "corto"),
        Segment(startSec: 5, endSec: 20, speaker: "Voz 1", text: "largo"),
        Segment(startSec: 30, endSec: 36, speaker: "Voz 1", text: "medio"),
        Segment(startSec: 40, endSec: 60, speaker: "Voz 2", text: "de otra voz"),
        Segment(startSec: nil, endSec: nil, speaker: "Voz 1", text: "sin tiempos"),
        Segment(startSec: 70, endSec: 73, speaker: "Voz 1", text: "otro"),
    ]
    let clips = Clip.samples(for: "Voz 1", in: segments)
    #expect(clips.map(\.text) == ["largo", "medio", "otro"])
    #expect(clips[0] == Clip(start: 5, end: 13, text: "largo")) // recortado a 8 s
}

@Test func vocabularyPromptAndEchoFilter() {
    #expect(TranscriptionService.vocabularyPrompt([]) == nil)
    #expect(TranscriptionService.vocabularyPrompt([" Toks", "Landing", ""]) == " Glosario: Toks, Landing.")
    let vocabulary = ["Toks", "Landing", "Petco"]
    let items = [
        TimedText(start: 0, end: 2, text: "Glosario: Toks, Landing, Petco."),
        TimedText(start: 2, end: 4, text: "Toks, Landing."),
        TimedText(start: 4, end: 8, text: "Trabajé en la Landing de Toks."),
        TimedText(start: 8, end: 9, text: "Toks."), // un solo término: puede ser una respuesta real
    ]
    #expect(TranscriptMerger.clean(items, vocabulary: vocabulary).map(\.text) == ["Trabajé en la Landing de Toks.", "Toks."])
    #expect(TranscriptMerger.clean(items).count == 4) // sin vocabulario no se filtra nada
}

@Test func compressesPlaysAndPurgesSessionAudio() async throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "session-audio-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    // 5 s de un tono a 16 kHz mono, por el mismo sink que la grabación.
    let sink = try AudioFileSink(url: dir.appending(path: "system.wav"))
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 80_000))
    buffer.frameLength = 80_000
    for i in 0..<80_000 { buffer.floatChannelData![0][i] = 0.3 * sin(Float(i) * 2 * .pi * 440 / 16_000) }
    sink.append(buffer)
    sink.close()

    let store = SessionAudio(root: dir.appending(path: "sessions"))
    try store.save(sessionId: "s1", tracks: [.system: sink.url])
    let url = try #require(store.url(sessionId: "s1", track: .system))
    #expect(store.url(sessionId: "s1", track: .mic) == nil)
    let wavSize = try #require(try FileManager.default.attributesOfItem(atPath: sink.url.path)[.size] as? Int)
    #expect(store.totalBytes() > 0)
    #expect(store.totalBytes() < Int64(wavSize) / 3) // comprimido
    let player = try AVAudioPlayer(contentsOf: url)
    #expect(abs(player.duration - 5) < 0.3)

    store.purge(now: .now.addingTimeInterval(29 * 86_400))
    #expect(store.url(sessionId: "s1", track: .system) != nil)
    store.purge(now: .now.addingTimeInterval(31 * 86_400))
    #expect(store.url(sessionId: "s1", track: .system) == nil)
}

@Test func onlyLocalPhasesCanBeCancelled() {
    #expect(RecordingService.Phase.recording(since: .now).isCancellable)
    #expect(RecordingService.Phase.transcribing(progress: 0.4).isCancellable)
    #expect(RecordingService.Phase.separatingVoices.isCancellable)
    #expect(!RecordingService.Phase.uploading.isCancellable) // la sesión ya se está creando
    #expect(!RecordingService.Phase.idle.isCancellable)
    #expect(!RecordingService.Phase.finished(sessionId: "s").isCancellable)
}
