import AppKit
import SwiftUI

/// Ajustes (⌘,) separados en pestañas.
struct SettingsView: View {
    enum Tab: String {
        case connection, recording, voices, character, obsidian
    }

    @AppStorage("settingsTab") private var tab = Tab.connection

    var body: some View {
        TabView(selection: $tab) {
            ConnectionSettings()
                .tabItem { Label("Conexión", systemImage: "network") }
                .tag(Tab.connection)
            RecordingSettings()
                .tabItem { Label("Grabación", systemImage: "mic") }
                .tag(Tab.recording)
            VoiceSettings()
                .tabItem { Label("Voces", systemImage: "person.wave.2") }
                .tag(Tab.voices)
            CharacterSettings()
                .tabItem { Label("Personaje", systemImage: "sparkles") }
                .tag(Tab.character)
            ObsidianSettings()
                .tabItem { Label("Obsidian", systemImage: "book.closed") }
                .tag(Tab.obsidian)
        }
        .frame(width: 540)
        .captureWindowRouter()
    }
}

/// Cada pestaña: un formulario agrupado del alto de su contenido.
private struct SettingsPane<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 8)
    }
}

private struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: Conexión

private struct ConnectionSettings: View {
    @Environment(AppStore.self) private var store
    @AppStorage(AppSettings.baseURLKey) private var baseURL = AppSettings.defaultBaseURL
    @State private var token = Keychain.read(AppSettings.tokenAccount) ?? ""
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        SettingsPane {
            Section("Backend") {
                TextField("URL", text: $baseURL)
                SecureField("Token del backend", text: $token)
                Caption("Es el API_TOKEN de backend/.env en el servidor, no la llave de Anthropic. Se guarda en el llavero de macOS.")
                if token.hasPrefix("sk-ant-") {
                    Label("Esto es una llave de Anthropic: va solo en el servidor. Aquí pega el API_TOKEN.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Section {
                HStack {
                    Button("Guardar y probar conexión") { saveAndTest() }
                        .disabled(testing || token.hasPrefix("sk-ant-"))
                    if testing { ProgressView().controlSize(.small) }
                    if let testResult { Text(testResult).font(.callout) }
                }
            }
        }
    }

    private func saveAndTest() {
        baseURL = baseURL.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        Keychain.save(token.trimmingCharacters(in: .whitespacesAndNewlines), for: AppSettings.tokenAccount)
        testing = true
        Task {
            defer { testing = false }
            do {
                guard try await APIClient().health() else { testResult = "⚠️ El backend responde pero sin Mongo"; return }
                _ = try await APIClient().projects()
                testResult = "✅ Conectado"
                await store.loadProjects()
            } catch {
                testResult = "❌ \(error.localizedDescription)"
            }
        }
    }
}

// MARK: Grabación

private struct RecordingSettings: View {
    @AppStorage(TranscriptionService.modelKey) private var whisperModel = TranscriptionService.defaultModel
    @AppStorage(RecordingService.keepAudioKey) private var keepAudio = false
    @AppStorage(RecordingService.voiceProcessingKey) private var voiceProcessing = false
    @AppStorage(AudioDevices.selectedMicKey) private var micUID = ""
    @State private var audioBytes = SessionAudio.shared.totalBytes()

    var body: some View {
        SettingsPane {
            Section("Transcripción") {
                Picker("Modelo", selection: $whisperModel) {
                    ForEach(TranscriptionService.models, id: \.id) { Text($0.label).tag($0.id) }
                }
                Caption("Se transcribe en esta Mac; el audio no sale del equipo.")
            }
            Section("Micrófono") {
                Picker("Micrófono", selection: $micUID) {
                    Text("Predeterminado del sistema").tag("")
                    ForEach(AudioDevices.inputs()) { Text($0.name).tag($0.uid) }
                }
                Toggle("Cancelación de eco", isOn: $voiceProcessing)
                Caption("Experimental: con algunos micrófonos deja la grabación en silencio.")
            }
            Section("Audio guardado") {
                LabeledContent("Audio de las llamadas") {
                    HStack {
                        Text(ByteCountFormatter.string(fromByteCount: audioBytes, countStyle: .file)).foregroundStyle(.secondary)
                        Button("Borrar", role: .destructive) {
                            SessionAudio.shared.deleteAll()
                            audioBytes = 0
                        }
                        .disabled(audioBytes == 0)
                    }
                }
                Caption("Se guarda comprimido \(SessionAudio.retentionDays) días para escuchar las voces y revisar correcciones; después se borra solo.")
                Toggle("Conservar también los WAV originales después de subir", isOn: $keepAudio)
                Button("Mostrar grabaciones en Finder") {
                    try? FileManager.default.createDirectory(at: RecordingService.recordingsDirectory, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(RecordingService.recordingsDirectory)
                }
            }
        }
    }
}

// MARK: Voces

private struct VoiceSettings: View {
    @AppStorage(VoiceStore.enabledKey) private var diarize = true
    @State private var voiceProfiles = VoiceStore.shared.profiles()

    var body: some View {
        SettingsPane {
            Section {
                Toggle("Separar las voces de la llamada y reconocer a cada persona", isOn: $diarize)
                Caption("Al confirmar quién es cada voz en una sesión, su huella se guarda solo en esta Mac (nunca se sube) y la próxima vez se reconoce sola. La primera vez descarga el modelo de separación.")
            }
            Section("Huellas guardadas") {
                if voiceProfiles.isEmpty {
                    Text("Sin huellas guardadas.").foregroundStyle(.secondary)
                } else {
                    ForEach(voiceProfiles, id: \.personId) { p in
                        LabeledContent(p.name) {
                            HStack {
                                Text("\(p.embeddings.count) \(p.embeddings.count == 1 ? "muestra" : "muestras")").foregroundStyle(.secondary)
                                Button("Olvidar") {
                                    try? VoiceStore.shared.forget(personId: p.personId)
                                    voiceProfiles = VoiceStore.shared.profiles()
                                }
                            }
                        }
                    }
                    Button("Borrar todas las huellas de voz", role: .destructive) {
                        try? VoiceStore.shared.forgetAll()
                        voiceProfiles = []
                    }
                }
            }
        }
    }
}

// MARK: Personaje

private struct CharacterSettings: View {
    @AppStorage(CompanionController.presenceKey) private var presence = CompanionController.Presence.character.rawValue
    @AppStorage(CharacterLibrary.selectedKey) private var characterId = CharacterPack.builtInId
    @AppStorage(CompanionController.followsCursorKey) private var followsCursor = true
    @AppStorage(CompanionController.birthdaysKey) private var birthdays = true
    @AppStorage(CompanionController.scaleKey) private var characterScale = 1.0
    @State private var characters = CharacterLibrary.installed()
    @State private var importResult: String?

    var body: some View {
        SettingsPane {
            Section("Presencia") {
                Picker("Mostrar", selection: $presence) {
                    ForEach(CompanionController.Presence.allCases) { Text($0.label).tag($0.rawValue) }
                }
                if CompanionController.shared?.isVisible == false, presence != CompanionController.Presence.menuBar.rawValue {
                    Button("Mostrar el personaje ahora") { CompanionController.shared?.show() }
                }
            }
            Section("Apariencia") {
                Picker("Personaje", selection: $characterId) {
                    ForEach(characters) { Text($0.name).tag($0.id) }
                }
                LabeledContent("Tamaño") {
                    HStack {
                        Slider(value: $characterScale, in: CompanionGeometry.minScale ... CompanionGeometry.maxScale, step: 0.05)
                        Text("\(Int((characterScale * 100).rounded())) %").monospacedDigit().frame(width: 48, alignment: .trailing)
                    }
                }
                Caption("También puedes pellizcar el personaje con el trackpad o usar el control de tamaño de su menú.")
                Toggle("Gira hacia el cursor", isOn: $followsCursor)
            }
            Section("Avisos") {
                Toggle("Avisar cumpleaños y aniversarios del equipo", isOn: $birthdays)
            }
            Section("Personajes propios") {
                HStack {
                    Button("Importar carpeta…") { importCharacter() }
                    Button("Mostrar carpeta de personajes") { showCharactersFolder() }
                }
                if let importResult {
                    Text(importResult).font(.caption)
                }
                Caption("Una carpeta con un .usdz por estado (idle, listening, thinking, talking, happy, sad, alert, sleeping), todos con el mismo esqueleto. Los personajes de Unity, Fab, CGTrader o Mixamo se convierten a USDZ con Blender; la guía está en el README de la carpeta de personajes.")
            }
        }
    }

    private func importCharacter() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Importar"
        panel.message = "Elige la carpeta con los .usdz del personaje"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let result = try CharacterImporter.importFolder(url)
            characters = CharacterLibrary.installed()
            characterId = result.character.id
            let moods = CompanionMood.allCases.filter { result.character.pack.clips[$0] != nil }.map(\.label).joined(separator: ", ")
            importResult = "✅ \(result.character.name): \(moods)"
                + (result.unmatched.isEmpty ? "" : " · sin estado: \(result.unmatched.joined(separator: ", "))")
        } catch {
            importResult = "❌ \(error.localizedDescription)"
        }
    }

    private func showCharactersFolder() {
        let folder = CharacterLibrary.userDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let readme = folder.appending(path: "README.md")
        if !FileManager.default.fileExists(atPath: readme.path),
           let bundled = CharacterLibrary.bundledDirectory?.appending(path: "README.md") {
            try? FileManager.default.copyItem(at: bundled, to: readme)
        }
        NSWorkspace.shared.open(folder)
    }
}

// MARK: Obsidian

private struct ObsidianSettings: View {
    @AppStorage(ObsidianExporter.rootKey) private var obsidianRoot = ""
    @AppStorage(ObsidianExporter.autoExportKey) private var obsidianAuto = false

    var body: some View {
        SettingsPane {
            Section("Vault") {
                LabeledContent("Carpeta") {
                    HStack {
                        Text(obsidianRoot.isEmpty ? "Sin elegir" : (obsidianRoot as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(obsidianRoot.isEmpty ? .secondary : .primary)
                        Button("Elegir…") { chooseFolder() }
                    }
                }
                Caption("Una carpeta dentro de tu vault (por ejemplo «Asistente»). Ahí se crean una nota por sesión, los resúmenes y las fichas de las personas. Lo que escribas bajo la línea «fin asistente» se conserva al volver a exportar.")
            }
            Section("Exportación") {
                Toggle("Exportar automáticamente al terminar cada análisis (con la app abierta)", isOn: $obsidianAuto)
                    .disabled(obsidianRoot.isEmpty)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Elegir"
        panel.message = "Elige la carpeta del vault donde se guardarán las notas"
        if !obsidianRoot.isEmpty { panel.directoryURL = URL(fileURLWithPath: obsidianRoot) }
        if panel.runModal() == .OK, let url = panel.url { obsidianRoot = url.path }
    }
}
