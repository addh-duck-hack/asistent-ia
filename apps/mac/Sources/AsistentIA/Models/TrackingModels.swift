import Foundation

// Pendientes con seguimiento (GET /api/action-items) y resúmenes semanales
// (GET /api/projects/:id/digests).

enum ItemStatus: String, Codable, CaseIterable, Identifiable {
    case open, inProgress = "in_progress", blocked, done
    var id: String { rawValue }

    var label: String {
        switch self {
        case .open: "Abierto"
        case .inProgress: "En curso"
        case .blocked: "Bloqueado"
        case .done: "Hecho"
        }
    }

    var systemImage: String {
        switch self {
        case .open: "circle"
        case .inProgress: "circle.lefthalf.filled"
        case .blocked: "exclamationmark.octagon"
        case .done: "checkmark.circle.fill"
        }
    }
}

struct TrackedItem: Codable, Identifiable, Hashable {
    struct ProjectRef: Codable, Hashable { let id: String; let name: String
        enum CodingKeys: String, CodingKey { case id = "_id", name } }
    struct SessionRef: Codable, Hashable { let id: String; let title: String; let date: Date
        enum CodingKeys: String, CodingKey { case id = "_id", title, date } }
    struct HistoryEntry: Codable, Hashable {
        let status: String?
        let note: String?
        let at: Date?
        let sessionId: String?
    }

    let id: String
    let task: String
    let owner: String?
    let dueDate: Date?
    let priority: String
    let status: ItemStatus
    let projectId: ProjectRef?
    let sessionId: SessionRef?
    let history: [HistoryEntry]
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id = "_id", task, owner, dueDate, priority, status, projectId, sessionId, history, createdAt
    }

    var isOverdue: Bool {
        guard let dueDate, status != .done else { return false }
        return dueDate < Calendar.current.startOfDay(for: .now)
    }

    /// Necesita intervención: vencido, bloqueado o sin responsable.
    var needsAttention: Bool {
        status != .done && (isOverdue || status == .blocked || owner == nil)
    }
}

struct ActionItemPatch: Encodable {
    var status: ItemStatus?
    var owner: String??
    var note: String?

    // Solo se envían las claves presentes; `owner: .some(nil)` borra el responsable.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(status, forKey: .status)
        if let owner { try c.encode(owner, forKey: .owner) }
        try c.encodeIfPresent(note, forKey: .note)
    }

    enum CodingKeys: String, CodingKey { case status, owner, note }
}

struct DigestResult: Codable {
    struct Decision: Codable, Hashable { let decision: String; let session: String }
    struct Attention: Codable, Hashable { let task: String; let owner: String?; let reason: String }
    struct Risk: Codable, Hashable { let description: String; let severity: String }

    let summary: String
    let highlights: [String]
    let decisions: [Decision]
    let completed: [String]
    let attention: [Attention]
    let risks: [Risk]
    let nextWeekFocus: [String]
}

struct WeeklyDigest: Codable, Identifiable {
    let id: String
    let periodStart: Date
    let periodEnd: Date
    let sessionCount: Int
    let source: String
    let model: String
    let result: DigestResult
    let usage: AnalysisUsage?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id = "_id", periodStart, periodEnd, sessionCount, source, model, result, usage, createdAt
    }

    var periodLabel: String {
        "\(periodStart.formatted(.dateTime.day().month(.abbreviated))) – \(periodEnd.formatted(.dateTime.day().month(.abbreviated).year()))"
    }
}
