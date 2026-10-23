import Foundation

/// Un fragmento transcrito de una de las dos pistas.
struct TimedText: Equatable, Sendable {
    var start: Double
    var end: Double
    var text: String
    /// Etiqueta de la voz si se separó la llamada ("Octavio Ramírez", "Voz 2").
    var speaker: String? = nil
}

/// Une las pistas "me" (micrófono) y "others" (audio del sistema) en una sola
/// transcripción ordenada, limpiando lo que Whisper suele inventar.
enum TranscriptMerger {
    /// Frases que Whisper genera sobre silencio o música (entrenado con subtítulos).
    static let hallucinations: [String] = [
        "gracias por ver",
        "gracias por ver el video",
        "suscríbete",
        "subtítulos realizados por la comunidad de amara.org",
        "subtítulos por la comunidad de amara.org",
        "amara.org",
        "¡gracias!",
        "gracias.",
        "música",
        "[música]",
        "(música)",
        "[aplausos]",
        "[risas]",
        "...",
    ]

    static func merge(me: [TimedText], others: [TimedText], vocabulary: [String] = []) -> [Segment] {
        let mine = clean(me, vocabulary: vocabulary)
        let theirs = clean(others, vocabulary: vocabulary)
        // Si el micrófono capta lo que suena en las bocinas, el mismo texto
        // aparece en ambas pistas: se conserva solo el del sistema.
        let mineWithoutEcho = mine.filter { m in
            !theirs.contains { o in overlaps(m, o) && similarity(m.text, o.text) >= 0.6 }
        }
        let tagged = mineWithoutEcho.map { ($0, "me") } + theirs.map { ($0, $0.speaker ?? "others") }
        return tagged
            .sorted { $0.0.start < $1.0.start }
            .map { Segment(startSec: $0.0.start, endSec: $0.0.end, speaker: $0.1, text: $0.0.text) }
    }

    static func clean(_ items: [TimedText], vocabulary: [String] = []) -> [TimedText] {
        var result: [TimedText] = []
        for item in items {
            let text = item.text
                .replacingOccurrences(of: #"<\|[^|]*\|>"#, with: "", options: .regularExpression) // tokens especiales
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !isHallucination(text), !echoesVocabulary(text, vocabulary) else { continue }
            // Whisper a veces repite la misma frase en ventanas seguidas.
            if let last = result.last, normalized(last.text) == normalized(text) { continue }
            result.append(TimedText(start: item.start, end: item.end, text: text, speaker: item.speaker))
        }
        return result
    }

    /// Con la pista de vocabulario, Whisper a veces la "dice" sobre un silencio:
    /// el fragmento es "Glosario: …" o solo términos del vocabulario.
    static func echoesVocabulary(_ text: String, _ vocabulary: [String]) -> Bool {
        guard !vocabulary.isEmpty else { return false }
        let n = normalized(text)
        if n.hasPrefix("glosario") { return true }
        let terms = Set(vocabulary.map(normalized))
        let parts = text.split(whereSeparator: { ",.;".contains($0) }).map { normalized(String($0)) }.filter { !$0.isEmpty }
        return parts.count >= 2 && parts.allSatisfy(terms.contains)
    }

    static func isHallucination(_ text: String) -> Bool {
        let n = normalized(text)
        return n.isEmpty || hallucinations.contains { normalized($0) == n }
    }

    static func overlaps(_ a: TimedText, _ b: TimedText, tolerance: Double = 1.5) -> Bool {
        a.start <= b.end + tolerance && b.start <= a.end + tolerance
    }

    /// Similitud de Jaccard entre las palabras de dos textos (0…1).
    static func similarity(_ a: String, _ b: String) -> Double {
        let wa = Set(words(a)), wb = Set(words(b))
        guard !wa.isEmpty, !wb.isEmpty else { return 0 }
        return Double(wa.intersection(wb).count) / Double(wa.union(wb).count)
    }

    static func normalized(_ s: String) -> String {
        words(s).joined(separator: " ")
    }

    private static func words(_ s: String) -> [String] {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
