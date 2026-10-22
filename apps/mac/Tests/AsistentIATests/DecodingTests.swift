import Foundation
import Testing
@testable import AsistentIA

// Respuesta real de GET /api/sessions/:id (forma que devuelve Mongoose + el
// análisis en snake_case de packages/schema).
private let sessionDetailJSON = """
{
  "session": {"_id": "6717a0c1f1a2b3c4d5e6f701", "projectId": "6717a0c1f1a2b3c4d5e6f700", "type": "teams_chat",
              "title": "Daily", "date": "2026-10-22T15:00:00.000Z", "participants": ["Ana López"],
              "status": "done", "createdAt": "2026-10-22T15:01:00.000Z", "__v": 0},
  "transcript": {"text": "Ana López: hola", "segments": [{"startSec": 1, "endSec": 2, "speaker": "Ana López", "text": "hola"}]},
  "analysis": {
    "result": {
      "summary": {"executive": "Todo bien.", "detailed": "Detalle"},
      "topics": [{"title": "Pagos", "key_points": ["Listo"], "timestamp": null}],
      "decisions": [{"decision": "Lanzar", "decided_by": null, "context": "QA ok"}],
      "action_items": [{"task": "Tests", "owner": "Carlos", "due_date": "2026-10-24", "priority": "high"}],
      "risks": [], "blockers": [{"description": "Sin acceso", "affected": "María", "severity": "high"}],
      "open_questions": ["¿Fecha final?"],
      "followups_from_previous": [{"action_item_id": "abc", "status": "done", "note": "Hecho"}],
      "team_signals": {"workload": null, "morale": "bueno", "dependencies": []}
    },
    "model": "claude-opus-5-5", "promptVersion": "analysis-v1", "createdAt": "2026-10-22T15:02:00.000Z"
  },
  "actionItems": [{"_id": "6717a0c1f1a2b3c4d5e6f702", "task": "Tests", "owner": "Carlos",
                   "dueDate": "2026-10-24T00:00:00.000Z", "priority": "high", "status": "open"}]
}
"""

@Test func decodesSessionDetail() throws {
    let detail = try APIClient.decoder.decode(SessionDetail.self, from: Data(sessionDetailJSON.utf8))
    #expect(detail.session.type == .teamsChat)
    #expect(detail.session.status == .done)
    #expect(detail.session.summary == nil)
    let result = try #require(detail.analysis?.result)
    #expect(result.topics.first?.keyPoints == ["Listo"])
    #expect(result.actionItems.first?.dueDate == "2026-10-24")
    #expect(result.followupsFromPrevious.first?.actionItemId == "abc")
    #expect(result.teamSignals.morale == "bueno")
    #expect(detail.actionItems.first?.dueDate != nil)
}

@Test func encodesCreateSessionRequest() throws {
    let req = CreateSessionRequest(
        projectId: "p1", type: .meeting, title: "Daily",
        date: Date(timeIntervalSince1970: 0),
        transcript: .init(format: .vtt, content: "WEBVTT")
    )
    let json = try #require(try JSONSerialization.jsonObject(with: APIClient.encoder.encode(req)) as? [String: Any])
    #expect(json["projectId"] as? String == "p1")
    #expect(json["type"] as? String == "meeting")
    #expect(json["date"] as? String == "1970-01-01T00:00:00Z")
    let transcript = try #require(json["transcript"] as? [String: Any])
    #expect(transcript["format"] as? String == "vtt")
}

@Test func decodesProjectSessionsList() throws {
    let json = """
    [{"_id": "s1", "projectId": "p1", "type": "pasted", "title": "Notas", "date": "2026-10-22T00:00:00Z",
      "status": "failed", "error": "Claude rechazó", "summary": null}]
    """
    let list = try APIClient.decoder.decode([Session].self, from: Data(json.utf8))
    #expect(list.first?.status == .failed)
    #expect(list.first?.error == "Claude rechazó")
}
