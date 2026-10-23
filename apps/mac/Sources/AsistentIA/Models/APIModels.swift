import Foundation

// Espejo en Swift de lo que devuelve el backend. Los campos del análisis
// replican packages/schema/src/analysis.ts (llegan en snake_case y el decoder
// los convierte a camelCase).

struct Project: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var description: String?
    var context: String?
    var archived: Bool?

    enum CodingKeys: String, CodingKey {
        case id = "_id", name, description, context, archived
    }
}

enum SessionType: String, Codable, CaseIterable, Identifiable {
    case meeting, teamsChat = "teams_chat", pasted
    var id: String { rawValue }
    var label: String {
        switch self {
        case .meeting: "Reunión"
        case .teamsChat: "Chat de Teams"
        case .pasted: "Texto pegado"
        }
    }
}

/// Nivel de análisis: define modelo, effort y extensión (ver /api/analysis-profiles).
enum AnalysisDepth: String, Codable, CaseIterable, Identifiable {
    case quick, standard, deep
    var id: String { rawValue }
    var label: String {
        switch self {
        case .quick: "Rápido"
        case .standard: "Normal"
        case .deep: "Profundo"
        }
    }
    var hint: String {
        switch self {
        case .quick: "Dailies y chats"
        case .standard: "1:1 y seguimientos"
        case .deep: "Clientes y plannings"
        }
    }
}

struct AnalysisProfile: Codable, Identifiable {
    let depth: AnalysisDepth
    let label: String
    let description: String
    let model: String
    let effort: String
    var id: AnalysisDepth { depth }

    /// "claude-sonnet-5-5" → "Sonnet 5.5"
    var modelName: String { ModelName.pretty(model) }
}

enum ModelName {
    static func pretty(_ id: String) -> String {
        let parts = id.replacingOccurrences(of: "claude-", with: "").split(separator: "-")
        guard let family = parts.first else { return id }
        let version = parts.dropFirst().joined(separator: ".")
        return "\(family.prefix(1).uppercased())\(family.dropFirst()) \(version)".trimmingCharacters(in: .whitespaces)
    }
}

enum SessionStatus: String, Codable {
    case pending, analyzing, done, failed

    var label: String {
        switch self {
        case .pending: "En cola"
        case .analyzing: "Analizando"
        case .done: "Listo"
        case .failed: "Falló"
        }
    }

    var isInProgress: Bool { self == .pending || self == .analyzing }
}

struct Session: Codable, Identifiable, Hashable {
    let id: String
    let projectId: String
    let type: SessionType
    let title: String
    let date: Date
    let participants: [String]?
    let depth: AnalysisDepth?
    let status: SessionStatus
    let error: String?
    /// Resumen ejecutivo y costo del último análisis; solo en GET /projects/:id/sessions.
    let summary: String?
    let costUsd: Double?

    enum CodingKeys: String, CodingKey {
        case id = "_id", projectId, type, title, date, participants, depth, status, error, summary, costUsd
    }
}

struct Segment: Codable, Hashable {
    var startSec: Double?
    var endSec: Double?
    var speaker: String?
    var text: String
}

struct Transcript: Codable {
    let text: String
    let segments: [Segment]?
}

struct AnalysisResult: Codable {
    /// `detailed` solo existe en análisis hechos con el prompt analysis-v1.
    struct Summary: Codable { let executive: String; let detailed: String? }
    struct Topic: Codable, Hashable { let title: String; let keyPoints: [String]; let timestamp: String? }
    struct Decision: Codable, Hashable { let decision: String; let decidedBy: String?; let context: String }
    struct ActionItemDraft: Codable, Hashable { let task: String; let owner: String?; let dueDate: String?; let priority: String }
    struct Risk: Codable, Hashable { let description: String; let severity: String; let mitigation: String? }
    struct Blocker: Codable, Hashable { let description: String; let affected: String?; let severity: String }
    struct FollowUp: Codable, Hashable { let actionItemId: String; let status: String; let note: String }
    struct TeamSignals: Codable { let workload: String?; let morale: String?; let dependencies: [String] }

    let summary: Summary
    let topics: [Topic]
    let decisions: [Decision]
    let actionItems: [ActionItemDraft]
    let risks: [Risk]
    let blockers: [Blocker]
    let openQuestions: [String]
    let followupsFromPrevious: [FollowUp]
    let teamSignals: TeamSignals
}

struct AnalysisUsage: Codable {
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheReadInputTokens: Int?
    let cacheCreationInputTokens: Int?
    let costUsd: Double?

    var totalTokens: Int {
        (inputTokens ?? 0) + (outputTokens ?? 0) + (cacheReadInputTokens ?? 0) + (cacheCreationInputTokens ?? 0)
    }
}

struct Analysis: Codable {
    let result: AnalysisResult
    let depth: AnalysisDepth?
    let model: String
    let effort: String?
    let promptVersion: String
    let usage: AnalysisUsage?
    let createdAt: Date
}

enum Money {
    static func usd(_ value: Double) -> String {
        value < 0.01 ? String(format: "$%.4f", value) : String(format: "$%.2f", value)
    }
}

struct ActionItem: Codable, Identifiable, Hashable {
    let id: String
    let task: String
    let owner: String?
    let dueDate: Date?
    let priority: String
    let status: String

    enum CodingKeys: String, CodingKey {
        case id = "_id", task, owner, dueDate, priority, status
    }
}

struct SessionDetail: Codable {
    let session: Session
    let transcript: Transcript?
    let analysis: Analysis?
    let actionItems: [ActionItem]
}

struct CreateProjectRequest: Encodable {
    let name: String
    let description: String
    let context: String
}

struct CreateSessionRequest: Encodable {
    struct TranscriptPayload: Encodable {
        enum Format: String, Encodable { case text, vtt, segments }
        let format: Format
        var content: String?
        var segments: [Segment]?
    }

    let projectId: String
    let type: SessionType
    let title: String
    let date: Date
    var participants: [String]?
    let depth: AnalysisDepth
    let transcript: TranscriptPayload
}
