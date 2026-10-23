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
