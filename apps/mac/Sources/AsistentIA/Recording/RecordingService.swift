import AVFoundation
import Foundation
import Observation

/// Datos de la reunión que se va a grabar.
struct RecordingMeta: Sendable {
    var projectId: String
    var title: String
    var depth: AnalysisDepth
    /// Vocabulario del proyecto: pista para Whisper.
    var vocabulary: [String] = []
    /// Separar las voces de la llamada en esta grabación (por defecto, lo de Ajustes).
    var separateVoices = VoiceStore.isEnabled
}

/// Coordina grabar → transcribir localmente → subir al backend.
@MainActor
@Observable
final class RecordingService {
    enum Phase: Equatable {
        case idle
        case recording(since: Date)
        case preparingModel(progress: Double)
        case transcribing(progress: Double)
        case separatingVoices
        case uploading
        case finished(sessionId: String)
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .recording, .preparingModel, .transcribing, .separatingVoices, .uploading: true
            default: false
            }
        }

        /// Se puede cancelar sin enviar nada: grabando o procesando en la Mac
        /// (al subir ya es tarde: la sesión se está creando en el backend).
        var isCancellable: Bool {
            switch self {
            case .recording, .preparingModel, .transcribing, .separatingVoices: true
            default: false
            }
        }
    }

    static let keepAudioKey = "keepRecordings"
    static let voiceProcessingKey = "micVoiceProcessing"

    private(set) var phase: Phase = .idle
    private(set) var micLevel: Float = 0
    private(set) var systemLevel: Float = 0
    /// Aviso no bloqueante (por ejemplo, sin permiso de audio del sistema).
    private(set) var warning: String?
    /// Problema activo con el micrófono durante la grabación (lo detecta el vigilante).
    private(set) var micProblem: String?
    /// Micrófono en uso y reinicios automáticos en esta grabación.
    private(set) var micDeviceName = "—"
    private(set) var micRestarts = 0
    private(set) var meta: RecordingMeta?

    private var mic: MicRecorder?
    private var system: SystemAudioRecorder?
    private var micSink: AudioFileSink?
    private var systemSink: AudioFileSink?
    private var folder: URL?
    private var startedAt: Date?
    private var meterTask: Task<Void, Never>?
    private var processTask: Task<String?, Never>?
    private var lastRecoveryAt: TimeInterval = 0
    private var recoveryAttempts = 0
    private let api = APIClient()

    var isRecording: Bool { if case .recording = phase { true } else { false } }

    static var recordingsDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "AsistentIA/Recordings", directoryHint: .isDirectory)
    }

    func start(_ meta: RecordingMeta) async {
        guard !phase.isBusy else { return }
        warning = nil
        micProblem = nil
        micRestarts = 0
        recoveryAttempts = 0
        guard await MicRecorder.requestPermission() else {
            phase = .failed(RecordingError.micDenied.localizedDescription)
            return
        }
        do {
            let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
                .replacingOccurrences(of: ":", with: "-")
            let folder = Self.recordingsDirectory.appending(path: stamp, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

            let micSink = try AudioFileSink(url: folder.appending(path: "mic.wav"))
            let systemSink = try AudioFileSink(url: folder.appending(path: "system.wav"))
            let mic = MicRecorder(sink: micSink)
            // Desactivada por defecto: en pruebas reales el procesamiento de voz de
            // macOS dejó el micrófono en silencio. El eco ya se quita al unir pistas.
            let voiceProcessing = UserDefaults.standard.object(forKey: Self.voiceProcessingKey) as? Bool ?? false
            try mic.start(deviceUID: AudioDevices.selected()?.uid, voiceProcessing: voiceProcessing)
            micDeviceName = mic.deviceName
            if let note = mic.note { warning = note }

            let system = SystemAudioRecorder(sink: systemSink)
            do {
                try await system.start()
                self.system = system
            } catch {
                // Se puede seguir solo con el micrófono (por ejemplo, reunión presencial).
                warning = "Solo se graba el micrófono: falta el permiso de audio del sistema (Ajustes del Sistema → Privacidad y seguridad → Grabación de pantalla y audio del sistema)."
            }

            self.mic = mic
            self.micSink = micSink
            self.systemSink = systemSink
            self.folder = folder
            self.meta = meta
            startedAt = .now
            phase = .recording(since: .now)
            startMeters()
        } catch {
            phase = .failed("No se pudo iniciar la grabación: \(error.localizedDescription)")
        }
    }

    /// Detiene la grabación, transcribe y sube la sesión. Devuelve el id creado.
    @discardableResult
    func stopAndProcess() async -> String? {
        guard isRecording else { return nil }
        meterTask?.cancel()
        mic?.stop()
        await system?.stop()
        micLevel = 0
        systemLevel = 0
        mic = nil
        system = nil
        return await runProcess()
    }

    /// Reintenta transcribir y subir la última grabación que falló.
    func retry() async {
        guard case .failed = phase, folder != nil else { return }
        await runProcess()
    }

    /// Cancela la grabación o su procesamiento: borra el audio y no envía nada.
    func cancel() async {
        guard phase.isCancellable else { return }
        if isRecording {
            meterTask?.cancel()
            mic?.stop()
            await system?.stop()
            mic = nil
            system = nil
        }
        processTask?.cancel()
        processTask = nil
        if let folder { try? FileManager.default.removeItem(at: folder) }
        micLevel = 0
        systemLevel = 0
        meta = nil
        folder = nil
        startedAt = nil
        micSink = nil
        systemSink = nil
        micProblem = nil
        warning = nil
        phase = .idle
    }

    /// El procesamiento corre en su propia tarea para poder cancelarlo.
    @discardableResult
    private func runProcess() async -> String? {
        let task = Task { await self.process() }
        processTask = task
        return await task.value
    }

    @discardableResult
    private func process() async -> String? {
        guard let meta, let folder, let micSink, let systemSink, let startedAt else { return nil }
        let durationSec = Int(max(micSink.seconds, systemSink.seconds))

        do {
            phase = .preparingModel(progress: 0)
            try await TranscriptionService.shared.warmUp { p in
                Task { @MainActor in if self.phase.isCancellable, self.meta != nil { self.phase = .preparingModel(progress: p) } }
            }
            try Task.checkCancellation()

            // Primero el sistema (lo que dijeron los demás), luego el micrófono.
            let hasSystem = systemSink.seconds > 0.5
            let tracks: [(AudioFileSink, Double)] = hasSystem ? [(systemSink, 0), (micSink, 0.5)] : [(micSink, 0)]
            var results: [URL: [TimedText]] = [:]
            for (sink, offset) in tracks {
                let share = 1.0 / Double(tracks.count)
                phase = .transcribing(progress: offset)
                try Task.checkCancellation()
                results[sink.url] = try await TranscriptionService.shared.transcribe(sink.url, vocabulary: meta.vocabulary) { p in
                    Task { @MainActor in if self.phase.isCancellable, self.meta != nil { self.phase = .transcribing(progress: offset + p * share) } }
                }
            }

            // Separar las voces de la llamada y reconocer a quien ya se conoce. Si
            // falla, se sigue con "Otros" como antes: nunca bloquea la sesión.
            var others = results[systemSink.url] ?? []
            var voices: [String: [Float]] = [:]
            try Task.checkCancellation()
            if hasSystem, !others.isEmpty, meta.separateVoices {
                phase = .separatingVoices
                if let diarization = try? await DiarizationService.shared.diarize(systemSink.url) {
                    (others, voices) = SpeakerLabeler.label(others, diarization: diarization, profiles: VoiceStore.shared.profiles())
                }
            }

            let segments = TranscriptMerger.merge(me: results[micSink.url] ?? [], others: others, vocabulary: meta.vocabulary)
            guard !segments.isEmpty else { throw RecordingError.emptyTranscript }

            // Último punto para cancelar: después ya se crea la sesión.
            try Task.checkCancellation()
            phase = .uploading
            let session = try await api.createSession(CreateSessionRequest(
                projectId: meta.projectId,
                type: .meeting,
                title: meta.title,
                date: startedAt,
                durationSec: durationSec,
                depth: meta.depth,
                transcript: .init(format: .segments, segments: segments)
            ))

            if !voices.isEmpty { try? VoiceStore.shared.saveSessionVoices(session.id, voices) }
            // Copia comprimida (30 días) para escuchar voces y revisar correcciones.
            try? SessionAudio.shared.save(sessionId: session.id,
                                          tracks: hasSystem ? [.mic: micSink.url, .system: systemSink.url] : [.mic: micSink.url])
            if !(UserDefaults.standard.bool(forKey: Self.keepAudioKey)) {
                try? FileManager.default.removeItem(at: folder)
            }
            self.meta = nil
            self.folder = nil
            self.startedAt = nil
            phase = .finished(sessionId: session.id)
            return session.id
        } catch {
            // Cancelado: cancel() ya limpió todo y dejó la fase en reposo.
            if Task.isCancelled || error is CancellationError { return nil }
            // El audio se conserva para poder reintentar.
            phase = .failed("\(error.localizedDescription) El audio quedó en \(folder.path).")
            return nil
        }
    }

    /// Reinicio manual desde la ventana de grabación.
    func restartMic() {
        guard isRecording, let mic else { return }
        do {
            try mic.restart()
            micDeviceName = mic.deviceName
            micProblem = nil
            recoveryAttempts = 0
        } catch {
            micProblem = error.localizedDescription
        }
    }

    func reset() {
        guard !phase.isBusy else { return }
        phase = .idle
        warning = nil
    }

    private func startMeters() {
        meterTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                self.micLevel = self.micSink?.level ?? 0
                self.systemLevel = self.systemSink?.level ?? 0
                tick += 1
                if tick % 10 == 0 { self.checkMicHealth() }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// Vigilante: si el micrófono deja de mandar audio o solo manda ceros,
    /// lo reinicia (la segunda vez sin cancelación de eco) y avisa si no se recupera.
    private func checkMicHealth() {
        guard let mic, let micSink, let startedAt else { return }
        // Gracia al arrancar: los audífonos Bluetooth tardan unos segundos en
        // pasar a "modo llamada"; reiniciarlos en ese momento lo empeora.
        guard Date.now.timeIntervalSince(startedAt) > 10 else { return }
        let noBuffers = micSink.secondsWithoutBuffers > 4
        let digitalSilence = micSink.secondsWithoutSignal > 8
        guard noBuffers || digitalSilence else {
            // Sano: también cuenta los reinicios automáticos por cambio de dispositivo.
            micRestarts = mic.restarts
            micDeviceName = mic.deviceName
            if micProblem != nil { micProblem = nil }
            recoveryAttempts = 0
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastRecoveryAt > 6 else { return }
        lastRecoveryAt = now
        recoveryAttempts += 1

        switch recoveryAttempts {
        case 1:
            try? mic.restart()
        case 2:
            try? mic.restart(voiceProcessing: false)
        default:
            micProblem = noBuffers
                ? "No llega audio de \(mic.deviceName). Revisa el micrófono en Probar audio o pulsa Reiniciar micrófono."
                : "\(mic.deviceName) solo manda silencio. Puede que otra app lo tenga en uso exclusivo o esté silenciado."
            return
        }
        micRestarts = mic.restarts
        micDeviceName = mic.deviceName
        micProblem = "Se perdió el audio de \(mic.deviceName); reiniciando el micrófono…"
    }
}
