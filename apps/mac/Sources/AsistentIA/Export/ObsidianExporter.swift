import Foundation

/// Escribe sesiones, resúmenes y 1:1 como notas en una carpeta del vault:
///
///     <raíz>/<Proyecto>/<Proyecto>.md                 (se crea si falta)
///     <raíz>/<Proyecto>/Sesiones/2026-10-23 Daily.md
///     <raíz>/<Proyecto>/Resúmenes/Semana 2026-10-19.md
///     <raíz>/Personas/Octavio Ramírez.md              (se crea si falta, con sus alias)
///     <raíz>/Personas/Octavio Ramírez/1-1 2026-10-23.md
///
/// Lo generado va arriba de `marker`; lo que el usuario escriba debajo se
/// conserva al re-exportar. Una nota se reconoce por `asistente_id`, aunque se
/// haya renombrado.
struct ObsidianExporter {
    static let rootKey = "obsidianRoot"
    static let autoExportKey = "obsidianAutoExport"
    static let marker = "%% fin asistente: lo de abajo es tuyo y no se sobrescribe %%"

    let root: URL
    let people: [TeamMember]
    private let fm = FileManager.default

    init(root: URL, people: [TeamMember]) {
        self.root = root
        self.people = people
    }

    /// La carpeta configurada en Ajustes, o nil si aún no se eligió.
    static var configuredRoot: URL? {
        guard let path = UserDefaults.standard.string(forKey: rootKey), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    // MARK: Notas

    @discardableResult
    func exportSession(_ detail: SessionDetail, projectName: String) throws -> URL {
        let s = detail.session
        let doc = ShareDocument.session(detail, projectName: projectName, audience: .full)
        let participants = (s.participants ?? []).map { link($0) ?? $0 }
        let front = frontmatter([
            ("asistente_id", .text(s.id)),
            ("asistente_tipo", .text("sesion")),
            ("proyecto", .text("[[\(projectName)]]")),
            ("fecha", .raw(Self.day(s.date))),
            ("tipo", .text(s.type.label)),
            ("participantes", .list(participants)),
            ("nivel", detail.analysis?.depth.map { Value.text($0.label) }),
            ("modelo", detail.analysis.map { Value.text(ModelName.pretty($0.model)) }),
            ("costo_usd", detail.analysis?.usage?.costUsd.map { Value.raw(String(format: "%.4f", $0)) }),
            ("tags", .list(["asistente", Self.tag(projectName)])),
        ])
        try ensureProjectNote(projectName)
        try ensurePersonNotes(for: doc, extra: s.participants ?? [])
        return try write(id: s.id, folder: projectFolder(projectName).appending(path: "Sesiones"),
                         name: "\(Self.day(s.date)) \(s.title)", generated: front + body(doc))
    }

    @discardableResult
    func exportDigest(_ digest: WeeklyDigest, projectName: String) throws -> URL {
        let doc = ShareDocument.digest(digest, projectName: projectName)
        let front = frontmatter([
            ("asistente_id", .text(digest.id)),
            ("asistente_tipo", .text("resumen")),
            ("proyecto", .text("[[\(projectName)]]")),
            ("desde", .raw(Self.day(digest.periodStart))),
            ("hasta", .raw(Self.day(digest.periodEnd))),
            ("sesiones", .raw(String(digest.sessionCount))),
            ("tags", .list(["asistente", "resumen-semanal", Self.tag(projectName)])),
        ])
        try ensureProjectNote(projectName)
        try ensurePersonNotes(for: doc)
        return try write(id: digest.id, folder: projectFolder(projectName).appending(path: "Resúmenes"),
                         name: "Semana \(Self.day(digest.periodStart))", generated: front + body(doc))
    }

    @discardableResult
    func exportOneOnOne(_ prep: OneOnOnePrep, person: TeamMember) throws -> URL {
        let doc = ShareDocument.oneOnOne(prep, personName: person.name)
        let front = frontmatter([
            ("asistente_id", .text(prep.id)),
            ("asistente_tipo", .text("1-1")),
            ("persona", .text("[[\(person.name)]]")),
            ("fecha", .raw(Self.day(prep.createdAt))),
            ("tags", .list(["asistente", "1-1"])),
        ])
        try ensurePersonNote(person)
        let folder = root.appending(path: "Personas").appending(path: Self.fileName(person.name))
        return try write(id: prep.id, folder: folder, name: "1-1 \(Self.day(prep.createdAt))", generated: front + body(doc))
    }

    // MARK: Personas y proyectos

    /// Nota oficial de la persona si `name` es su nombre, primer nombre único o alias.
    func member(named name: String) -> TeamMember? {
        let key = Self.normalize(name)
        if let exact = people.first(where: { Self.normalize($0.name) == key || $0.aliases.contains { Self.normalize($0) == key } }) {
            return exact
        }
        let byFirst = people.filter { Self.normalize($0.name).split(separator: " ").first.map(String.init) == key }
        return byFirst.count == 1 ? byFirst[0] : nil
    }

    /// `[[Octavio Ramírez]]`, o `[[Octavio Ramírez|Tavo]]` si se le nombró por alias.
    func link(_ name: String) -> String? {
        guard let m = member(named: name) else { return nil }
        return m.name == name ? "[[\(m.name)]]" : "[[\(m.name)|\(name)]]"
    }

    private func ensurePersonNotes(for doc: ShareDocument, extra: [String] = []) throws {
        let names = doc.blocks.flatMap { block -> [String] in
            switch block {
            case let .bullets(e), let .tasks(e): e.compactMap(\.person)
            default: []
            }
        } + extra
        var seen = Set<String>()
        for m in names.compactMap(member(named:)) where seen.insert(m.id).inserted {
            try ensurePersonNote(m)
        }
    }

    /// Crea la ficha si falta. Una ficha existente nunca se modifica.
    private func ensurePersonNote(_ m: TeamMember) throws {
        let url = root.appending(path: "Personas").appending(path: "\(Self.fileName(m.name)).md")
        guard !fm.fileExists(atPath: url.path) else { return }
        let front = frontmatter([
            ("aliases", .list(m.aliases)),
            ("rol", m.role.flatMap { $0.isEmpty ? nil : Value.text($0) }),
            ("tags", .list(["asistente", "persona"])),
        ])
        try createFile(url, front + "# \(m.name)\n")
    }

    private func ensureProjectNote(_ name: String) throws {
        let url = projectFolder(name).appending(path: "\(Self.fileName(name)).md")
        guard !fm.fileExists(atPath: url.path) else { return }
        try createFile(url, frontmatter([("tags", .list(["asistente", "proyecto"]))]) + "# \(name)\n")
    }

    private func projectFolder(_ name: String) -> URL { root.appending(path: Self.fileName(name)) }

    // MARK: Escritura

    /// Escribe la nota conservando lo que haya bajo el marcador.
    func write(id: String, folder: URL, name: String, generated: String) throws -> URL {
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let existing = try findNote(id: id, in: folder)
        var tail = "\n"
        if let existing, let text = try? String(contentsOf: existing, encoding: .utf8),
           let range = text.range(of: Self.marker) {
            tail = String(text[range.upperBound...])
        }
        let url = existing ?? freeURL(in: folder, base: Self.fileName(name))
        try (generated + "\n" + Self.marker + tail).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func findNote(id: String, in folder: URL) throws -> URL? {
        let needle = "asistente_id: \"\(id)\""
        let files = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "md" }
        return files.first { url in
            guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
            defer { try? handle.close() }
            let head = (try? handle.read(upToCount: 600)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            return head.contains(needle)
        }
    }

    private func freeURL(in folder: URL, base: String) -> URL {
        var url = folder.appending(path: "\(base).md")
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = folder.appending(path: "\(base) (\(n)).md")
            n += 1
        }
        return url
    }

    private func createFile(_ url: URL, _ text: String) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Formato

    enum Value { case text(String), raw(String), list([String]) }

    private func frontmatter(_ fields: [(String, Value?)]) -> String {
        var out = ["---"]
        for (key, value) in fields {
            switch value {
            case let .text(s): out.append("\(key): \(Self.quote(s))")
            case let .raw(s): out.append("\(key): \(s)")
            case let .list(items) where items.isEmpty: out.append("\(key): []")
            case let .list(items): out.append("\(key):"); out += items.map { "  - \(Self.quote($0))" }
            case nil: continue
            }
        }
        return (out + ["---", ""]).joined(separator: "\n")
    }

    private func body(_ doc: ShareDocument) -> String {
        ShareRenderer.markdown(doc, link: link)
    }

    static func quote(_ s: String) -> String {
        "\"\(s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    /// Nombre de archivo válido en macOS y como enlace de Obsidian.
    static func fileName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|#^[]").union(.newlines).union(.controlCharacters)
        let cleaned = s.unicodeScalars.map { bad.contains($0) ? "-" : String($0) }.joined()
            .trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ".")))
        return cleaned.isEmpty ? "Sin título" : String(cleaned.prefix(120))
    }

    static func tag(_ s: String) -> String {
        let folded = normalize(s).map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(folded).split(separator: "-").joined(separator: "-")
    }

    static func normalize(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespaces)
    }

    static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}

enum ObsidianLink {
    /// `obsidian://open?path=…`: abre la nota si está dentro de un vault de Obsidian.
    static func url(for file: URL) -> URL {
        var c = URLComponents()
        c.scheme = "obsidian"
        c.host = "open"
        c.queryItems = [URLQueryItem(name: "path", value: file.path)]
        return c.url ?? file
    }
}
