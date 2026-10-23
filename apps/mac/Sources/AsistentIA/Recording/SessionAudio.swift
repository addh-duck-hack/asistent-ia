import AVFoundation
import Foundation

/// Audio de cada sesión grabada, comprimido (AAC mono de 32 kbps, ~15 MB por
/// hora y pista) en ~/Library/Application Support/AsistentIA/Recordings/sessions.
/// Sirve para escuchar voces y revisar correcciones; se borra a los 30 días.
struct SessionAudio {
    enum Track: String { case mic, system }

    static let retentionDays = 30
    static let shared = SessionAudio(root: URL.applicationSupportDirectory.appending(path: "AsistentIA/Recordings/sessions", directoryHint: .isDirectory))

    let root: URL

    func url(sessionId: String, track: Track) -> URL? {
        let url = root.appending(path: "\(sessionId)/\(track.rawValue).m4a")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Comprime las pistas WAV de la grabación y las guarda con el id de la sesión.
    func save(sessionId: String, tracks: [Track: URL]) throws {
        let folder = root.appending(path: sessionId, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (track, wav) in tracks {
            try Self.compress(wav, to: folder.appending(path: "\(track.rawValue).m4a"))
        }
    }

    func delete(sessionId: String) {
        try? FileManager.default.removeItem(at: root.appending(path: sessionId, directoryHint: .isDirectory))
    }

    func deleteAll() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Borra el audio de las sesiones grabadas hace más de `retentionDays`.
    func purge(now: Date = .now) {
        let limit = now.addingTimeInterval(-Double(Self.retentionDays) * 86_400)
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for folder in folders {
            let created = (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? now
            if created < limit { try? FileManager.default.removeItem(at: folder) }
        }
    }

    /// Tamaño total guardado, para mostrarlo en Ajustes.
    func totalBytes() -> Int64 {
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey])?.allObjects as? [URL] ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    static func compress(_ wav: URL, to m4a: URL) throws {
        let source = try AVAudioFile(forReading: wav)
        let format = source.processingFormat
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitRateKey: 32_000,
        ]
        try? FileManager.default.removeItem(at: m4a)
        let out = try AVAudioFile(forWriting: m4a, settings: settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384) else { return }
        while source.framePosition < source.length {
            try source.read(into: buffer)
            try out.write(from: buffer)
        }
        out.close()
    }
}
