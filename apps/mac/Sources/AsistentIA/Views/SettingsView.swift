import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @AppStorage(AppSettings.baseURLKey) private var baseURL = AppSettings.defaultBaseURL
    @State private var token = Keychain.read(AppSettings.tokenAccount) ?? ""
    @State private var testResult: String?
    @State private var testing = false
    @AppStorage(TranscriptionService.modelKey) private var whisperModel = TranscriptionService.defaultModel
    @AppStorage(RecordingService.keepAudioKey) private var keepAudio = false
    @AppStorage(RecordingService.voiceProcessingKey) private var voiceProcessing = false
    @AppStorage(AudioDevices.selectedMicKey) private var micUID = ""
    @AppStorage(VoiceStore.enabledKey) private var diarize = true
    @State private var voiceProfiles = VoiceStore.shared.profiles()
    @AppStorage(ObsidianExporter.rootKey) private var obsidianRoot = ""
    @AppStorage(ObsidianExporter.autoExportKey) private var obsidianAuto = false

    var body: some View {
        Form {
            Section("Backend") {
                TextField("URL", text: $baseURL)
                SecureField("Token del backend", text: $token)
                Text("Es el API_TOKEN de backend/.env en el servidor, no la llave de Anthropic. Se guarda en el llavero de macOS.")
                    .font(.caption).foregroundStyle(.secondary)
                if token.hasPrefix("sk-ant-") {
                    Label("Esto es una llave de Anthropic: va solo en el servidor. Aquí pega el API_TOKEN.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Section("Grabación y transcripción") {
                Picker("Modelo de transcripción", selection: $whisperModel) {
                    ForEach(TranscriptionService.models, id: \.id) { Text($0.label).tag($0.id) }
                }
                Picker("Micrófono", selection: $micUID) {
                    Text("Predeterminado del sistema").tag("")
                    ForEach(AudioDevices.inputs()) { Text($0.name).tag($0.uid) }
                }
                Toggle("Cancelación de eco (experimental: puede dejar el micrófono en silencio)", isOn: $voiceProcessing)
                Toggle("Conservar el audio después de subir la transcripción", isOn: $keepAudio)
                Button("Mostrar grabaciones en Finder") {
                    try? FileManager.default.createDirectory(at: RecordingService.recordingsDirectory, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(RecordingService.recordingsDirectory)
                }
            }
            Section("Voces") {
                Toggle("Separar las voces de la llamada y reconocer a cada persona", isOn: $diarize)
                Text("Al confirmar quién es cada voz en una sesión, su huella se guarda solo en esta Mac (nunca se sube) y la próxima vez se reconoce sola. La primera vez descarga el modelo de separación.")
                    .font(.caption).foregroundStyle(.secondary)
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
            Section("Obsidian") {
                LabeledContent("Carpeta") {
                    HStack {
                        Text(obsidianRoot.isEmpty ? "Sin elegir" : (obsidianRoot as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(obsidianRoot.isEmpty ? .secondary : .primary)
                        Button("Elegir…") { chooseObsidianFolder() }
                    }
                }
                Text("Una carpeta dentro de tu vault (por ejemplo «Asistente»). Ahí se crean una nota por sesión, los resúmenes y las fichas de las personas. Lo que escribas bajo la línea «fin asistente» se conserva al volver a exportar.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Exportar automáticamente al terminar cada análisis (con la app abierta)", isOn: $obsidianAuto)
                    .disabled(obsidianRoot.isEmpty)
            }
            HStack {
                Button("Guardar y probar conexión") { saveAndTest() }
                    .disabled(testing || token.hasPrefix("sk-ant-"))
                if testing { ProgressView().controlSize(.small) }
                if let testResult { Text(testResult).font(.callout) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding()
    }

    private func chooseObsidianFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Elegir"
        panel.message = "Elige la carpeta del vault donde se guardarán las notas"
        if !obsidianRoot.isEmpty { panel.directoryURL = URL(fileURLWithPath: obsidianRoot) }
        if panel.runModal() == .OK, let url = panel.url { obsidianRoot = url.path }
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
