import SwiftUI

/// Crea un proyecto o, si recibe uno, lo edita.
struct NewProjectSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var project: Project?

    @State private var name = ""
    @State private var description = ""
    @State private var context = ""
    @State private var vocabulary: [String] = []
    @State private var newTerm = ""
    @State private var saving = false

    var body: some View {
        Form {
            TextField("Nombre", text: $name)
            TextField("Descripción", text: $description)
            VStack(alignment: .leading) {
                Text("Contexto para Claude").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $context)
                    .font(.body)
                    .frame(minHeight: 120)
                Text("Stack, objetivos, siglas, sistemas… Se usa en cada análisis del proyecto.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                if !vocabulary.isEmpty {
                    FlowChips(items: vocabulary) { term in vocabulary.removeAll { $0 == term } }
                }
                TextField("Agregar término y Enter", text: $newTerm, prompt: Text("Toks"))
                    .onSubmit(addTerm)
            } header: {
                Text("Vocabulario")
            } footer: {
                Text("Nombres de clientes, productos y términos que la transcripción confunde (Toks, Landing, Petco…). Whisper los recibe como pista al transcribir y Claude los escribe así en el análisis.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(project == nil ? "Crear" : "Guardar") {
                    addTerm()
                    saving = true
                    let body = CreateProjectRequest(name: name, description: description, context: context, vocabulary: vocabulary)
                    Task {
                        let ok = if let project { await store.updateProject(id: project.id, body) } else { await store.createProject(body) }
                        if ok { dismiss() }
                        saving = false
                    }
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || saving)
            }
        }
        .onAppear {
            guard let project else { return }
            name = project.name
            description = project.description ?? ""
            context = project.context ?? ""
            vocabulary = project.vocabulary ?? []
        }
    }

    private func addTerm() {
        let term = newTerm.trimmingCharacters(in: .whitespaces)
        newTerm = ""
        guard !term.isEmpty, !vocabulary.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) else { return }
        vocabulary.append(term)
    }
}
