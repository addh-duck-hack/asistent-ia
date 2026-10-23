import Foundation

/// Contenido neutral de una sesión, resumen o 1:1, listo para mostrarse como
/// HTML (portapapeles), texto de chat (WhatsApp) o Markdown (Obsidian).
/// No llama a Claude: reutiliza el análisis ya guardado.
struct ShareDocument {
    struct Entry: Hashable {
        var text: String
        /// Persona relacionada (responsable, quien decidió, afectado); Obsidian la enlaza.
        var person: String?
        /// Dato secundario: estado, fecha, severidad, sesión de origen…
        var detail: String?
        var done = false
    }

    enum Block {
        case heading(String)
        case paragraph(String)
        case bullets([Entry])
        case tasks([Entry])
    }

    /// Para quién es: `.team` se pega en chats del equipo y nunca lleva las
    /// señales de carga y ánimo; `.full` es la copia completa de Obsidian.
    enum Audience { case team, full }

    var title: String
    var meta: String
    var blocks: [Block] = []

    mutating func section(_ title: String, bullets entries: [Entry]) {
        guard !entries.isEmpty else { return }
        blocks += [.heading(title), .bullets(entries)]
    }

    mutating func section(_ title: String, _ lines: [String]) {
        section(title, bullets: lines.map { Entry(text: $0) })
    }
}

enum Severity {
    static func label(_ value: String) -> String {
        switch value {
        case "high": "alto"
        case "medium": "medio"
        default: "bajo"
        }
    }
}

extension ShareDocument {
    static func session(_ detail: SessionDetail, projectName: String?, audience: Audience) -> ShareDocument {
        let s = detail.session
        var doc = ShareDocument(
            title: s.title,
            meta: [projectName, s.date.formatted(date: .long, time: .omitted), s.type.label].compactMap { $0 }.joined(separator: " · ")
        )
        guard let r = detail.analysis?.result else {
            doc.blocks = [.paragraph("Esta sesión todavía no tiene análisis.")]
            return doc
        }
        doc.blocks.append(.paragraph(r.summary.executive))
        doc.section("Decisiones", bullets: r.decisions.map { Entry(text: $0.decision, person: $0.decidedBy) })

        // Los pendientes con su estado de hoy (no el borrador del análisis), para
        // que lo compartido diga quién lo tiene y si ya se cerró.
        let tasks: [Entry] = detail.actionItems.isEmpty
            ? r.actionItems.map { Entry(text: $0.task, person: $0.owner, detail: $0.dueDate.map { "vence \($0)" }) }
            : detail.actionItems.map { item in
                let status = ItemStatus(rawValue: item.status)
                let parts = [
                    status.flatMap { $0 == .open || $0 == .done ? nil : $0.label.lowercased() },
                    item.dueDate.map { "vence \($0.formatted(.dateTime.day().month(.abbreviated)))" },
                ].compactMap { $0 }
                return Entry(text: item.task, person: item.owner ?? "sin responsable",
                             detail: parts.isEmpty ? nil : parts.joined(separator: ", "), done: status == .done)
            }
        if !tasks.isEmpty { doc.blocks += [.heading("Pendientes"), .tasks(tasks)] }

        doc.section("Bloqueos", bullets: r.blockers.map {
            Entry(text: $0.description, person: $0.affected, detail: Severity.label($0.severity))
        })
        doc.section("Riesgos", bullets: r.risks.map {
            Entry(text: $0.description, detail: [Severity.label($0.severity), $0.mitigation.map { "mitigación: \($0)" }]
                .compactMap { $0 }.joined(separator: "; "))
        })
        doc.section("Preguntas abiertas", r.openQuestions)

        if audience == .full {
            doc.section("Temas", bullets: r.topics.map {
                Entry(text: $0.title, detail: $0.keyPoints.isEmpty ? nil : $0.keyPoints.joined(separator: "; "))
            })
            let signals = r.teamSignals
            let lines = [
                signals.workload.map { "Carga: \($0)" },
                signals.morale.map { "Ánimo: \($0)" },
            ].compactMap { $0 } + signals.dependencies.map { "Dependencia: \($0)" }
            doc.section("Señales del equipo", lines)
        }
        return doc
    }

    static func digest(_ digest: WeeklyDigest, projectName: String?) -> ShareDocument {
        let r = digest.result
        var doc = ShareDocument(
            title: "Resumen semanal\(projectName.map { " · \($0)" } ?? "")",
            meta: "\(digest.periodLabel) · \(digest.sessionCount) \(digest.sessionCount == 1 ? "sesión" : "sesiones")",
            blocks: [.paragraph(r.summary)]
        )
        doc.section("Requieren atención", bullets: r.attention.map {
            Entry(text: $0.task, person: $0.owner ?? "sin responsable", detail: $0.reason)
        })
        doc.section("Foco para la siguiente semana", r.nextWeekFocus)
        doc.section("Avances", r.highlights)
        doc.section("Decisiones", bullets: r.decisions.map { Entry(text: $0.decision, detail: $0.session) })
        doc.section("Pendientes cerrados", r.completed)
        doc.section("Riesgos", bullets: r.risks.map { Entry(text: $0.description, detail: Severity.label($0.severity)) })
        return doc
    }

    /// Preparación privada del 1:1 (para las notas del líder, no para el equipo).
    static func oneOnOne(_ prep: OneOnOnePrep, personName: String?) -> ShareDocument {
        let r = prep.result
        var doc = ShareDocument(
            title: "1:1 con \(personName ?? "")",
            meta: "\(prep.periodStart.formatted(date: .abbreviated, time: .omitted)) – \(prep.periodEnd.formatted(date: .abbreviated, time: .omitted))",
            blocks: [.paragraph(r.summary)]
        )
        doc.section("Temas para el 1:1", r.topics)
        doc.section("Preguntas sugeridas", r.questions)
        doc.section("Logros para reconocer", r.wins)
        doc.section("Bloqueos", r.blockers)
        if let w = r.workloadSignals { doc.blocks += [.heading("Carga y ánimo"), .paragraph(w)] }
        return doc
    }
}
