import SwiftUI

struct NewProjectSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var context = ""
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
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Crear") {
                    saving = true
                    Task {
                        if await store.createProject(name: name, description: description, context: context) { dismiss() }
                        saving = false
                    }
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || saving)
            }
        }
    }
}
