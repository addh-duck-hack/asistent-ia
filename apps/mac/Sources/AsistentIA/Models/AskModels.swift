import Foundation

// "Preguntar": conversaciones con Claude sobre el historial (GET /api/conversations).

struct ConversationSummary: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let projectId: String?
    let personId: String?
    let costUsd: Double?
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id = "_id", title, projectId, personId, costUsd, updatedAt
    }
}

struct ConversationMessage: Codable, Identifiable, Hashable {
    let id: String
    let role: String
    let content: String
    let citations: [String]?
    let model: String?
    let toolCalls: Int?
    let usage: Usage?
    let createdAt: Date?

    struct Usage: Codable, Hashable { let costUsd: Double? }

    enum CodingKeys: String, CodingKey {
        case id = "_id", role, content, citations, model, toolCalls, usage, createdAt
    }

    var isUser: Bool { role == "user" }
}

struct Conversation: Codable, Identifiable {
    struct CitedSession: Codable, Hashable {
        let id: String
        let title: String
        let date: Date
        let projectId: String
        enum CodingKeys: String, CodingKey { case id = "_id", title, date, projectId }
    }

    let id: String
    let title: String
    let projectId: String?
    let personId: String?
    let messages: [ConversationMessage]
    let sessions: [CitedSession]
    let costUsd: Double?

    enum CodingKeys: String, CodingKey {
        case id = "_id", title, projectId, personId, messages, sessions, costUsd
    }

    var summary: ConversationSummary {
        ConversationSummary(id: id, title: title, projectId: projectId, personId: personId, costUsd: costUsd, updatedAt: .now)
    }
}

struct NewConversationRequest: Encodable {
    let question: String
    var projectId: String?
    var personId: String?
}

/// Convierte las citas `[[sesion:<id>]]` de una respuesta en enlaces que la app abre.
enum Citations {
    static let scheme = "asistente"

    static func markdown(_ text: String, sessions: [Conversation.CitedSession]) -> String {
        let byId = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        let pattern = /\[\[sesion:([a-fA-F0-9]{24})\]\]/
        return text.replacing(pattern) { match in
            let id = String(match.1).lowercased()
            guard let s = byId[id] else { return "" } // cita a una sesión que ya no existe
            let label = "\(s.title), \(s.date.formatted(.dateTime.day().month(.abbreviated)))"
            return "[↗ \(label.replacingOccurrences(of: "]", with: ")"))](\(scheme)://sesion/\(id))"
        }
    }

    /// Id de sesión de un enlace `asistente://sesion/<id>`.
    static func sessionId(from url: URL) -> String? {
        guard url.scheme == scheme, url.host == "sesion" else { return nil }
        return url.pathComponents.last
    }
}
