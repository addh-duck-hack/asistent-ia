import SwiftUI

// MARK: - Barra lateral

struct PersonRow: View {
    let person: TeamMember

    var body: some View {
        HStack {
            Label(person.name, systemImage: "person.crop.circle")
            Spacer()
            if let c = person.counts {
                if c.overdue > 0 {
                    Text("\(c.overdue)").font(.caption.bold()).foregroundStyle(.red)
                        .help("\(c.overdue) vencidos")
                }
                if c.open > 0 {
                    Text("\(c.open)").font(.caption).foregroundStyle(.secondary)
                        .help("\(c.open) pendientes abiertos")
                }
            }
        }
    }
}

/// Personas agrupadas por rol para la barra lateral. "iOS developer" e "iOS
/// Developer" van juntos (con el nombre como se escribió primero); sin rol, al final.
struct TeamGroup: Identifiable, Equatable {
    static let noRole = "Sin rol"

    let role: String
    let people: [TeamMember]
    var id: String { role }

    static func byRole(_ people: [TeamMember]) -> [TeamGroup] {
        var order: [String] = []
        var groups: [String: (label: String, people: [TeamMember])] = [:]
        for p in people {
            let label = p.role?.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? noRole
            let key = label.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            if groups[key] == nil { order.append(key); groups[key] = (label, []) }
            groups[key]!.people.append(p)
        }
        return order
            .map { TeamGroup(role: groups[$0]!.label, people: groups[$0]!.people) }
            .sorted { a, b in
                if (a.role == noRole) != (b.role == noRole) { return b.role == noRole }
                return a.role.localizedCaseInsensitiveCompare(b.role) == .orderedAscending
            }
    }

    /// Roles distintos que ya existen, para sugerirlos al editar.
    static func roles(_ people: [TeamMember]) -> [String] {
        byRole(people).map(\.role).filter { $0 != noRole }
    }
}

struct TeamGroupLabel: View {
    let group: TeamGroup

    var body: some View {
        let overdue = group.people.reduce(0) { $0 + ($1.counts?.overdue ?? 0) }
        HStack {
            Text(group.role).font(.callout.weight(.medium))
            Text("\(group.people.count)").font(.caption).foregroundStyle(.secondary)
            Spacer()
            if overdue > 0 {
                Image(systemName: "exclamationmark.circle.fill").font(.caption).foregroundStyle(.red)
                    .help("\(overdue) pendientes vencidos en este grupo")
            }
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Editor de persona (con alias)

struct PersonEditorSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let person: TeamMember?

    @State private var name = ""
    @State private var role = ""
    @State private var email = ""
    @State private var aliases: [String] = []
    @State private var newAlias = ""
    @State private var projectIds: Set<String> = []
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                TextField("Nombre completo", text: $name, prompt: Text("Octavio Ramírez"))
                HStack {
                    TextField("Rol", text: $role, prompt: Text("iOS Developer, Android Developer, QA…"))
                    let roles = TeamGroup.roles(store.people)
                    if !roles.isEmpty {
                        Menu {
                            ForEach(roles, id: \.self) { r in Button(r) { role = r } }
                        } label: {
                            Image(systemName: "chevron.down.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("Usar un rol que ya existe (agrupa a las personas en la barra lateral)")
                    }
                }
                TextField("Correo", text: $email)
            }
            Section {
                if !aliases.isEmpty {
                    FlowChips(items: aliases) { alias in aliases.removeAll { $0 == alias } }
                }
                TextField("Agregar alias y Enter", text: $newAlias, prompt: Text("Tavo"))
                    .onSubmit(addAlias)
            } header: {
                Text("Alias / apodos")
            } footer: {
                Text("Cómo lo mencionan en reuniones y chats. Claude usará siempre el nombre completo y se ligarán sus pendientes que ya tenían cualquiera de estos nombres.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Proyectos") {
                ForEach(store.projects) { project in
                    Toggle(project.name, isOn: Binding(
                        get: { projectIds.contains(project.id) },
                        set: { on in if on { projectIds.insert(project.id) } else { projectIds.remove(project.id) } }
                    ))
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 560)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
            if let person {
                ToolbarItem(placement: .destructiveAction) {
                    Menu("Quitar") {
                        Button("Archivar (conserva su historial)") { save(active: false) }
                        Button("Eliminar definitivamente…", role: .destructive) {
                            dismiss()
                            store.pendingDeletion = .person(person)
                        }
                    }
                    .fixedSize()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(person == nil ? "Agregar" : "Guardar") { save(active: nil) }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || saving)
            }
        }
        .onAppear {
            guard let person else { return }
            name = person.name
            role = person.role ?? ""
            email = person.email ?? ""
            aliases = person.aliases
            projectIds = Set(person.projects?.map(\.id) ?? [])
        }
    }

    private func addAlias() {
        let alias = newAlias.trimmingCharacters(in: .whitespaces)
        newAlias = ""
        guard !alias.isEmpty, !aliases.contains(where: { $0.caseInsensitiveCompare(alias) == .orderedSame }) else { return }
        aliases.append(alias)
    }

    private func save(active: Bool?) {
        addAlias()
        saving = true
        error = nil
        let body = PersonRequest(
            name: name.trimmingCharacters(in: .whitespaces),
            role: role,
            email: email.trimmingCharacters(in: .whitespaces),
            aliases: aliases,
            projectIds: Array(projectIds),
            active: active
        )
        Task {
            if await store.savePerson(id: person?.id, body) {
                dismiss()
            } else {
                error = store.errorMessage
                store.errorMessage = nil
            }
            saving = false
        }
    }
}

/// Chips con botón para quitar; pasan a la siguiente línea si no caben.
struct FlowChips: View {
    let items: [String]
    let onRemove: (String) -> Void

    var body: some View {
        WrapLayout(spacing: 6) {
            ForEach(items, id: \.self) { item in
                HStack(spacing: 4) {
                    Text(item)
                    Button { onRemove(item) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(.quaternary, in: Capsule())
            }
        }
    }
}

// MARK: - Ficha: columna central

struct PersonContentView: View {
    @Environment(AppStore.self) private var store
    @State private var editing = false
    @State private var newTask = false

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 0) {
            if let person = store.selectedPerson {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(person.name).font(.title3.bold())
                        Text([person.role, person.aliasLine].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                        if let projects = person.projects, !projects.isEmpty {
                            Text(projects.map(\.name).joined(separator: ", ")).font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                    Button("Editar") { editing = true }
                }
                .padding(.horizontal, 12).padding(.top, 10)

                Picker("Vista", selection: $store.personTab) {
                    ForEach(AppStore.PersonTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(8)

                Group {
                    switch store.personTab {
                    case .items: personItems
                    case .progress: PersonProgressView()
                    case .mentions: PersonMentionsView()
                    case .oneOnOne: OneOnOneListView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .sheet(isPresented: $editing) { PersonEditorSheet(person: person) }
                .sheet(isPresented: $newTask) { NewTaskSheet(fixedProjectId: nil, fixedOwnerId: person.id) }
            } else {
                ContentUnavailableView("Selecciona una persona", systemImage: "person.2")
                    .frame(maxHeight: .infinity)
            }
        }
    }

    private var personItems: some View {
        @Bindable var store = store
        let groups = Dictionary(grouping: store.personItems) { $0.projectId?.name ?? "Sin proyecto" }
        return VStack(spacing: 0) {
            if store.personItems.isEmpty {
                ContentUnavailableView("Sin pendientes", systemImage: "checklist")
                    .frame(maxHeight: .infinity)
            } else {
                List(selection: $store.selectedItemId) {
                    ForEach(groups.keys.sorted(), id: \.self) { project in
                        Section("\(project) (\(groups[project]?.count ?? 0))") {
                            ForEach(groups[project] ?? []) { item in
                                ItemRow(item: item).tag(item.id).contextMenu { StatusMenu(item: item) }
                            }
                        }
                    }
                }
            }
            Divider()
            HStack {
                Toggle("Mostrar hechos", isOn: $store.showDoneItems)
                    .toggleStyle(.checkbox)
                    .onChange(of: store.showDoneItems) { Task { await store.loadPersonTab() } }
                Spacer()
                Button { newTask = true } label: { Label("Nueva tarea", systemImage: "plus") }
            }
            .padding(8)
        }
    }
}

private struct PersonProgressView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        if let p = store.progress {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    StatCard(value: p.completed.count, label: "Cerrados", color: .green)
                    StatCard(value: p.assigned.count, label: "Asignados", color: .blue)
                    StatCard(value: p.stalled.count, label: "Estancados", color: .orange)
                    StatCard(value: p.blocked.count + p.overdue.count, label: "Bloq./vencidos", color: .red)
                }
                .padding(.horizontal, 8)
                Text("Últimos \(p.days) días · estancado = abierto sin cambios en más de 7 días")
                    .font(.caption2).foregroundStyle(.secondary).padding(6)
                List(selection: $store.selectedItemId) {
                    section("Cerrados", p.completed)
                    section("Vencidos", p.overdue)
                    section("Bloqueados", p.blocked)
                    section("Estancados", p.stalled)
                    section("Asignados en el periodo", p.assigned)
                }
            }
        } else {
            ProgressView().frame(maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [TrackedItem]) -> some View {
        if !items.isEmpty {
            Section("\(title) (\(items.count))") {
                // id compuesto: un pendiente puede estar en varias secciones.
                ForEach(items, id: \.id) { ItemRow(item: $0).tag($0.id) }
            }
        }
    }
}

private struct StatCard: View {
    let value: Int
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text("\(value)").font(.title2.bold()).foregroundStyle(value > 0 ? color : .secondary)
            Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct PersonMentionsView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        if store.mentions.isEmpty {
            ContentUnavailableView("Sin menciones", systemImage: "text.bubble",
                                   description: Text("Sesiones donde participó o se le nombró (por nombre o alias)."))
                .frame(maxHeight: .infinity)
        } else {
            List(store.mentions) { mention in
                Button {
                    Task { await store.show(sessionId: mention.session.id, projectId: mention.session.project?.id) }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(mention.session.title).font(.headline)
                        Text([
                            mention.session.date.formatted(date: .abbreviated, time: .omitted),
                            mention.session.project?.name,
                        ].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                        if let snippet = mention.snippet {
                            Text(snippet).font(.callout).italic().lineLimit(3)
                        } else if let summary = mention.summary {
                            Text(summary).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 3)
            }
        }
    }
}

private struct OneOnOneListView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            if store.oneOnOnes.isEmpty {
                ContentUnavailableView("Sin preparaciones", systemImage: "person.2.wave.2",
                                       description: Text("Claude revisa sus pendientes y menciones de las últimas 2 semanas y te sugiere temas y preguntas."))
                    .frame(maxHeight: .infinity)
            } else {
                List(store.oneOnOnes, selection: $store.selectedOneOnOneId) { prep in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(prep.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.headline)
                        Text([ModelName.pretty(prep.model), prep.usage?.costUsd.map { Money.usd($0) }].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(prep.id)
                    .contextMenu {
                        Button("Copiar (privado)") { store.copy(.oneOnOne(prep, personName: store.selectedPerson?.name)) }
                        Button("Exportar a Obsidian") { store.export(oneOnOne: prep) }
                        Divider()
                        Button("Eliminar…", role: .destructive) { store.pendingDeletion = .oneOnOne(prep) }
                    }
                }
            }
            Divider()
            Button {
                Task { await store.prepareOneOnOne() }
            } label: {
                if store.preparingOneOnOne {
                    HStack { ProgressView().controlSize(.small); Text("Preparando…") }
                } else {
                    Label("Preparar 1:1", systemImage: "sparkles")
                }
            }
            .disabled(store.preparingOneOnOne)
            .padding(8)
        }
    }
}

// MARK: - Ficha: columna de detalle

struct PersonDetailView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        switch store.personTab {
        case .items, .progress:
            if let item = store.selectedItem {
                ItemDetailView(item: item).id(item.id)
            } else {
                ContentUnavailableView("Selecciona un pendiente", systemImage: "checklist")
            }
        case .mentions:
            ContentUnavailableView("Menciones", systemImage: "text.bubble",
                                   description: Text("Haz clic en una sesión para abrirla."))
        case .oneOnOne:
            if let prep = store.selectedOneOnOne {
                OneOnOneDetailView(prep: prep, person: store.selectedPerson)
            } else {
                ContentUnavailableView("Sin preparación seleccionada", systemImage: "person.2.wave.2")
            }
        }
    }
}

private struct OneOnOneDetailView: View {
    @Environment(AppStore.self) private var store
    let prep: OneOnOnePrep
    let person: TeamMember?

    var body: some View {
        let r = prep.result
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("1:1 con \(person?.name ?? "")").font(.largeTitle.bold())
                    Text("\(prep.periodStart.formatted(date: .abbreviated, time: .omitted)) – \(prep.periodEnd.formatted(date: .abbreviated, time: .omitted))")
                        .foregroundStyle(.secondary)
                }
                Text(r.summary)
                    .font(.title3)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    .textSelection(.enabled)
                list("Temas para el 1:1", "list.number", r.topics)
                list("Preguntas sugeridas", "questionmark.bubble", r.questions)
                list("Logros para reconocer", "star", r.wins)
                list("Bloqueos", "hand.raised", r.blockers)
                if let w = r.workloadSignals {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Carga y ánimo", systemImage: "gauge.with.dots.needle.50percent").font(.headline)
                        Text(w).textSelection(.enabled)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
        }
        .toolbar {
            // Privado: es para tus notas, no para el chat del equipo.
            ShareToolbarButtons(
                copyLabel: "Copiar (privado)",
                copy: { store.copy(.oneOnOne(prep, personName: person?.name)) },
                export: { store.export(oneOnOne: prep) }
            )
        }
    }

    @ViewBuilder
    private func list(_ title: String, _ icon: String, _ items: [String]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: icon).font(.headline)
                ForEach(items, id: \.self) { Text("• \($0)").textSelection(.enabled) }
            }
        }
    }
}

// MARK: - Nueva tarea

struct NewTaskSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// Proyecto fijo (desde Pendientes del proyecto) o persona fija (desde su ficha).
    let fixedProjectId: String?
    let fixedOwnerId: String?

    @State private var task = ""
    @State private var projectId: String?
    @State private var ownerId: String?
    @State private var hasDue = false
    @State private var due = Date.now.addingTimeInterval(86_400)
    @State private var priority = "medium"
    @State private var saving = false

    var body: some View {
        Form {
            TextField("Tarea", text: $task, prompt: Text("Documentar el release de iOS"), axis: .vertical)
            Picker("Proyecto", selection: $projectId) {
                Text("Elige…").tag(String?.none)
                ForEach(store.projects) { Text($0.name).tag(Optional($0.id)) }
            }
            .disabled(fixedProjectId != nil)
            Picker("Responsable", selection: $ownerId) {
                Text("Sin responsable").tag(String?.none)
                ForEach(store.people) { Text($0.name).tag(Optional($0.id)) }
            }
            Toggle("Fecha límite", isOn: $hasDue)
            if hasDue { DatePicker("Vence", selection: $due, displayedComponents: .date) }
            Picker("Prioridad", selection: $priority) {
                Text("Alta").tag("high"); Text("Media").tag("medium"); Text("Baja").tag("low")
            }
            .pickerStyle(.segmented)
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onAppear {
            projectId = fixedProjectId ?? store.selectedPerson?.projects?.first?.id ?? store.selectedProjectId
            ownerId = fixedOwnerId
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Crear") {
                    guard let projectId else { return }
                    saving = true
                    Task {
                        let ok = await store.createTask(NewTaskRequest(
                            projectId: projectId,
                            task: task.trimmingCharacters(in: .whitespacesAndNewlines),
                            ownerId: ownerId,
                            dueDate: hasDue ? due : nil,
                            priority: priority
                        ))
                        saving = false
                        if ok { dismiss() }
                    }
                }
                .disabled(task.trimmingCharacters(in: .whitespaces).isEmpty || projectId == nil || saving)
            }
        }
    }
}

/// Acomoda las vistas en renglones, pasando a la siguiente línea cuando no caben.
struct WrapLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, width: proposal.width ?? .infinity)
        let height = rows.map { $0.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0 }.reduce(0, +)
            + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? rows.map(rowWidth).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            var x = bounds.minX
            let height = row.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
            for view in row {
                let size = view.sizeThatFits(.unspecified)
                view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += height + spacing
        }
    }

    private func rows(for subviews: Subviews, width: CGFloat) -> [[LayoutSubview]] {
        var rows: [[LayoutSubview]] = [[]]
        var x: CGFloat = 0
        for view in subviews {
            let w = view.sizeThatFits(.unspecified).width
            if x > 0, x + w > width { rows.append([]); x = 0 }
            rows[rows.count - 1].append(view)
            x += w + spacing
        }
        return rows
    }

    private func rowWidth(_ row: [LayoutSubview]) -> CGFloat {
        row.map { $0.sizeThatFits(.unspecified).width }.reduce(0, +) + spacing * CGFloat(max(row.count - 1, 0))
    }
}
