import AVFoundation
import Foundation
import Testing
@testable import AsistentIA

/// Prueba real de punta a punta (sin micrófono): voz sintetizada → AudioFileSink
/// (conversión a 16 kHz) → WhisperKit. Descarga el modelo la primera vez.
/// Solo corre con: TEST_RUNNER_ASISTENT_WHISPER_TEST=1 xcodebuild test …
@Test(.enabled(if: ProcessInfo.processInfo.environment["ASISTENT_WHISPER_TEST"] == "1"), .timeLimit(.minutes(20)))
func transcribesSynthesizedSpanishSpeech() async throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "asistent-whisper-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    // 1. Voz sintetizada en español (formato nativo de `say`: 22 kHz AIFF).
    let aiff = dir.appending(path: "voz.aiff")
    let say = Process()
    say.executableURL = URL(filePath: "/usr/bin/say")
    say.arguments = ["-v", "Eddy (Español (México))", "-o", aiff.path,
                     "Buenos días equipo. Carlos va a terminar las pruebas de pagos el jueves. María sigue bloqueada sin acceso a Stripe."]
    try say.run()
    say.waitUntilExit()
    #expect(say.terminationStatus == 0)

    // 2. Pasa por el mismo sink que usa la grabación.
    let sink = try AudioFileSink(url: dir.appending(path: "mic.wav"))
    let source = try AVAudioFile(forReading: aiff)
    while source.framePosition < source.length {
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 4096))
        try source.read(into: buffer)
        sink.append(buffer)
    }
    sink.close()
    #expect(sink.seconds > 3)

    // 3. Transcripción real.
    let started = Date()
    let segments = try await TranscriptionService.shared.transcribe(sink.url) { _ in }
    let text = segments.map(\.text).joined(separator: " ").lowercased()
    print("Whisper (\(Int(Date().timeIntervalSince(started))) s): \(text)")
    #expect(text.contains("carlos"))
    #expect(text.contains("stripe"))
    #expect(text.contains("jueves"))
}
