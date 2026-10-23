import Foundation
@preconcurrency import WhisperKit

/// Transcribe audio localmente con WhisperKit. El modelo se descarga una sola
/// vez a ~/Library/Application Support/AsistentIA/Models y queda cargado en memoria.
actor TranscriptionService {
    static let shared = TranscriptionService()

    /// Modelos ofrecidos en Ajustes (variantes de argmaxinc/whisperkit-coreml).
    static let models: [(id: String, label: String)] = [
        ("large-v3-v20240930_626MB", "Large v3 Turbo (626 MB) — recomendado"),
        ("small", "Small (~250 MB) — más rápido, menos preciso"),
    ]
    static let defaultModel = models[0].id
    static let modelKey = "whisperModel"

    private var pipe: WhisperKit?
    private var loadedModel: String?

    static var modelsDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "AsistentIA/Models", directoryHint: .isDirectory)
    }

    /// Descarga (si hace falta) y carga el modelo. `progress` recibe 0…1 de la descarga.
    func warmUp(progress: @escaping @Sendable (Double) -> Void) async throws {
        _ = try await prepare(progress: progress)
    }

    private func prepare(progress: @escaping @Sendable (Double) -> Void) async throws -> WhisperKit {
        let model = UserDefaults.standard.string(forKey: Self.modelKey) ?? Self.defaultModel
        if let pipe, loadedModel == model { return pipe }

        try FileManager.default.createDirectory(at: Self.modelsDirectory, withIntermediateDirectories: true)
        let folder = try await WhisperKit.download(variant: model, downloadBase: Self.modelsDirectory) { p in
            progress(p.fractionCompleted)
        }
        let pipe = try await WhisperKit(WhisperKitConfig(
            model: model,
            modelFolder: folder.path,
            verbose: false,
            logLevel: .error,
            load: true,
            download: false
        ))
        self.pipe = pipe
        loadedModel = model
        return pipe
    }

    /// Pista para Whisper con el vocabulario del proyecto: lo orienta a escribir
    /// "Toks" o "Landing" en lugar de "Tox" o "London".
    static func vocabularyPrompt(_ vocabulary: [String]) -> String? {
        let terms = vocabulary.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.prefix(40)
        return terms.isEmpty ? nil : " Glosario: \(terms.joined(separator: ", "))."
    }

    /// Transcribe un archivo en español; `progress` recibe 0…1.
    func transcribe(_ url: URL, vocabulary: [String] = [], progress: @escaping @Sendable (Double) -> Void) async throws -> [TimedText] {
        let pipe = try await prepare { _ in }
        var options = DecodingOptions(
            task: .transcribe,
            language: "es",
            skipSpecialTokens: true,
            chunkingStrategy: .vad
        )
        // WhisperKit recorta la pista a lo que cabe y quita los tokens especiales.
        if let prompt = Self.vocabularyPrompt(vocabulary), let tokenizer = pipe.tokenizer {
            options.promptTokens = Array(tokenizer.encode(text: prompt).prefix(100))
        }
        // Reporta el avance mientras corre. WhisperKit reemplaza su `progress` al
        // empezar cada transcripción, así que se lee la propiedad en cada vuelta.
        nonisolated(unsafe) let observed = pipe
        let poller = Task.detached {
            while !Task.isCancelled {
                progress(observed.progress.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        defer { poller.cancel() }

        let results = try await pipe.transcribe(
            audioPath: url.path,
            audioInputOptions: AudioInputOptions(audioLoadingMode: .incremental),
            decodeOptions: options
        )
        progress(1)
        return results
            .flatMap(\.segments)
            .map { TimedText(start: Double($0.start), end: Double($0.end), text: $0.text) }
    }
}
