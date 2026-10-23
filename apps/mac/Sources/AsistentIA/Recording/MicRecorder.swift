@preconcurrency import AVFoundation
import AudioToolbox

/// Graba el micrófono elegido (o el predeterminado). Con el procesamiento de voz
/// activado, macOS cancela el eco de las bocinas para que la voz de los demás no
/// se cuele en la pista "Yo".
///
/// AVAudioEngine se detiene solo cuando el dispositivo cambia de formato (por
/// ejemplo, audífonos Bluetooth que pasan a "modo llamada" al empezar Teams) o
/// cuando cambia el micrófono predeterminado. Por eso se escucha esa
/// notificación y se vuelve a arrancar con un engine nuevo.
final class MicRecorder: @unchecked Sendable {
    private let sink: AudioFileSink
    private let lock = NSLock()
    /// Archivos adicionales que reciben el mismo audio (muestra de la prueba de
    /// audio): así no hay que reabrir el micrófono, que con AirPods tarda segundos.
    private let extraLock = NSLock()
    private var extraSinks: [AudioFileSink] = []
    private var engine: AVAudioEngine?
    private var observer: NSObjectProtocol?
    private var deviceUID: String?
    private var stopped = false
    private(set) var voiceProcessing = false
    private(set) var restarts = 0
    /// Nombre del micrófono en uso, para mostrarlo en la interfaz.
    private(set) var deviceName = "—"
    /// Último aviso (por ejemplo, no se pudo activar la cancelación de eco).
    private(set) var note: String?

    init(sink: AudioFileSink) {
        self.sink = sink
    }

    static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }

    /// - Parameters:
    ///   - deviceUID: UID de Core Audio; nil usa el micrófono predeterminado del sistema.
    func start(deviceUID: String?, voiceProcessing: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        self.deviceUID = deviceUID
        stopped = false
        try startEngine(voiceProcessing: voiceProcessing)
    }

    /// Vuelve a arrancar con un engine nuevo. `voiceProcessing` nil conserva el ajuste.
    func restart(voiceProcessing: Bool? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }
        tearDown()
        restarts += 1
        try startEngine(voiceProcessing: voiceProcessing ?? self.voiceProcessing)
    }

    /// Empieza a copiar el audio también a `sink` (sin reiniciar el micrófono).
    func addSink(_ sink: AudioFileSink) {
        extraLock.lock(); defer { extraLock.unlock() }
        extraSinks.append(sink)
    }

    /// Deja de copiar a `sink` y lo cierra.
    func removeSink(_ sink: AudioFileSink) {
        extraLock.lock()
        extraSinks.removeAll { $0 === sink }
        extraLock.unlock()
        sink.close()
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        stopped = true
        tearDown()
        sink.close()
    }

    private func startEngine(voiceProcessing: Bool) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        note = nil

        // 1. Dispositivo: si se eligió uno en Ajustes y sigue conectado.
        let device = deviceUID.flatMap { uid in AudioDevices.inputs().first { $0.uid == uid } }
        if let device {
            guard let unit = input.audioUnit else { throw MicError.deviceUnavailable(device.name) }
            var id = device.id
            let status = AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &id, UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            guard status == noErr else { throw MicError.deviceUnavailable(device.name) }
        }
        deviceName = device?.name ?? AudioDevices.defaultInput()?.name ?? "Micrófono del sistema"

        // 2. Cancelación de eco (opcional; si falla se sigue sin ella).
        self.voiceProcessing = false
        if voiceProcessing {
            do {
                try input.setVoiceProcessingEnabled(true)
                // Sin esto, macOS baja el volumen de la llamada mientras grabamos.
                input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
                self.voiceProcessing = true
            } catch {
                note = "No se pudo activar la cancelación de eco con \(deviceName); se graba sin ella."
            }
        }

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw MicError.deviceUnavailable(deviceName) }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.sink.append(buffer)
            self.extraLock.lock()
            let extras = self.extraSinks
            self.extraLock.unlock()
            for extra in extras { extra.append(buffer) }
        }
        engine.prepare()
        try engine.start()

        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            // Se reinicia fuera del hilo de la notificación.
            DispatchQueue.global(qos: .userInitiated).async {
                try? self.restart()
            }
        }
        self.engine = engine
    }

    private func tearDown() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }
}

enum MicError: LocalizedError {
    case deviceUnavailable(String)

    var errorDescription: String? {
        switch self {
        case let .deviceUnavailable(name):
            "No se pudo usar el micrófono \(name). Revisa que esté conectado o elige otro en Probar audio."
        }
    }
}
