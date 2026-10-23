import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(AppStore.self) private var store
    @State private var showNewProject = false
    @State private var showNewPerson = false
    @State private var showNewSession = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            List(selection: $store.sidebar) {
                Label("Preguntar", systemImage: "bubble.left.and.text.bubble.right")
                    .tag(AppStore.SidebarItem.ask)
                Section("Proyectos") {
                    ForEach(store.projects) { project in
                        Label(project.name, systemImage: "folder")
                            .tag(AppStore.SidebarItem.project(project.id))
                            .contextMenu {
                                Button("Preguntar sobre este proyecto…") { store.startConversation(projectId: project.id) }
                                Button("Exportar proyecto a Obsidian") { Task { await store.export(project: project) } }
                                    .disabled(store.exporting)
                                Divider()
                                Button("Eliminar proyecto…", role: .destructive) { store.pendingDeletion = .project(project) }
                            }
                    }
                }
                Section {
                    ForEach(store.people) { person in
                        PersonRow(person: person).tag(AppStore.SidebarItem.person(person.id))
                            .contextMenu {
                                Button("Preguntar sobre \(person.name)…") { store.startConversation(personId: person.id) }
                                Divider()
                                Button("Eliminar persona…", role: .destructive) { store.pendingDeletion = .person(person) }
                            }
                    }
                    Button { showNewPerson = true } label: { Label("Agregar persona", systemImage: "person.badge.plus") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Equipo")
                }
            }
            .navigationTitle("Asistent IA")
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            .toolbar {
                Button { showNewProject = true } label: { Label("Nuevo proyecto", systemImage: "folder.badge.plus") }
                Button { openWindow(id: "recorder") } label: { Label("Grabar reunión", systemImage: "record.circle") }
                    .help("Grabar reunión")
            }
        } content: {
            if store.showingAsk {
                ConversationListView()
                    .navigationSplitViewColumnWidth(min: 260, ideal: 300)
            } else if store.selectedPersonId != nil {
                PersonContentView()
                    .navigationSplitViewColumnWidth(min: 300, ideal: 360)
            } else {
                VStack(spacing: 0) {
                    Picker("Vista", selection: $store.tab) {
                        ForEach(AppStore.ProjectTab.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(8)
                    .disabled(store.selectedProjectId == nil)

                    // Ocupa todo el alto: sin esto, una pestaña vacía se centra
                    // verticalmente y arrastra el selector de pestañas al centro.
                    Group {
                        switch store.tab {
                        case .sessions: SessionListView()
                        case .items: ItemsListView()
                        case .digests: DigestListView()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .navigationSplitViewColumnWidth(min: 280, ideal: 340)
                .toolbar {
                    Button { showNewSession = true } label: { Label("Nueva sesión", systemImage: "square.and.pencil") }
                        .disabled(store.selectedProjectId == nil)
                }
            }
        } detail: {
            if store.showingAsk {
                ConversationView()
            } else if store.selectedPersonId != nil {
                PersonDetailView()
            } else {
                switch store.tab {
                case .sessions:
                    if store.selectedSessionId != nil {
                        SessionDetailView()
                    } else {
                        ContentUnavailableView("Selecciona una sesión", systemImage: "text.bubble",
                                               description: Text("O crea una nueva pegando una transcripción."))
                    }
                case .items:
                    if let item = store.selectedItem {
                        ItemDetailView(item: item).id(item.id)
                    } else {
                        ContentUnavailableView("Selecciona un pendiente", systemImage: "checklist",
                                               description: Text("Clic derecho en un pendiente para cambiar su estado."))
                    }
                case .digests:
                    if let digest = store.selectedDigest {
                        DigestDetailView(digest: digest)
                    } else {
                        ContentUnavailableView("Sin resumen seleccionado", systemImage: "calendar")
                    }
                }
            }
        }
        .confirmationDialog(
            store.pendingDeletion?.title ?? "",
            isPresented: Binding(get: { store.pendingDeletion != nil }, set: { if !$0 { store.pendingDeletion = nil } }),
            presenting: store.pendingDeletion
        ) { deletion in
            Button("Eliminar", role: .destructive) { Task { await store.confirmDeletion(deletion) } }
            Button("Cancelar", role: .cancel) { store.pendingDeletion = nil }
        } message: { deletion in
            Text(deletion.message)
        }
        .sheet(isPresented: $showNewProject) { NewProjectSheet() }
        .sheet(isPresented: $showNewPerson) { PersonEditorSheet(person: nil) }
        .sheet(isPresented: $showNewSession) { NewSessionSheet() }
        .overlay(alignment: .bottom) {
            if let notice = store.notice, store.errorMessage == nil {
                NoticeBanner(notice: notice)
            }
            if let message = store.errorMessage {
                Text(message)
                    .font(.callout)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.red.opacity(0.85), in: Capsule())
                    .foregroundStyle(.white)
                    .padding()
                    .onTapGesture { store.errorMessage = nil }
            }
        }
        .task { await store.loadProjects() }
        .onChange(of: store.selectedProjectId) {
            store.selectedSessionId = nil
            store.selectedItemId = nil
            store.selectedDigestId = nil
            Task { await store.loadTab() }
        }
        .onChange(of: store.tab) {
            Task { await store.loadTab() }
        }
        .onChange(of: store.selectedPersonId) {
            store.selectedItemId = nil
            store.selectedOneOnOneId = nil
            store.progress = nil
            Task { await store.loadPersonTab() }
        }
        .onChange(of: store.personTab) {
            store.selectedItemId = nil
            Task { await store.loadPersonTab() }
        }
        .onChange(of: store.selectedSessionId) {
            Task { await store.loadDetail() }
        }
    }
}

struct SessionListView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Group {
            if store.selectedProjectId == nil {
                ContentUnavailableView("Sin proyecto", systemImage: "folder",
                                       description: Text("Crea un proyecto para empezar."))
            } else if store.sessions.isEmpty {
                ContentUnavailableView("Sin sesiones", systemImage: "text.bubble",
                                       description: Text("Pega una transcripción o importa un .vtt de Teams."))
            } else {
                List(store.sessions, selection: $store.selectedSessionId) { session in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(session.title).font(.headline).lineLimit(1)
                            Spacer()
                            StatusBadge(status: session.status)
                        }
                        Text([
                            session.date.formatted(date: .abbreviated, time: .omitted),
                            session.type.label,
                            session.depth?.label,
                            session.costUsd.map { Money.usd($0) },
                        ].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                        if let summary = session.summary {
                            Text(summary).font(.callout).lineLimit(2).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    .tag(session.id)
                    .contextMenu {
                        Button("Copiar para compartir") { Task { await store.copy(session: session) } }
                            .disabled(session.status != .done)
                        Button("Exportar a Obsidian") { Task { await store.export(session: session) } }
                            .disabled(session.status != .done)
                        Divider()
                        Button("Eliminar sesión…", role: .destructive) { store.pendingDeletion = .session(session) }
                    }
                }
            }
        }
        .navigationTitle(store.selectedProject?.name ?? "Sesiones")
        .refreshable { await store.loadSessions() }
    }
}

struct StatusBadge: View {
    let status: SessionStatus

    var body: some View {
        Text(status.label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch status {
        case .pending: .secondary
        case .analyzing: .blue
        case .done: .green
        case .failed: .red
        }
    }
}

/// Aviso de éxito; si hay archivo, permite abrirlo en Obsidian o en Finder.
private struct NoticeBanner: View {
    @Environment(AppStore.self) private var store
    let notice: AppStore.Notice

    var body: some View {
        HStack(spacing: 10) {
            Label(notice.text, systemImage: "checkmark.circle.fill")
            if let file = notice.file {
                Button("Abrir en Obsidian") { NSWorkspace.shared.open(ObsidianLink.url(for: file)) }
                Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
            }
        }
        .font(.callout)
        .buttonStyle(.link)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.green.opacity(0.5)))
        .padding()
        .onTapGesture { store.notice = nil }
    }
}

/// Botones de la barra para copiar y exportar lo que se está viendo.
struct ShareToolbarButtons: View {
    var copyLabel = "Copiar para compartir"
    let copy: () -> Void
    let export: () -> Void

    var body: some View {
        Button(action: copy) { Label(copyLabel, systemImage: "doc.on.doc") }
            .help(copyLabel)
        Button(action: export) { Label("Exportar a Obsidian", systemImage: "square.and.arrow.down.on.square") }
            .help("Exportar a Obsidian")
    }
}
