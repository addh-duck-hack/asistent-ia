import SwiftUI

/// Lo que se edita de un proyecto: lo comparten el diálogo de nuevo proyecto y la pestaña Configuración.
struct ProjectDraft: Equatable {
    var name = ""
    var description = ""
    var context = ""
    var vocabulary: [String] = []
    var weeklyDigest = true
    var newTerm = ""

    init() {}

    init(_ project: Project) {
        name = project.name
        description = project.description ?? ""
        context = project.context ?? ""
        vocabulary = project.vocabulary ?? []
        weeklyDigest = project.weeklyDigestEnabled
    }

    var isValid: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Pasa el término escrito (si hay) a la lista, sin repetidos sin importar mayúsculas.
    mutating func addTerm() {
        let term = newTerm.trimmingCharacters(in: .whitespaces)
        newTerm = ""
        guard !term.isEmpty, !vocabulary.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) else { return }
        vocabulary.append(term)
    }

    /// Lo que se manda al servidor (con el término a medio escribir ya agregado).
    var request: CreateProjectRequest {
        var copy = self
        copy.addTerm()
        return CreateProjectRequest(name: copy.name.trimmingCharacters(in: .whitespaces), description: copy.description,
                                    context: copy.context, vocabulary: copy.vocabulary, weeklyDigest: copy.weeklyDigest)
    }

    /// Mismo contenido que el proyecto guardado (sin contar el término a medio escribir).
    func matches(_ project: Project) -> Bool {
        var saved = ProjectDraft(project)
        saved.newTerm = newTerm
        return saved == self
    }
}

/// Campos del proyecto. `weeklyDigest` aparece solo si se pasa (en Configuración tiene su propio interruptor).
struct ProjectFields: View {
    @Binding var draft: ProjectDraft
    var showsWeeklyDigest = true

    var body: some View {
        Section {
            TextField("Nombre", text: $draft.name)
            TextField("Descripción", text: $draft.description)
        }
        Section {
            TextEditor(text: $draft.context)
                .font(.body)
                .frame(minHeight: 120)
        } header: {
            Text("Contexto para Claude")
        } footer: {
            Text("Stack, objetivos, siglas, sistemas… Se usa en cada análisis del proyecto.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section {
            if !draft.vocabulary.isEmpty {
                FlowChips(items: draft.vocabulary) { term in draft.vocabulary.removeAll { $0 == term } }
            }
            TextField("Agregar término y Enter", text: $draft.newTerm, prompt: Text("Toks"))
                .onSubmit { draft.addTerm() }
        } header: {
            Text("Vocabulario")
        } footer: {
            Text("Nombres de clientes, productos y términos que la transcripción confunde (Toks, Landing, Petco…). Whisper los recibe como pista al transcribir y Claude los escribe así en el análisis.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if showsWeeklyDigest {
            WeeklyDigestSection(isOn: $draft.weeklyDigest)
        }
    }
}

struct WeeklyDigestSection: View {
    @Binding var isOn: Bool

    var body: some View {
        Section {
            Toggle("Resumen semanal automático", isOn: $isOn)
        } header: {
            Text("Resumen semanal")
        } footer: {
            Text(isOn
                 ? "Cada lunes a las 8:00 se genera el resumen de la semana si el proyecto tuvo sesiones."
                 : "No se genera el resumen de los lunes. Puedes generarlo a mano desde la pestaña Resumen semanal.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Crea un proyecto o, si recibe uno, lo edita.
struct NewProjectSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var project: Project?

    @State private var draft = ProjectDraft()
    @State private var saving = false

    var body: some View {
        Form {
            ProjectFields(draft: $draft)
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(project == nil ? "Crear" : "Guardar") {
                    saving = true
                    let body = draft.request
                    Task {
                        let ok = if let project { await store.updateProject(id: project.id, body) } else { await store.createProject(body) }
                        if ok { dismiss() }
                        saving = false
                    }
                }
                .disabled(!draft.isValid || saving)
            }
        }
        .onAppear {
            if let project { draft = ProjectDraft(project) }
        }
    }
}
