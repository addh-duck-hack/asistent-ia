import Foundation
import Testing
@testable import AsistentIA

struct ErrorLogTests {
    private func tempLog(limit: Int = 500) -> LocalErrorLog {
        LocalErrorLog(url: FileManager.default.temporaryDirectory
            .appending(path: "errores-\(UUID().uuidString)/errores.jsonl"), limit: limit)
    }

    @Test func localLogKeepsNewestFirstAndRespectsTheLimit() {
        let log = tempLog(limit: 2)
        defer { log.clear() }
        log.append(title: "A", message: "uno", date: Date(timeIntervalSince1970: 1))
        log.append(title: "B", message: "dos", date: Date(timeIntervalSince1970: 2))
        log.append(title: "C", message: "tres", date: Date(timeIntervalSince1970: 3))
        #expect(log.read().map(\.title) == ["C", "B"])
        log.clear()
        #expect(log.read().isEmpty)
    }

    @Test func decodesServerLogsAndMergesThemAsText() throws {
        let json = #"[{"_id":"l1","sessionId":"s1","projectId":"p1","title":"Reunión 24 Nov","message":"Claude 401: invalid x-api-key","retryable":false,"createdAt":"2026-11-24T18:05:00.000Z"},{"_id":"l2","sessionId":"s1","message":"Claude 529","resolvedAt":"2026-11-24T19:00:00.000Z","createdAt":"2026-11-24T17:00:00.000Z"}]"#
        let entries = try APIClient.decoder.decode([ErrorLogEntry].self, from: Data(json.utf8))
        let lines = entries.map(LogLine.init)
        #expect(lines[0].title == "Reunión 24 Nov" && !lines[0].resolved)
        #expect(lines[1].title == "Sesión" && lines[1].resolved)
        let text = LogLine.plainText(lines)
        #expect(text.contains("[Servidor] «Reunión 24 Nov»\nClaude 401: invalid x-api-key"))
        #expect(text.contains("«Sesión» (resuelto)"))
    }
}
