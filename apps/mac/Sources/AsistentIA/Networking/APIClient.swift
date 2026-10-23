import Foundation

enum APIError: LocalizedError {
    case notConfigured
    case unauthorized
    case http(Int, String)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Configura la URL del backend y el token en Ajustes."
        case .unauthorized: "Token inválido. Revisa el token en Ajustes."
        case let .http(code, body): "Error \(code) del backend: \(body)"
        case let .message(text): text
        }
    }
}

enum AppSettings {
    static let defaultBaseURL = "https://asistant.duck-hack.cloud"
    static let baseURLKey = "backendBaseURL"
    static let tokenAccount = "apiToken"

    static var baseURL: String {
        UserDefaults.standard.string(forKey: baseURLKey) ?? defaultBaseURL
    }
}

/// Cliente del backend. Toma la URL de UserDefaults y el token del Keychain en
/// cada petición, así un cambio en Ajustes aplica sin reiniciar.
struct APIClient: Sendable {
    var session: URLSession = .shared

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = ISO8601DateFormatter.withFractional.date(from: raw)
                ?? ISO8601DateFormatter.plain.date(from: raw) {
                return date
            }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Fecha inválida: \(raw)"))
        }
        return d
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    func health() async throws -> Bool {
        struct Health: Decodable { let ok: Bool }
        return try await request("/health", authorized: false, as: Health.self).ok
    }

    func projects() async throws -> [Project] {
        try await request("/api/projects", as: [Project].self)
    }

    func createProject(_ body: CreateProjectRequest) async throws -> Project {
        try await request("/api/projects", method: "POST", body: body, as: Project.self)
    }

    func sessions(projectId: String) async throws -> [Session] {
        try await request("/api/projects/\(projectId)/sessions", as: [Session].self)
    }

    func session(id: String) async throws -> SessionDetail {
        try await request("/api/sessions/\(id)", as: SessionDetail.self)
    }

    func createSession(_ body: CreateSessionRequest) async throws -> Session {
        try await request("/api/sessions", method: "POST", body: body, as: Session.self)
    }

    func reanalyze(sessionId: String, depth: AnalysisDepth?) async throws -> Session {
        struct Body: Encodable { let depth: AnalysisDepth? }
        return try await request("/api/sessions/\(sessionId)/reanalyze", method: "POST", body: Body(depth: depth), as: Session.self)
    }

    func actionItems(projectId: String?, statuses: [ItemStatus]) async throws -> [TrackedItem] {
        var q = URLComponents()
        q.queryItems = [URLQueryItem(name: "status", value: statuses.map(\.rawValue).joined(separator: ","))]
        if let projectId { q.queryItems?.append(URLQueryItem(name: "projectId", value: projectId)) }
        return try await request("/api/action-items?\(q.percentEncodedQuery ?? "")", as: [TrackedItem].self)
    }

    func updateActionItem(id: String, _ patch: ActionItemPatch) async throws {
        struct Ignored: Decodable {}
        _ = try await request("/api/action-items/\(id)", method: "PATCH", body: patch, as: Ignored.self)
    }

    func digests(projectId: String) async throws -> [WeeklyDigest] {
        try await request("/api/projects/\(projectId)/digests", as: [WeeklyDigest].self)
    }

    func generateDigest(projectId: String) async throws -> WeeklyDigest {
        struct Body: Encodable { let days = 7 }
        return try await request("/api/projects/\(projectId)/digests", method: "POST", body: Body(), as: WeeklyDigest.self)
    }

    func analysisProfiles() async throws -> [AnalysisProfile] {
        try await request("/api/analysis-profiles", as: [AnalysisProfile].self)
    }

    private struct Empty: Encodable {}

    private func request<T: Decodable>(
        _ path: String, method: String = "GET", authorized: Bool = true, as _: T.Type
    ) async throws -> T {
        try await request(path, method: method, body: Empty?.none, authorized: authorized, as: T.self)
    }

    private func request<T: Decodable, B: Encodable>(
        _ path: String, method: String = "GET", body: B?, authorized: Bool = true, as _: T.Type
    ) async throws -> T {
        guard let url = URL(string: AppSettings.baseURL + path) else { throw APIError.notConfigured }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 180
        if authorized {
            guard let token = Keychain.read(AppSettings.tokenAccount), !token.isEmpty else { throw APIError.notConfigured }
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try Self.encoder.encode(body)
        }
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw APIError.unauthorized }
        guard (200..<300).contains(status) else {
            // Si el backend manda {"message": "..."}, se muestra ese texto.
            if let body = try? JSONDecoder().decode(BackendErrorBody.self, from: data) {
                throw APIError.message(body.message)
            }
            throw APIError.http(status, String(decoding: data.prefix(500), as: UTF8.self))
        }
        return try Self.decoder.decode(T.self, from: data)
    }
}

private struct BackendErrorBody: Decodable {
    let message: String
}

extension ISO8601DateFormatter {
    nonisolated(unsafe) static let withFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) static let plain = ISO8601DateFormatter()
}
