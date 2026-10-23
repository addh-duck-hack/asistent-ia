import Foundation
@preconcurrency import SpeakerKit
@preconcurrency import WhisperKit

/// Separa las voces de un audio con SpeakerKit (Pyannote en Core ML, local).
/// Los modelos se descargan una vez junto a los de Whisper.
actor DiarizationService {
    static let shared = DiarizationService()

    private var kit: SpeakerKit?

    func diarize(_ url: URL, speakers: Int? = nil) async throws -> Diarization {
        let kit = try await prepare()
        let audio = try AudioProcessor.loadAudioAsFloatArray(fromPath: url.path)
        let result = try await kit.diarize(audioArray: audio, options: PyannoteDiarizationOptions(numberOfSpeakers: speakers))
        let turns = result.segments.compactMap { seg in
            seg.speaker.speakerId.map { DiarizedTurn(start: Double(seg.startTime), end: Double(seg.endTime), speaker: $0) }
        }
        return Diarization(turns: turns, centroids: result.speakerCentroidEmbeddings)
    }

    private func prepare() async throws -> SpeakerKit {
        if let kit { return kit }
        try FileManager.default.createDirectory(at: TranscriptionService.modelsDirectory, withIntermediateDirectories: true)
        let kit = try await SpeakerKit(PyannoteConfig(
            downloadBase: TranscriptionService.modelsDirectory.path,
            verbose: false,
            logLevel: .error
        ))
        self.kit = kit
        return kit
    }
}
