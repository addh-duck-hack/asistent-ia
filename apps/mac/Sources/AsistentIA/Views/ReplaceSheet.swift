import SwiftUI

/// Misma regla que el backend (POST /api/sessions/:id/transcript/replace):
/// palabra o frase completa, sin distinguir mayúsculas. "Tox" no toca "tóxico".
enum TranscriptReplace {
    static func regex(_ find: String) -> NSRegularExpression? {
        let term = find.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return nil }
        let pattern = #"(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: term) + #"(?![\p{L}\p{N}])"#
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    static func count(_ find: String, in text: String) -> Int {
        regex(find)?.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) ?? 0
    }

    static func apply(_ find: String, _ replace: String, to text: String) -> String {
        guard let regex = regex(find) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                              withTemplate: NSRegularExpression.escapedTemplate(for: replace))
    }
}

struct ReplaceSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let detail: SessionDetail

    @State private var find = ""
    @State private var replace = ""
    @State private var addToVocabulary = true
    @State private var working = false
    @State private var applied = 0
    private var player: ClipPlayer { ClipPlayer.shared }

    /// Líneas de la transcripción actual (la del store, que se refresca tras cada reemplazo).
    private var current: SessionDetail { store.detail?.session.id == detail.session.id ? store.detail! : detail }
    private var lines: [Segment] {
        let segments = current.transcript?.segments ?? []
        if !segments.isEmpty { return segments }
        return (current.transcript?.text ?? "").split(separator: "\n").map { Segment(text: String($0)) }
    }
    private var matches: [Segment] { lines.filter { TranscriptReplace.count(find, in: $0.text) > 0 } }
    private var total: Int { lines.reduce(0) { $0 + TranscriptReplace.count(find, in: $1.text) } }

    private var project: Project? { store.projects.first { $0.id == detail.session.projectId } }
    private var term: String { replace.trimmingCharacters(in: .whitespaces) }
    /// Solo términos cortos tienen sentido como vocabulario (no frases completas).
    private var canAddToVocabulary: Bool {
        let words = term.split(separator: " ").count
        return project != nil && (1...3).contains(words)
            && !(project?.vocabulary ?? []).contains { $0.caseInsensitiveCompare(term) == .orderedSame }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Buscar y reemplazar").font(.title2.bold())
            Form {
                TextField("Buscar", text: $find, prompt: Text("Tox"))
                TextField("Reemplazar por", text: $replace, prompt: Text("Toks"))
                if canAddToVocabulary, let project {
                    Toggle("Agregar «\(term)» al vocabulario de \(project.name)", isOn: $addToVocabulary)
                }
            }
            .formStyle(.grouped)

            if !find.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(total == 0 ? "Sin coincidencias (palabra o frase completa, sin importar mayúsculas)."
                     : "\(total) \(total == 1 ? "coincidencia" : "coincidencias") en \(matches.count) \(matches.count == 1 ? "línea" : "líneas")")
                    .font(.callout).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(matches.prefix(10).enumerated()), id: \.offset) { i, line in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                playButton(line, index: i)
                                Text(preview(line.text)).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                .frame(maxHeight: 220)
            }

            if applied > 0 {
                Label("\(applied) \(applied == 1 ? "cambio aplicado" : "cambios aplicados"). Re-analiza para que el resumen y los pendientes usen el texto corregido.",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.callout)
            }

            HStack {
                Button("Cerrar") { player.stop(); dismiss() }
                Spacer()
                if applied > 0 {
                    Button("Re-analizar y cerrar") {
                        player.stop()
                        Task { await store.reanalyze(); dismiss() }
                    }
                }
                Button(working ? "Reemplazando…" : "Reemplazar") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || total == 0)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onDisappear { player.stop() }
    }

    private func apply() {
        working = true
        let (f, r, add) = (find, replace, addToVocabulary && canAddToVocabulary)
        Task {
            if let n = await store.replaceInTranscript(find: f, replace: r, addToVocabulary: add) {
                applied += n
                find = ""
                replace = ""
            }
            working = false
        }
    }

    /// La línea ya corregida, con el reemplazo en negritas.
    private func preview(_ text: String) -> AttributedString {
        guard let regex = TranscriptReplace.regex(find) else { return AttributedString(text) }
        var out = AttributedString()
        var last = text.startIndex
        for m in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(m.range, in: text) else { continue }
            out += AttributedString(String(text[last..<range.lowerBound]))
            var replaced = AttributedString(replace.isEmpty ? "∅" : replace)
            replaced.inlinePresentationIntent = .stronglyEmphasized
            replaced.foregroundColor = .accentColor
            out += replaced
            last = range.upperBound
        }
        out += AttributedString(String(text[last...]))
        return out
    }

    @ViewBuilder
    private func playButton(_ line: Segment, index: Int) -> some View {
        let track: SessionAudio.Track = line.speaker == "me" ? .mic : .system
        if let start = line.startSec, let url = SessionAudio.shared.url(sessionId: detail.session.id, track: track) {
            let id = "replace|\(index)|\(start)"
            Button {
                player.toggle(url, from: max(0, start - 0.3), to: (line.endSec ?? start + 6) + 0.3, id: id)
            } label: {
                Image(systemName: player.playingId == id ? "stop.circle.fill" : "play.circle")
            }
            .buttonStyle(.plain)
            .help("Escuchar esta línea")
        } else {
            Image(systemName: "text.quote").foregroundStyle(.tertiary)
        }
    }
}
