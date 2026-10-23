@preconcurrency import AVFoundation
@preconcurrency import ScreenCaptureKit

/// Graba el audio que reproduce la Mac (Teams, Meet, Zoom…) con ScreenCaptureKit.
/// Requiere el permiso "Grabación de pantalla y audio del sistema"; no se guarda video.
final class SystemAudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let sink: AudioFileSink
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "asistent-ia.system-audio")
    private(set) var lastError: Error?

    private let excludeOwnAudio: Bool

    /// - Parameter excludeOwnAudio: false solo en la prueba de audio, para captar
    ///   la frase de prueba que reproduce la propia app.
    init(sink: AudioFileSink, excludeOwnAudio: Bool = true) {
        self.sink = sink
        self.excludeOwnAudio = excludeOwnAudio
    }

    func start() async throws {
        // También dispara el diálogo de permiso la primera vez.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw RecordingError.noDisplay }

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = excludeOwnAudio
        config.sampleRate = 48_000
        config.channelCount = 2
        // Video mínimo: SCStream exige una pantalla, pero no se usa.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
        sink.close()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let buffer = Self.pcmBuffer(from: sampleBuffer) else { return }
        sink.append(buffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lastError = error
    }

    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = sampleBuffer.formatDescription else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList
        )
        return status == noErr ? buffer : nil
    }
}

enum RecordingError: LocalizedError {
    case micDenied
    case noDisplay
    case emptyTranscript

    var errorDescription: String? {
        switch self {
        case .micDenied:
            "Sin permiso de micrófono. Actívalo en Ajustes del Sistema → Privacidad y seguridad → Micrófono."
        case .noDisplay:
            "No se encontró una pantalla para capturar el audio del sistema."
        case .emptyTranscript:
            "La transcripción quedó vacía: no se detectó voz en la grabación."
        }
    }
}
