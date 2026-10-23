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

    var selectedItem: TrackedItem? { items.first { $0.id == selectedItemId } }
    var selectedDigest: WeeklyDigest? { digests.first { $0.id == selectedDigestId } }
    var errorMessage: String?

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
        await loadItems()
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
