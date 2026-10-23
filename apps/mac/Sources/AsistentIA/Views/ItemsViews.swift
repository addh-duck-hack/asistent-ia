import SwiftUI

/// Pendientes del proyecto, agrupados por urgencia.
struct ItemsListView: View {
    @Environment(AppStore.self) private var store
    @State private var newTask = false

    var body: some View {
        @Bindable var store = store
        let attention = store.items.filter { $0.needsAttention }
        let inProgress = store.items.filter { !$0.needsAttention && $0.status == .inProgress }
        let open = store.items.filter { !$0.needsAttention && $0.status == .open }
        let done = store.items.filter { $0.status == .done }

        VStack(spacing: 0) {
            if store.items.isEmpty {
                ContentUnavailableView("Sin pendientes", systemImage: "checklist",
                                       description: Text("Los action items de las sesiones aparecen aquí."))
                    .frame(maxHeight: .infinity)
            } else {
                List(selection: $store.selectedItemId) {
                    section("Requieren atención", attention)
                    section("En curso", inProgress)
                    section("Abiertos", open)
                    section("Hechos", done)
                }
            }
            Divider()
            HStack {
                Toggle("Mostrar hechos", isOn: $store.showDoneItems)
                    .toggleStyle(.checkbox)
                    .onChange(of: store.showDoneItems) { Task { await store.loadItems() } }
                Spacer()
                Button { newTask = true } label: { Label("Nueva tarea", systemImage: "plus") }
                    .disabled(store.selectedProjectId == nil)
            }
            .padding(8)
        }
        .sheet(isPresented: $newTask) { NewTaskSheet(fixedProjectId: store.selectedProjectId, fixedOwnerId: nil) }
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [TrackedItem]) -> some View {
        if !items.isEmpty {
            Section("\(title) (\(items.count))") {
                ForEach(items) { item in
                    ItemRow(item: item)
                        .tag(item.id)
                        .contextMenu { StatusMenu(item: item) }
                }
            }
        }
    }
}

struct ItemRow: View {
    let item: TrackedItem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: item.status.systemImage)
                .foregroundStyle(item.status == .blocked ? .red : item.status == .done ? .green : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.task)
                    .strikethrough(item.status == .done)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(item.owner ?? "Sin responsable")
                        .foregroundStyle(item.owner == nil ? .orange : .secondary)
                    if let due = item.dueDate {
                        Text("· vence \(due.formatted(.dateTime.day().month(.abbreviated)))")
                            .foregroundStyle(item.isOverdue ? .red : .secondary)
                    }
                    if let session = item.sessionId {
                        Text("· \(session.title)").foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Menú para cambiar el estado (clic derecho en la lista y en el detalle).
struct StatusMenu: View {
    @Environment(AppStore.self) private var store
    let item: TrackedItem

    var body: some View {
        ForEach(ItemStatus.allCases) { status in
            Button {
                Task { await store.update(item, status: status) }
            } label: {
                Label(status.label, systemImage: status.systemImage)
            }
            .disabled(status == item.status)
        }
    }
}

/// Detalle de un pendiente: estado, origen e historial (lo que Claude detectó en sesiones posteriores).
struct ItemDetailView: View {
    @Environment(AppStore.self) private var store
    let item: TrackedItem
    @State private var note = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(item.task).font(.title2.bold()).textSelection(.enabled)

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        Text("Estado").foregroundStyle(.secondary)
                        Menu {
                            StatusMenu(item: item)
                        } label: {
                            Label(item.status.label, systemImage: item.status.systemImage)
                        }
                        .fixedSize()
                    }
                    GridRow {
                        Text("Responsable").foregroundStyle(.secondary)
                        Menu {
                            Button("Sin responsable") { Task { await store.assign(item, to: nil) } }
                            Divider()
                            ForEach(store.people) { person in
                                Button(person.name) { Task { await store.assign(item, to: person.id) } }
                                    .disabled(person.id == item.ownerId)
                            }
                        } label: {
                            Text(item.owner ?? "Sin responsable")
                                .foregroundStyle(item.owner == nil ? .orange : .primary)
                        }
                        .fixedSize()
                        .help(item.owner != nil && item.ownerId == nil
                              ? "\(item.owner!) no está registrado en el equipo; agrégalo (o como alias) para ligarlo"
                              : "Cambiar responsable")
                    }
                    if let due = item.dueDate {
                        GridRow {
                            Text("Vence").foregroundStyle(.secondary)
                            Text(due.formatted(date: .complete, time: .omitted))
                                .foregroundStyle(item.isOverdue ? .red : .primary)
                        }
                    }
                    GridRow {
                        Text("Prioridad").foregroundStyle(.secondary)
                        Text(item.priority == "high" ? "Alta" : item.priority == "medium" ? "Media" : "Baja")
                    }
                    if item.sessionId == nil {
                        GridRow {
                            Text("Origen").foregroundStyle(.secondary)
                            Text("Tarea manual")
                        }
                    }
                    if let session = item.sessionId {
                        GridRow {
                            Text("Origen").foregroundStyle(.secondary)
                            Button("\(session.title) · \(session.date.formatted(date: .abbreviated, time: .omitted))") {
                                Task { await store.show(sessionId: session.id, projectId: store.selectedProjectId) }
                            }
                            .buttonStyle(.link)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Historial").font(.headline)
                    if item.history.isEmpty {
                        Text("Sin cambios desde que se creó en \(item.createdAt.formatted(date: .abbreviated, time: .omitted)).")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(item.history.enumerated().reversed()), id: \.offset) { _, entry in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                if let s = entry.status.flatMap(ItemStatus.init(rawValue:)) {
                                    Label(s.label, systemImage: s.systemImage).font(.callout.bold())
                                }
                                Spacer()
                                if let at = entry.at {
                                    Text(at.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            if let text = entry.note, !text.isEmpty { Text(text).textSelection(.enabled) }
                            Text(entry.sessionId != nil ? "Detectado por Claude en una sesión" : "Cambio manual")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                        .padding(10)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    }
                }

                HStack {
                    TextField("Agregar nota…", text: $note)
                    Button("Guardar nota") {
                        let text = note
                        note = ""
                        Task { await store.update(item, note: text) }
                    }
                    .disabled(note.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }
}
