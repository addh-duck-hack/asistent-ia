import Foundation

// Miembros del equipo (GET /api/people) y su ficha: avance, menciones y 1:1.

struct TeamMember: Codable, Identifiable, Hashable {
    struct Counts: Codable, Hashable { let open: Int; let blocked: Int; let overdue: Int; let doneWeek: Int }

    let id: String
    let name: String
    let role: String?
    let email: String?
    let aliases: [String]
    let active: Bool?
    let projects: [TrackedItem.ProjectRef]?
    let counts: Counts?

    enum CodingKeys: String, CodingKey {
        case id = "_id", name, role, email, aliases, active, projects, counts
    }

    var aliasLine: String? { aliases.isEmpty ? nil : "también: \(aliases.joined(separator: ", "))" }
}

struct PersonRequest: Encodable {
    var name: String
    var role: String
    var email: String
    var aliases: [String]
    var projectIds: [String]
    var active: Bool?
}

struct PersonProgress: Codable {
    let days: Int
    let completed: [TrackedItem]
    let assigned: [TrackedItem]
    let stalled: [TrackedItem]
    let blocked: [TrackedItem]
    let overdue: [TrackedItem]
}

struct Mention: Codable, Identifiable, Hashable {
    struct SessionInfo: Codable, Hashable {
        let id: String
        let title: String
        let date: Date
        let type: SessionType
        let project: TrackedItem.ProjectRef?
        enum CodingKeys: String, CodingKey { case id = "_id", title, date, type, project }
    }

    let session: SessionInfo
    let snippet: String?
    let summary: String?
    var id: String { session.id }
}

struct OneOnOneResult: Codable {
    let summary: String
    let wins: [String]
    let blockers: [String]
    let workloadSignals: String?
    let topics: [String]
    let questions: [String]
}

struct OneOnOnePrep: Codable, Identifiable {
    let id: String
    let periodStart: Date
    let periodEnd: Date
    let result: OneOnOneResult
    let model: String
    let usage: AnalysisUsage?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id = "_id", periodStart, periodEnd, result, model, usage, createdAt
    }
}

struct NewTaskRequest: Encodable {
    let projectId: String
    let task: String
    var ownerId: String?
    var dueDate: Date?
    let priority: String
}
