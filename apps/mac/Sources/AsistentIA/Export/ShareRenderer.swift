import AppKit

enum ShareRenderer {
    /// Texto plano con el formato de WhatsApp (*negritas*, _cursivas_); también
    /// se lee bien en cualquier campo de texto.
    static func chatText(_ doc: ShareDocument) -> String {
        var out = ["*\(doc.title)*", "_\(doc.meta)_"]
        for block in doc.blocks {
            switch block {
            case let .heading(text): out += ["", "*\(text)*"]
            case let .paragraph(text): out += ["", text]
            case let .bullets(entries): out += entries.map { "• \(line($0, person: { $0 }))" }
            case let .tasks(entries): out += entries.map { "\($0.done ? "☑" : "☐") \(line($0, person: { $0 }))" }
            }
        }
        return out.joined(separator: "\n")
    }

    /// HTML sencillo: Teams, Notion y el correo lo pegan con formato.
    static func html(_ doc: ShareDocument) -> String {
        var out = ["<h2>\(esc(doc.title))</h2>", "<p><i>\(esc(doc.meta))</i></p>"]
        for block in doc.blocks {
            switch block {
            case let .heading(text): out.append("<h3>\(esc(text))</h3>")
            case let .paragraph(text): out.append("<p>\(esc(text))</p>")
            case let .bullets(entries):
                out.append("<ul>" + entries.map { "<li>\(htmlLine($0))</li>" }.joined() + "</ul>")
            case let .tasks(entries):
                out.append("<ul>" + entries.map { "<li>\($0.done ? "☑" : "☐") \(htmlLine($0))</li>" }.joined() + "</ul>")
            }
        }
        return out.joined(separator: "\n")
    }

    /// Markdown para Obsidian. `link` convierte un nombre en `[[Nota]]` cuando
    /// es alguien del equipo; si devuelve nil queda como texto.
    static func markdown(_ doc: ShareDocument, link: (String) -> String? = { _ in nil }) -> String {
        var out = ["# \(doc.title)", "", doc.meta]
        for block in doc.blocks {
            switch block {
            case let .heading(text): out += ["", "## \(text)"]
            case let .paragraph(text): out += ["", text]
            case let .bullets(entries): out += entries.map { "- \(line($0) { link($0) ?? $0 })" }
            case let .tasks(entries): out += entries.map { "- [\($0.done ? "x" : " ")] \(line($0) { link($0) ?? $0 })" }
            }
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// Copia al portapapeles en HTML y en texto: cada app toma el que entiende.
    @MainActor
    static func copy(_ doc: ShareDocument) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(html(doc), forType: .html)
        pb.setString(chatText(doc), forType: .string)
    }

    private static func line(_ e: ShareDocument.Entry, person: (String) -> String) -> String {
        [e.text, e.person.map { "— \(person($0))" }, e.detail.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
    }

    private static func htmlLine(_ e: ShareDocument.Entry) -> String {
        [esc(e.text), e.person.map { "— <b>\(esc($0))</b>" }, e.detail.map { "<i>(\(esc($0)))</i>" }]
            .compactMap { $0 }.joined(separator: " ")
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
