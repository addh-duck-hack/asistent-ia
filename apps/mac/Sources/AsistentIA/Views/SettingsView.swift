import SwiftUI

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @AppStorage(AppSettings.baseURLKey) private var baseURL = AppSettings.defaultBaseURL
    @State private var token = Keychain.read(AppSettings.tokenAccount) ?? ""
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        Form {
            Section("Backend") {
                TextField("URL", text: $baseURL)
                SecureField("Token (API_TOKEN)", text: $token)
                Text("El token se guarda en el llavero de macOS.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Guardar y probar conexión") { saveAndTest() }
                    .disabled(testing)
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
