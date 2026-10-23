import Foundation
import Testing
@testable import AsistentIA

// Sesión analizada con un pendiente hecho, uno abierto y señales del equipo
// (que nunca deben salir en lo que se comparte con el equipo).
private let detailJSON = """
{
  "session": {"_id": "s1", "projectId": "p1", "type": "meeting", "title": "Daily: equipo",
              "date": "2026-10-23T15:00:00.000Z", "participants": ["Octavio Ramírez", "Ana"], "status": "done", "depth": "quick"},
  "analysis": {
    "result": {
      "summary": {"executive": "Se cerró el login y quedó bloqueado el despliegue."},
      "topics": [{"title": "Login", "key_points": ["Listo en QA"], "timestamp": null}],
      "decisions": [{"decision": "Lanzar el viernes", "decided_by": "Tavo", "context": "QA ok"}],
      "action_items": [],
      "risks": [{"description": "Poca cobertura", "severity": "medium", "mitigation": null}],
      "blockers": [{"description": "Sin acceso a prod", "affected": "Ana", "severity": "high"}],
      "open_questions": ["¿Quién revisa?"],
      "followups_from_previous": [],
      "team_signals": {"workload": "Ana saturada", "morale": null, "dependencies": []}
    },
    "depth": "quick", "model": "claude-sonnet-5-5", "effort": "medium", "promptVersion": "analysis-v5",
    "usage": {"costUsd": 0.0123}, "createdAt": "2026-10-23T15:02:00.000Z"
  },
  "actionItems": [
    {"_id": "a1", "task": "Arreglar crash", "owner": "Octavio Ramírez", "priority": "high", "status": "done"},
    {"_id": "a2", "task": "Pedir acceso", "owner": null, "priority": "medium", "status": "blocked"}
  ]
}
"""

private let peopleJSON = """
[{"_id": "u1", "name": "Octavio Ramírez", "role": "Backend", "aliases": ["Tavo"]},
 {"_id": "u2", "name": "Ana López", "aliases": []}]
"""

private func fixtures() throws -> (SessionDetail, [TeamMember]) {
    (try APIClient.decoder.decode(SessionDetail.self, from: Data(detailJSON.utf8)),
     try APIClient.decoder.decode([TeamMember].self, from: Data(peopleJSON.utf8)))
}

private func tempRoot() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "export-\(UUID().uuidString)")
}

@Test func chatTextHasCurrentItemsAndNoTeamSignals() throws {
    let (detail, _) = try fixtures()
    let doc = ShareDocument.session(detail, projectName: "Panda", audience: .team)
    let text = ShareRenderer.chatText(doc)
    #expect(text.hasPrefix("*Daily: equipo*"))
    #expect(text.contains("Se cerró el login"))
    #expect(text.contains("• Lanzar el viernes — Tavo"))
    #expect(text.contains("☑ Arreglar crash — Octavio Ramírez"))
    #expect(text.contains("☐ Pedir acceso — sin responsable (bloqueado)"))
    #expect(text.contains("Sin acceso a prod — Ana (alto)"))
    #expect(!text.contains("saturada"))
    #expect(!text.contains("Temas"))

    let html = ShareRenderer.html(doc)
    #expect(html.contains("<h3>Pendientes</h3>"))
    #expect(html.contains("<b>Octavio Ramírez</b>"))
    #expect(!html.contains("saturada"))
}

@Test func exportsSessionWithLinksAndPersonNotes() throws {
    let (detail, people) = try fixtures()
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let exporter = ObsidianExporter(root: root, people: people)
    let url = try exporter.exportSession(detail, projectName: "Panda")

    #expect(url.path.hasSuffix("Panda/Sesiones/2026-10-23 Daily- equipo.md"))
    let md = try String(contentsOf: url, encoding: .utf8)
    #expect(md.contains("asistente_id: \"s1\""))
    #expect(md.contains("proyecto: \"[[Panda]]\""))
    #expect(md.contains("  - \"[[Octavio Ramírez]]\""))
    #expect(md.contains("  - \"[[Ana López|Ana]]\"")) // primer nombre único
    #expect(md.contains("- [x] Arreglar crash — [[Octavio Ramírez]]"))
    #expect(md.contains("- Lanzar el viernes — [[Octavio Ramírez|Tavo]]")) // alias
    #expect(md.contains("Carga: Ana saturada")) // Obsidian lleva la copia completa
    #expect(md.contains(ObsidianExporter.marker))

    let person = root.appending(path: "Personas/Octavio Ramírez.md")
    let note = try String(contentsOf: person, encoding: .utf8)
    #expect(note.contains("aliases:\n  - \"Tavo\""))
    #expect(note.contains("rol: \"Backend\""))
    #expect(FileManager.default.fileExists(atPath: root.appending(path: "Panda/Panda.md").path))
}

@Test func reexportKeepsUserNotesAndExistingPersonNotes() throws {
    let (detail, people) = try fixtures()
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let exporter = ObsidianExporter(root: root, people: people)
    let first = try exporter.exportSession(detail, projectName: "Panda")

    // El usuario renombra la nota, escribe bajo el marcador y edita la ficha.
    let renamed = first.deletingLastPathComponent().appending(path: "Mi daily.md")
    try FileManager.default.moveItem(at: first, to: renamed)
    try (try String(contentsOf: renamed, encoding: .utf8) + "\nMis notas: hablar con Ana.\n")
        .write(to: renamed, atomically: true, encoding: .utf8)
    let person = root.appending(path: "Personas/Octavio Ramírez.md")
    try "Ficha editada a mano".write(to: person, atomically: true, encoding: .utf8)

    let second = try exporter.exportSession(detail, projectName: "Panda")
    #expect(second.lastPathComponent == "Mi daily.md")
    let md = try String(contentsOf: second, encoding: .utf8)
    #expect(md.contains("Mis notas: hablar con Ana."))
    #expect(md.components(separatedBy: ObsidianExporter.marker).count == 2)
    #expect(md.components(separatedBy: "# Daily: equipo").count == 2)
    #expect(try String(contentsOf: person, encoding: .utf8) == "Ficha editada a mano")
    let files = try FileManager.default.contentsOfDirectory(atPath: second.deletingLastPathComponent().path)
    #expect(files == ["Mi daily.md"])
}

@Test func sanitizesFileNamesAndTags() {
    #expect(ObsidianExporter.fileName("Daily: 23/10 [#1]") == "Daily- 23-10 --1-")
    #expect(ObsidianExporter.fileName("  ...  ") == "Sin título")
    #expect(ObsidianExporter.tag("Equipo de Desarrollo Ñandú") == "equipo-de-desarrollo-nandu")
    #expect(ObsidianExporter.quote("dijo \"sí\"") == "\"dijo \\\"sí\\\"\"")
}
