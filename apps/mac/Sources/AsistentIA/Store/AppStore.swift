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
    var errorMessage: String?

    private let api = APIClient()
    private var pollTask: Task<Void, Never>?

    var selectedProject: Project? { projects.first { $0.id == selectedProjectId } }

    func loadProjects() async {
        await run {
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

    func reanalyze() async {
        guard let id = selectedSessionId else { return }
        await run { _ = try await api.reanalyze(sessionId: id) }
        await loadDetail()
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
