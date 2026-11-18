import SwiftUI

/// Pestaña Configuración, columna central: resumen semanal y acciones rápidas del proyecto.
struct ProjectSettingsSidebar: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        if let project = store.selectedProject {
            Form {
                WeeklyDigestSection(isOn: Binding(
                    get: { store.selectedProject?.weeklyDigestEnabled ?? true },
                    set: { value in Task { await store.setWeeklyDigest(value, projectId: project.id) } }
                ))
                Section("Acciones") {
                    Button("Preguntar sobre este proyecto…", systemImage: "bubble.left.and.text.bubble.right") {
                        store.startConversation(projectId: project.id)
                    }
                    Button("Exportar proyecto a Obsidian", systemImage: "square.and.arrow.up") {
                        Task { await store.export(project: project) }
                    }
                    .disabled(store.exporting)
                }
                Section {
                    Button("Eliminar proyecto…", systemImage: "trash", role: .destructive) {
                        store.pendingDeletion = .project(project)
                    }
                } footer: {
                    Text("Borra el proyecto con sus sesiones, análisis, pendientes y resúmenes.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .buttonStyle(.borderless)
        } else {
            ContentUnavailableView("Selecciona un proyecto", systemImage: "folder")
        }
    }
}

/// Pestaña Configuración, detalle: nombre, descripción, contexto y vocabulario, con "Guardar cambios".
struct ProjectSettingsDetail: View {
    @Environment(AppStore.self) private var store
    let project: Project

    @State private var draft = ProjectDraft()
    @State private var saving = false

    var body: some View {
        let dirty = !draft.matches(project)
        Form {
            ProjectFields(draft: $draft, showsWeeklyDigest: false)
        }
        .formStyle(.grouped)
        .navigationTitle(project.name)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Descartar") { draft = ProjectDraft(project) }
                    .disabled(!dirty || saving)
                Button("Guardar cambios") {
                    saving = true
                    let body = draft.request
                    Task {
                        if await store.updateProject(id: project.id, body), let saved = store.selectedProject {
                            draft = ProjectDraft(saved)
                        }
                        saving = false
                    }
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!dirty || !draft.isValid || saving)
            }
        }
        .onAppear { draft = ProjectDraft(project) }
        // El interruptor del resumen se guarda aparte: que no cuente como cambio sin guardar.
        .onChange(of: project.weeklyDigestEnabled) { _, new in draft.weeklyDigest = new }
    }
}
