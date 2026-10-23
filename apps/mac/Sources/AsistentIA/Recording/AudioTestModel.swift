@preconcurrency import AVFoundation
import Foundation
import Observation

/// Prueba de audio antes de una reunión: medidores en vivo del micrófono y del
/// audio del sistema, frase de prueba y grabación corta transcrita con Whisper.
@MainActor
@Observable
final class AudioTestModel {
    enum Check: Equatable {
        case waiting, ok, problem(String)
    }

    enum Sample: Equatable {
        case idle
        case recording(secondsLeft: Int)
        case transcribing
        case result(String)
        case failed(String)
    }

    private(set) var devices: [AudioDevice] = []
    private(set) var defaultDeviceName = "—"
    private(set) var micDeviceName = "—"
    private(set) var micLevel: Float = 0
    private(set) var systemLevel: Float = 0
    private(set) var micCheck: Check = .waiting
    private(set) var systemCheck: Check = .waiting
    private(set) var note: String?
    private(set) var sample: Sample = .idle
    private(set) var running = false

    private var mic: MicRecorder?
    private var micSink: AudioFileSink?
    private var system: SystemAudioRecorder?
    private var systemSink: AudioFileSink?
    private var meterTask: Task<Void, Never>?
    private let speech = AVSpeechSynthesizer()
    private let folder = FileManager.default.temporaryDirectory.appending(path: "asistent-audio-test", directoryHint: .isDirectory)

    var selectedUID: String {
        get { UserDefaults.standard.string(forKey: AudioDevices.selectedMicKey) ?? "" }
        set {
            UserDefaults.standard.set(newValue, forKey: AudioDevices.selectedMicKey)
            Task { await restartMic() }
        }
    }

    var voiceProcessing: Bool {
        get { UserDefaults.standard.object(forKey: RecordingService.voiceProcessingKey) as? Bool ?? false }
        set {
            UserDefaults.standard.set(newValue, forKey: RecordingService.voiceProcessingKey)
            Task { await restartMic() }
        }
    }

    func start() async {
        guard !running else { return }
        running = true
        refreshDevices()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        await startMic()
        await startSystem()
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.updateMeters()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    func stop() async {
        meterTask?.cancel()
        meterTask = nil
        speech.stopSpeaking(at: .immediate)
        mic?.stop()
        await system?.stop()
        mic = nil
        system = nil
        micLevel = 0
        systemLevel = 0
        running = false
        try? FileManager.default.removeItem(at: folder)
    }

    func refreshDevices() {
        devices = AudioDevices.inputs()
        defaultDeviceName = AudioDevices.defaultInput()?.name ?? "—"
    }

    /// Reproduce una frase por las bocinas o audífonos: si el medidor de la
    /// llamada se mueve, el audio del sistema se está captando.
    func playTestPhrase() {
        let utterance = AVSpeechUtterance(string: "Prueba de audio de Asistent IA. Si el medidor de la llamada se mueve, todo está bien.")
        utterance.voice = AVSpeechSynthesisVoice(language: "es-MX")
        speech.stopSpeaking(at: .immediate)
        speech.speak(utterance)
    }

    /// Graba 5 s del micrófono y los transcribe: prueba toda la cadena.
    func recordSample() async {
        guard running, !sample.isBusy, let mic else { return }
        do {
            // Copia del micrófono que ya está corriendo: reabrirlo (sobre todo con
            // AirPods) tarda segundos y la muestra quedaba en silencio.
            let sink = try AudioFileSink(url: folder.appending(path: "muestra-\(UUID().uuidString).wav"))
            mic.addSink(sink)
            for left in stride(from: 5, through: 1, by: -1) {
                sample = .recording(secondsLeft: left)
                try await Task.sleep(for: .seconds(1))
            }
            mic.removeSink(sink)
            // Sin señal no se transcribe: Whisper inventa frases sobre el silencio ("Gracias.").
            guard sink.peakLevel >= 0.05 else {
                sample = .failed("No se detectó audio del micrófono en esos 5 s. Revisa el micrófono elegido o desactiva la cancelación de eco.")
                return
            }
            sample = .transcribing
            let segments = try await TranscriptionService.shared.transcribe(sink.url) { _ in }
            let text = TranscriptMerger.clean(segments).map(\.text).joined(separator: " ")
            sample = text.isEmpty
                ? .failed("Hubo sonido pero no se reconoció voz. Habla más cerca del micrófono.")
                : .result(text)
        } catch {
            sample = .failed(error.localizedDescription)
        }
    }

    func clearSample() { sample = .idle }

    // MARK: - Privado

    private func restartMic() async {
        guard running else { return }
        mic?.stop()
        mic = nil
        micCheck = .waiting
        await startMic()
    }

    private func startMic() async {
        guard await MicRecorder.requestPermission() else {
            micCheck = .problem(RecordingError.micDenied.localizedDescription)
            return
        }
        do {
            let sink = try AudioFileSink(url: folder.appending(path: "mic-\(UUID().uuidString).wav"))
            let recorder = MicRecorder(sink: sink)
            try recorder.start(deviceUID: AudioDevices.selected()?.uid, voiceProcessing: voiceProcessing)
            micSink = sink
            mic = recorder
            micDeviceName = recorder.deviceName
            note = recorder.note
        } catch {
            micCheck = .problem(error.localizedDescription)
        }
    }

    private func startSystem() async {
        do {
            let sink = try AudioFileSink(url: folder.appending(path: "system.wav"))
            let recorder = SystemAudioRecorder(sink: sink, excludeOwnAudio: false)
            try await recorder.start()
            systemSink = sink
            system = recorder
        } catch {
            systemCheck = .problem("Falta el permiso de audio del sistema: Ajustes del Sistema → Privacidad y seguridad → Grabación de pantalla y audio del sistema.")
        }
    }

    private func updateMeters() {
        if let micSink, mic != nil {
            micLevel = micSink.level
            if micLevel > 0.08 {
                micCheck = .ok
            } else if micSink.secondsWithoutBuffers > 3 {
                micCheck = .problem("No llega audio de \(micDeviceName).")
            } else if micSink.secondsWithoutSignal > 3 {
                micCheck = .problem("\(micDeviceName) solo manda silencio (¿silenciado o en uso exclusivo por otra app?).")
            }
        }
        if let systemSink, system != nil {
            systemLevel = systemSink.level
            if systemLevel > 0.05 { systemCheck = .ok }
        }
    }
}

private extension AudioTestModel.Sample {
    var isBusy: Bool {
        switch self {
        case .recording, .transcribing: true
        default: false
        }
    }
}
