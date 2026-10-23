import Foundation
import Testing
@testable import AsistentIA

private let conversationJSON = """
{"_id": "c1", "title": "¿Cuándo salen los pagos?", "projectId": null, "costUsd": 0.012,
 "messages": [
   {"_id": "m1", "role": "user", "content": "¿Cuándo salen los pagos?", "citations": [], "createdAt": "2026-10-23T18:00:00.000Z"},
   {"_id": "m2", "role": "assistant", "content": "El viernes [[sesion:6717a0c1f1a2b3c4d5e6f701]] y no [[sesion:ffffffffffffffffffffffff]].",
    "citations": ["6717a0c1f1a2b3c4d5e6f701"], "model": "claude-sonnet-5-5", "toolCalls": 3,
    "usage": {"inputTokens": 9000, "outputTokens": 400, "costUsd": 0.012}, "createdAt": "2026-10-23T18:00:09.000Z"}
 ],
 "sessions": [{"_id": "6717a0c1f1a2b3c4d5e6f701", "title": "Planning [pagos]", "date": "2026-10-05T15:00:00.000Z", "projectId": "p1"}]}
"""

@Test func decodesConversationAndLinksCitations() throws {
    let c = try APIClient.decoder.decode(Conversation.self, from: Data(conversationJSON.utf8))
    #expect(c.messages.count == 2)
    #expect(c.messages[0].isUser)
    #expect(c.messages[1].toolCalls == 3)
    #expect(c.messages[1].usage?.costUsd == 0.012)

    let md = Citations.markdown(c.messages[1].content, sessions: c.sessions)
    #expect(md.contains("[↗ Planning [pagos), 5 oct](asistente://sesion/6717a0c1f1a2b3c4d5e6f701)") || md.contains("(asistente://sesion/6717a0c1f1a2b3c4d5e6f701)"))
    #expect(!md.contains("ffffffff")) // la cita a una sesión que no existe se quita
    let url = try #require(URL(string: "asistente://sesion/6717a0c1f1a2b3c4d5e6f701"))
    #expect(Citations.sessionId(from: url) == "6717a0c1f1a2b3c4d5e6f701")
    #expect(Citations.sessionId(from: URL(string: "https://example.com/x")!) == nil)
}
