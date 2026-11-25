import Foundation

/// Un fallo del análisis guardado en el backend (GET /api/logs).
struct ErrorLogEntry: Codable, Identifiable, Hashable {
    let id: String
    let sessionId: String?
    let projectId: String?
    let title: String?
    let message: String
    let retryable: Bool?
    let resolvedAt: Date?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id = "_id", sessionId, projectId, title, message, retryable, resolvedAt, createdAt
    }
}

/// Un error de la Mac (transcribir o subir una grabación) guardado en `Logs/errores.jsonl`.
struct LocalErrorEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    let date: Date
    let title: String
    let message: String
}

/// Una línea del registro que se muestra en la app: del servidor o de esta Mac.
struct LogLine: Identifiable, Hashable {
    enum Origin: String { case server = "Servidor", mac = "Mac" }
    let id: String
    let origin: Origin
    let date: Date
    let title: String
    let message: String
    let sessionId: String?
    let resolved: Bool

    init(_ entry: ErrorLogEntry) {
        id = "s-\(entry.id)"
        origin = .server
        date = entry.createdAt
        title = entry.title ?? "Sesión"
        message = entry.message
        sessionId = entry.sessionId
        resolved = entry.resolvedAt != nil
    }

    init(_ entry: LocalErrorEntry) {
        id = "m-\(entry.id)"
        origin = .mac
        date = entry.date
        title = entry.title
        message = entry.message
        sessionId = nil
        resolved = false
    }

    /// Texto plano para copiar o guardar en un .txt.
    static func plainText(_ lines: [LogLine]) -> String {
        let format = Date.ISO8601FormatStyle(timeZone: .current).year().month().day().time(includingFractionalSeconds: false)
        return lines.map { line in
            let state = line.resolved ? " (resuelto)" : ""
            return "[\(line.date.formatted(format))] [\(line.origin.rawValue)] «\(line.title)»\(state)\n\(line.message)"
        }.joined(separator: "\n\n") + "\n"
    }
}

/// Registro de errores de la Mac: un JSON por línea en Application Support.
/// Guarda como máximo `limit` entradas (las más recientes).
struct LocalErrorLog: Sendable {
    let url: URL
    var limit = 500

    static let shared = LocalErrorLog(
        url: URL.applicationSupportDirectory.appending(path: "AsistentIA/Logs/errores.jsonl")
    )

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func append(title: String, message: String, date: Date = .now) {
        let entry = LocalErrorEntry(date: date, title: title, message: message)
        var entries = read()
        entries.insert(entry, at: 0)
        write(Array(entries.prefix(limit)))
    }

    /// Del más reciente al más antiguo; ignora líneas que no se puedan leer.
    func read() -> [LocalErrorEntry] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? Self.decoder.decode(LocalErrorEntry.self, from: Data($0.utf8)) }
            .sorted { $0.date > $1.date }
    }

    func clear() {
        try? FileManager.default.removeItem(at: url)
    }

    private func write(_ entries: [LocalErrorEntry]) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lines = entries.compactMap { try? Self.encoder.encode($0) }.map { String(decoding: $0, as: UTF8.self) }
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
