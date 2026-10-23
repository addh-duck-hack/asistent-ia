import AVFoundation
import Observation

/// Reproduce un tramo de un audio guardado (extractos de voces y líneas a corregir).
@MainActor
@Observable
final class ClipPlayer {
    static let shared = ClipPlayer()

    /// Identificador de lo que suena ahora, para mostrar ▶︎ o ⏸ en su botón.
    private(set) var playingId: String?
    private var player: AVAudioPlayer?
    private var stopTask: Task<Void, Never>?

    func play(_ url: URL, from start: Double, to end: Double, id: String) {
        stop()
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.currentTime = max(0, start)
        player.play()
        self.player = player
        playingId = id
        stopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0.5, end - start)))
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    func toggle(_ url: URL, from start: Double, to end: Double, id: String) {
        if playingId == id { stop() } else { play(url, from: start, to: end, id: id) }
    }

    func stop() {
        stopTask?.cancel()
        player?.stop()
        player = nil
        playingId = nil
    }
}

/// Tramo de audio de una línea de la transcripción.
struct Clip: Equatable {
    var start: Double
    var end: Double
    var text: String

    /// Los fragmentos más largos de una voz, recortados a `maxSeconds`, para identificarla.
    static func samples(for speaker: String, in segments: [Segment], count: Int = 3, maxSeconds: Double = 8) -> [Clip] {
        segments
            .filter { $0.speaker == speaker }
            .compactMap { s -> Clip? in
                guard let start = s.startSec, let end = s.endSec, end > start else { return nil }
                return Clip(start: start, end: end, text: s.text)
            }
            .sorted { ($0.end - $0.start) > ($1.end - $1.start) } // por duración real, antes de recortar
            .prefix(count)
            .map { Clip(start: $0.start, end: min($0.end, $0.start + maxSeconds), text: $0.text) }
    }
}
