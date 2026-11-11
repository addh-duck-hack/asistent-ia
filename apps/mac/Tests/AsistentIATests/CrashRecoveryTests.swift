import AVFoundation
import Foundation
import Testing
@testable import AsistentIA

/// Una grabación que se cortó (la app se cerró) deja el WAV sin tamaños en la
/// cabecera: se copia el archivo mientras sigue abierto, como lo encontraría la
/// app al volver a abrirse, y se repara.
@Test func repairsTheHeaderOfAnInterruptedRecording() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "wav-repair-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let sink = try AudioFileSink(url: dir.appending(path: "mic.wav"))
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
    for _ in 0..<5 { // 5 s en bloques, como llega del micrófono
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        for i in 0..<16_000 { buffer.floatChannelData![0][i] = 0.2 * sin(Float(i) * 0.1) }
        sink.append(buffer)
    }
    let crashed = dir.appending(path: "crashed.wav")
    try FileManager.default.copyItem(at: sink.url, to: crashed) // sin close(): cabecera incompleta
    sink.close()

    let before = (try? AVAudioFile(forReading: crashed)).map { Double($0.length) / 16_000 } ?? 0
    #expect(before < 4.5) // sin reparar no se ve todo el audio
    #expect(try WAVRepair.repair(crashed))
    let after = try AVAudioFile(forReading: crashed)
    #expect(abs(Double(after.length) / 16_000 - 5) < 0.3)
    #expect(try !WAVRepair.repair(crashed)) // ya está bien: no toca nada
    #expect(try !WAVRepair.repair(sink.url)) // un WAV bien cerrado no cambia
}

@Test func catchesObjectiveCExceptions() {
    #expect(throws: (any Error).self) {
        try ObjCExceptionCatcher.catching {
            NSException(name: .invalidArgumentException, reason: "formato inválido", userInfo: nil).raise()
        }
    }
    #expect(throws: Never.self) { try ObjCExceptionCatcher.catching {} }
}

@Test func manifestRoundTrip() throws {
    let manifest = RecordingManifest(meta: RecordingMeta(projectId: "p1", title: "Cierre", depth: .quick, vocabulary: ["Toks"], separateVoices: true),
                                     startedAt: Date(timeIntervalSince1970: 1_000))
    let decoded = try JSONDecoder().decode(RecordingManifest.self, from: JSONEncoder().encode(manifest))
    #expect(decoded.meta.title == "Cierre")
    #expect(decoded.meta.vocabulary == ["Toks"])
    #expect(decoded.startedAt == manifest.startedAt)
}
