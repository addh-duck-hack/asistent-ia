@preconcurrency import AVFoundation
import os

/// Recibe buffers en cualquier formato, los convierte a 16 kHz mono Float32
/// (lo que espera Whisper) y los escribe en un .wav. Se usa desde los hilos de
/// captura de audio, por eso protege su estado con un lock.
final class AudioFileSink: @unchecked Sendable {
    static let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    let url: URL
    private let file: AVAudioFile
    private let lock = OSAllocatedUnfairLock()
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var _level: Float = 0
    private var _peakLevel: Float = 0
    private var _framesWritten: AVAudioFramePosition = 0
    private var closed = false
    private let createdAt = ProcessInfo.processInfo.systemUptime
    private var lastBufferAt: TimeInterval?
    private var lastSignalAt: TimeInterval?

    init(url: URL) throws {
        self.url = url
        file = try AVAudioFile(
            forWriting: url,
            settings: Self.targetFormat.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
    }

    /// Nivel RMS reciente (0…1) para los medidores de la interfaz.
    var level: Float { lock.withLock { _level } }
    /// Nivel más alto registrado desde que se creó el archivo.
    var peakLevel: Float { lock.withLock { _peakLevel } }
    var seconds: Double { lock.withLock { Double(_framesWritten) / Self.targetFormat.sampleRate } }

    /// Segundos sin recibir audio (el dispositivo dejó de mandar buffers).
    var secondsWithoutBuffers: TimeInterval {
        lock.withLock { ProcessInfo.processInfo.systemUptime - (lastBufferAt ?? createdAt) }
    }

    /// Segundos de silencio digital absoluto (todas las muestras en cero). Un
    /// micrófono que funciona siempre capta algo de ruido aunque nadie hable.
    var secondsWithoutSignal: TimeInterval {
        lock.withLock { ProcessInfo.processInfo.systemUptime - (lastSignalAt ?? createdAt) }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard !closed, buffer.frameLength > 0 else { return }
            if converterInputFormat != buffer.format {
                converter = AVAudioConverter(from: buffer.format, to: Self.targetFormat)
                converterInputFormat = buffer.format
            }
            guard let converter else { return }

            let ratio = Self.targetFormat.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: capacity) else { return }

            var consumed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if consumed {
                    status.pointee = .noDataNow
                    return nil
                }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, out.frameLength > 0 else { return }

            do {
                try file.write(from: out)
                _framesWritten += AVAudioFramePosition(out.frameLength)
            } catch {
                return
            }
            _level = Self.rms(out)
            _peakLevel = max(_peakLevel, _level)
            let now = ProcessInfo.processInfo.systemUptime
            lastBufferAt = now
            if Self.hasSignal(out) { lastSignalAt = now }
        }
    }

    /// Cierra el archivo: AVAudioFile solo escribe la duración en la cabecera del
    /// WAV al cerrarse, y hasta entonces otros lectores (WhisperKit) ven 0 frames.
    func close() {
        lock.withLock {
            guard !closed else { return }
            closed = true
            _level = 0
            file.close()
        }
    }

    private static func hasSignal(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard let data = buffer.floatChannelData?[0] else { return false }
        for i in 0..<Int(buffer.frameLength) where abs(data[i]) > 1e-7 { return true }
        return false
    }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
        // Escala aproximada para que la voz normal llene el medidor.
        return min(1, (sum / Float(buffer.frameLength)).squareRoot() * 6)
    }
}
