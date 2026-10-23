import Foundation
import Observation

@MainActor
@Observable
final class AppStore {
    var projects: [Project] = []
    var sessions: [Session] = []
    var selectedProjectId: String?
    var selectedSessionId: String?
    var detail: SessionDetail?
    var profiles: [AnalysisProfile] = []

    enum ProjectTab: String, CaseIterable, Identifiable {
        case sessions = "Sesiones", items = "Pendientes", digests = "Resumen semanal"
        var id: String { rawValue }
    }

    var tab: ProjectTab = .sessions
    var items: [TrackedItem] = []
    var showDoneItems = false
    var selectedItemId: String?
    var digests: [WeeklyDigest] = []
    var selectedDigestId: String?
    var generatingDigest = false

    // MARK: Equipo

    /// Elemento elegido en la barra lateral: un proyecto o una persona.
    enum SidebarItem: Hashable {
        case project(String)
        case person(String)
    }

    enum PersonTab: String, CaseIterable, Identifiable {
        case items = "Pendientes", progress = "Avance", mentions = "Menciones", oneOnOne = "1:1"
        var id: String { rawValue }
    }

    var people: [TeamMember] = []
    var selectedPersonId: String?
    var personTab: PersonTab = .items
    var personItems: [TrackedItem] = []
    var progress: PersonProgress?
    var mentions: [Mention] = []
    var oneOnOnes: [OneOnOnePrep] = []
    var selectedOneOnOneId: String?
    var preparingOneOnOne = false

    var selectedPerson: TeamMember? { people.first { $0.id == selectedPersonId } }
    var selectedOneOnOne: OneOnOnePrep? { oneOnOnes.first { $0.id == selectedOneOnOneId } }

    var sidebar: SidebarItem? {
        get {
            if let selectedPersonId { return .person(selectedPersonId) }
            return selectedProjectId.map { .project($0) }
        }
        set {
            switch newValue {
            case let .project(id):
                selectedPersonId = nil
                selectedProjectId = id
            case let .person(id):
                selectedPersonId = id
            case nil:
                break
            }
        }
    }

    /// El pendiente elegido, venga de la vista del proyecto o de la ficha de la persona.
    var selectedItem: TrackedItem? {
        guard let id = selectedItemId else { return nil }
        let progressItems = progress.map { $0.completed + $0.assigned + $0.stalled + $0.blocked + $0.overdue } ?? []
        return (items + personItems + progressItems).first { $0.id == id }
    }
    var selectedDigest: WeeklyDigest? { digests.first { $0.id == selectedDigestId } }
    var errorMessage: String?

    /// Aviso de éxito (copiado, exportado); `file` permite abrir la nota exportada.
    struct Notice: Identifiable {
        let id = UUID()
        let text: String
        var file: URL?
    }

    var notice: Notice?

    // MARK: Compartir y exportar

    func copy(_ doc: ShareDocument) {
        ShareRenderer.copy(doc)
        notify("Copiado: pégalo en Teams, WhatsApp, Notion o un correo")
    }

    func copy(session: Session) async {
        guard let detail = await sessionDetail(session.id) else { return }
        copy(.session(detail, projectName: projectName(detail.session.projectId), audience: .team))
    }

    func export(session: Session) async {
        guard let exporter = obsidian(), let detail = await sessionDetail(session.id) else { return }
        exportFile { try exporter.exportSession(detail, projectName: projectName(detail.session.projectId) ?? "Sin proyecto") }
    }

    func export(digest: WeeklyDigest) {
        guard let exporter = obsidian() else { return }
        exportFile { try exporter.exportDigest(digest, projectName: selectedProject?.name ?? "Sin proyecto") }
    }

    func export(oneOnOne prep: OneOnOnePrep) {
        guard let exporter = obsidian(), let person = selectedPerson else { return }
        exportFile { try exporter.exportOneOnOne(prep, person: person) }
    }

    /// Todas las sesiones analizadas y los resúmenes del proyecto.
    func export(project: Project) async {
        guard let exporter = obsidian(), !exporting else { return }
        exporting = true
        defer { exporting = false }
        await run {
            let sessions = try await api.sessions(projectId: project.id).filter { $0.status == .done }
            for s in sessions { try exporter.exportSession(try await api.session(id: s.id), projectName: project.name) }
            let digests = try await api.digests(projectId: project.id)
            for d in digests { try exporter.exportDigest(d, projectName: project.name) }
            notify("Exportado a Obsidian: \(sessions.count) sesiones y \(digests.count) resúmenes de \(project.name)",
                   file: exporter.root.appending(path: ObsidianExporter.fileName(project.name)))
        }
    }

    var exporting = false

    private func obsidian() -> ObsidianExporter? {
        guard let root = ObsidianExporter.configuredRoot else {
            errorMessage = "Elige la carpeta de tu vault en Ajustes (⌘,) → Obsidian."
            return nil
        }
        return ObsidianExporter(root: root, people: people)
    }

    private func exportFile(_ work: () throws -> URL) {
        do {
            let url = try work()
            errorMessage = nil
            notify("Exportado a Obsidian: \(url.lastPathComponent)", file: url)
        } catch {
            errorMessage = "No se pudo exportar: \(error.localizedDescription)"
        }
    }

    private func sessionDetail(_ id: String) async -> SessionDetail? {
        if let detail, detail.session.id == id { return detail }
        var fetched: SessionDetail?
        await run { fetched = try await api.session(id: id) }
        return fetched
    }

    private func projectName(_ id: String) -> String? { projects.first { $0.id == id }?.name }

    private func notify(_ text: String, file: URL? = nil) {
        let notice = Notice(text: text, file: file)
        self.notice = notice
        Task {
            try? await Task.sleep(for: .seconds(6))
            if self.notice?.id == notice.id { self.notice = nil }
        }
    }

    // MARK: Eliminar

    /// Lo que el usuario pidió eliminar; ContentView muestra la confirmación.
    enum Deletion: Identifiable {
        case project(Project), person(TeamMember), session(Session), item(TrackedItem), digest(WeeklyDigest), oneOnOne(OneOnOnePrep)

        var id: String {
            switch self {
            case let .project(x): "project-\(x.id)"
            case let .person(x): "person-\(x.id)"
            case let .session(x): "session-\(x.id)"
            case let .item(x): "item-\(x.id)"
            case let .digest(x): "digest-\(x.id)"
            case let .oneOnOne(x): "oneOnOne-\(x.id)"
            }
        }

        var title: String {
            switch self {
            case let .project(x): "¿Eliminar el proyecto “\(x.name)”?"
            case let .person(x): "¿Eliminar a \(x.name)?"
            case let .session(x): "¿Eliminar la sesión “\(x.title)”?"
            case .item: "¿Eliminar este pendiente?"
            case let .digest(x): "¿Eliminar el resumen de \(x.periodLabel)?"
            case .oneOnOne: "¿Eliminar esta preparación de 1:1?"
            }
        }

        var message: String {
            switch self {
            case .project:
                "Se borrarán todas sus sesiones (transcripciones y análisis), sus pendientes y sus resúmenes semanales. Las personas se conservan. No se puede deshacer."
            case .person:
                "Se borrarán sus preparaciones de 1:1 y saldrá de sus proyectos. Sus pendientes se conservan con su nombre, pero sin ligarse a nadie. Para ocultarla sin borrar nada, usa Archivar. No se puede deshacer."
            case .session:
                "Se borrarán su transcripción, su análisis y los pendientes que nacieron en ella. No se puede deshacer."
            case let .item(x):
                "“\(x.task)”. No se puede deshacer."
            case .digest, .oneOnOne:
                "No se puede deshacer."
            }
        }
    }

    var pendingDeletion: Deletion?

    func confirmDeletion(_ deletion: Deletion) async {
        pendingDeletion = nil
        switch deletion {
        case let .project(x):
            guard await run({ try await api.delete("/api/projects/\(x.id)") }) else { return }
            if selectedProjectId == x.id { selectedProjectId = nil; selectedSessionId = nil }
            await loadProjects()
        case let .person(x):
            guard await run({ try await api.delete("/api/people/\(x.id)") }) else { return }
            if selectedPersonId == x.id { selectedPersonId = nil }
            await loadPeople()
        case let .session(x):
            guard await run({ try await api.delete("/api/sessions/\(x.id)") }) else { return }
            if selectedSessionId == x.id { selectedSessionId = nil; detail = nil }
            await loadSessions()
            await loadPeople()
        case let .item(x):
            guard await run({ try await api.delete("/api/action-items/\(x.id)") }) else { return }
            if selectedItemId == x.id { selectedItemId = nil }
            await reloadAfterItemChange()
        case let .digest(x):
            guard let projectId = selectedProjectId,
                  await run({ try await api.delete("/api/projects/\(projectId)/digests/\(x.id)") }) else { return }
            if selectedDigestId == x.id { selectedDigestId = nil }
            await loadDigests()
        case let .oneOnOne(x):
            guard let personId = selectedPersonId,
                  await run({ try await api.delete("/api/people/\(personId)/one-on-ones/\(x.id)") }) else { return }
            if selectedOneOnOneId == x.id { selectedOneOnOneId = nil }
            await loadPersonTab()
        }
    }

    private let api = APIClient()
    private var pollTask: Task<Void, Never>?

    var selectedProject: Project? { projects.first { $0.id == selectedProjectId } }

    func profile(for depth: AnalysisDepth) -> AnalysisProfile? {
        profiles.first { $0.depth == depth }
    }

    func loadProjects() async {
        await run {
            if profiles.isEmpty { profiles = (try? await api.analysisProfiles()) ?? [] }
            projects = try await api.projects()
            if selectedProjectId == nil { selectedProjectId = projects.first?.id }
        }
        await loadPeople()
    }

    func loadPeople() async {
        await run { people = try await api.people() }
    }

    /// Crea o edita una persona. Devuelve false (y deja el mensaje en errorMessage) si falla,
    /// por ejemplo si un alias ya es de otra persona.
    func savePerson(id: String?, _ body: PersonRequest) async -> Bool {
        let ok = await run {
            let saved = if let id { try await api.updatePerson(id: id, body) } else { try await api.createPerson(body) }
            if saved.active != false { selectedPersonId = saved.id }
        }
        if ok {
            await loadPeople()
            if body.active == false { selectedPersonId = nil }
        }
        return ok
    }

    func loadPersonTab() async {
        guard let id = selectedPersonId else { return }
        switch personTab {
        case .items:
            let statuses: [ItemStatus] = showDoneItems ? ItemStatus.allCases : [.open, .inProgress, .blocked]
            await run { personItems = try await api.personItems(personId: id, statuses: statuses) }
        case .progress:
            await run { progress = try await api.progress(personId: id) }
        case .mentions:
            await run { mentions = try await api.mentions(personId: id) }
        case .oneOnOne:
            await run { oneOnOnes = try await api.oneOnOnes(personId: id) }
            if selectedOneOnOneId == nil { selectedOneOnOneId = oneOnOnes.first?.id }
        }
    }

    func prepareOneOnOne() async {
        guard let id = selectedPersonId, !preparingOneOnOne else { return }
        preparingOneOnOne = true
        defer { preparingOneOnOne = false }
        await run {
            let prep = try await api.generateOneOnOne(personId: id)
            oneOnOnes.insert(prep, at: 0)
            selectedOneOnOneId = prep.id
        }
    }

    func assign(_ item: TrackedItem, to personId: String?) async {
        await run { try await api.updateActionItem(id: item.id, ActionItemPatch(ownerId: .some(personId))) }
        await reloadAfterItemChange()
    }

    func createTask(_ body: NewTaskRequest) async -> Bool {
        let ok = await run { try await api.createActionItem(body) }
        if ok { await reloadAfterItemChange() }
        return ok
    }

    private func reloadAfterItemChange() async {
        if selectedPersonId != nil { await loadPersonTab() } else { await loadItems() }
        await loadPeople() // contadores de la barra lateral
    }

    func createProject(name: String, description: String, context: String) async -> Bool {
        await run {
            let project = try await api.createProject(.init(name: name, description: description, context: context))
            projects.append(project)
            projects.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            selectedProjectId = project.id
        }
    }

    /// Recarga lo que muestra la pestaña actual del proyecto.
    func loadTab() async {
        switch tab {
        case .sessions: await loadSessions()
        case .items: await loadItems()
        case .digests: await loadDigests()
        }
    }

    func loadItems() async {
        guard let projectId = selectedProjectId else { items = []; return }
        let statuses: [ItemStatus] = showDoneItems ? ItemStatus.allCases : [.open, .inProgress, .blocked]
        await run { items = try await api.actionItems(projectId: projectId, statuses: statuses) }
        if let id = selectedItemId, !items.contains(where: { $0.id == id }) { selectedItemId = nil }
    }

    func update(_ item: TrackedItem, status: ItemStatus? = nil, note: String? = nil) async {
        await run { try await api.updateActionItem(id: item.id, ActionItemPatch(status: status, note: note)) }
        await reloadAfterItemChange()
    }

    func loadDigests() async {
        guard let projectId = selectedProjectId else { digests = []; return }
        await run { digests = try await api.digests(projectId: projectId) }
        if selectedDigestId == nil { selectedDigestId = digests.first?.id }
    }

    func generateDigest() async {
        guard let projectId = selectedProjectId, !generatingDigest else { return }
        generatingDigest = true
        defer { generatingDigest = false }
        await run {
            let digest = try await api.generateDigest(projectId: projectId)
            digests.insert(digest, at: 0)
            selectedDigestId = digest.id
        }
    }

    /// Abre una sesión concreta (por ejemplo, recién grabada).
    func show(sessionId: String, projectId: String?) async {
        selectedPersonId = nil
        if let projectId, projectId != selectedProjectId {
            selectedProjectId = projectId
        }
        tab = .sessions
        await loadSessions()
        selectedSessionId = sessionId
        await loadDetail()
    }

    func loadSessions() async {
        guard let projectId = selectedProjectId else { sessions = []; return }
        await run { sessions = try await api.sessions(projectId: projectId) }
    }

    func createSession(_ request: CreateSessionRequest) async -> Bool {
        await run {
            let session = try await api.createSession(request)
            sessions.insert(session, at: 0)
            selectedSessionId = session.id
        }
    }

    func reanalyze(depth: AnalysisDepth? = nil) async {
        guard let id = selectedSessionId else { return }
        await run { _ = try await api.reanalyze(sessionId: id, depth: depth) }
        await loadDetail()
        await loadSessions()
    }

    /// Carga el detalle y, mientras el análisis está en cola o en curso,
    /// vuelve a consultar cada 5 s.
    func loadDetail() async {
        pollTask?.cancel()
        guard let id = selectedSessionId else { detail = nil; return }
        await run { detail = try await api.session(id: id) }
        guard detail?.session.status.isInProgress == true else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled, self.selectedSessionId == id else { return }
                guard let fresh = try? await self.api.session(id: id) else { continue }
                self.detail = fresh
                if !fresh.session.status.isInProgress {
                    if fresh.session.status == .done, UserDefaults.standard.bool(forKey: ObsidianExporter.autoExportKey) {
                        await self.export(session: fresh.session)
                    }
                    await self.loadSessions()
                    return
                }
            }
        }
    }

    @discardableResult
    private func run(_ work: () async throws -> Void) async -> Bool {
        do {
            try await work()
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
