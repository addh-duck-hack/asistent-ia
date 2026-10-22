import SwiftUI
import UniformTypeIdentifiers

struct NewSessionSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var type: SessionType = .pasted
    @State private var date = Date()
    @State private var content = ""
    @State private var isVTT = false
    @State private var importedFile: String?
    @State private var showImporter = false
    @State private var saving = false

    private static let vttType = UTType(filenameExtension: "vtt") ?? .plainText

    var body: some View {
        Form {
            TextField("Título", text: $title, prompt: Text("Daily, 1:1 con Ana, Planning sprint 12…"))
            Picker("Tipo", selection: $type) {
                ForEach(SessionType.allCases) { Text($0.label).tag($0) }
            }
            DatePicker("Fecha", selection: $date)
            Section {
                TextEditor(text: $content)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 260)
                    .onChange(of: content) { _, new in
                        // Si se pega un VTT a mano, se detecta por su cabecera.
                        isVTT = new.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("WEBVTT")
                    }
                    .dropDestination(for: URL.self) { urls, _ in
                        guard let url = urls.first else { return false }
                        load(url)
                        return true
                    }
            } header: {
                HStack {
                    Text("Transcripción o texto")
                    Spacer()
                    if let importedFile { Text(importedFile).foregroundStyle(.secondary) }
                    if isVTT { Text("VTT").font(.caption.bold()).foregroundStyle(.blue) }
                    Button("Importar archivo…") { showImporter = true }
                }
            } footer: {
                Text("Pega el texto o arrastra un .txt o el .vtt que exporta Teams.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 640, height: 600)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [Self.vttType, .plainText, .text]) { result in
            if case let .success(url) = result { load(url) }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Analizar") { submit() }
                    .disabled(!canSubmit || saving)
            }
        }
    }

    private var canSubmit: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty &&
            !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func load(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            store.errorMessage = "No se pudo leer \(url.lastPathComponent) como texto UTF-8."
            return
        }
        content = text
        importedFile = url.lastPathComponent
        if title.isEmpty { title = url.deletingPathExtension().lastPathComponent }
        if url.pathExtension.lowercased() == "vtt" && type == .pasted { type = .meeting }
    }

    private func submit() {
        guard let projectId = store.selectedProjectId else { return }
        saving = true
        let request = CreateSessionRequest(
            projectId: projectId,
            type: type,
            title: title.trimmingCharacters(in: .whitespaces),
            date: date,
            transcript: .init(format: isVTT ? .vtt : .text, content: content)
        )
        Task {
            if await store.createSession(request) { dismiss() }
            saving = false
        }
    }
}
