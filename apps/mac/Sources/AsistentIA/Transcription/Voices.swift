import Accelerate
import Foundation

// Separación de voces del audio de la llamada y reconocimiento de personas por
// su huella de voz. Todo ocurre y se guarda en esta Mac: las huellas nunca se
// suben al backend; solo viajan los nombres ya resueltos o "Voz N".

/// Un tramo en que habla una voz (resultado de la diarización).
struct DiarizedTurn: Equatable, Sendable {
    var start: Double
    var end: Double
    var speaker: Int
}

struct Diarization: Sendable {
    var turns: [DiarizedTurn]
    /// Huella (centroide del embedding) de cada voz detectada.
    var centroids: [Int: [Float]]
}

/// Huellas de voz de una persona del equipo (varias, de distintas reuniones).
struct VoiceProfile: Codable, Equatable {
    var personId: String
    var name: String
    var embeddings: [[Float]]
}

enum VoiceMath {
    static func cosineDistance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        vDSP_svesq(a, 1, &na, vDSP_Length(a.count))
        vDSP_svesq(b, 1, &nb, vDSP_Length(b.count))
        guard na > 0, nb > 0 else { return 1 }
        return 1 - dot / (na.squareRoot() * nb.squareRoot())
    }
}

enum SpeakerLabeler {
    /// Distancia coseno máxima para decir "es la misma persona" entre reuniones.
    /// Medido con voces reales (DiarizationIntegrationTests): la misma persona
    /// partida en dos grupos quedó a 0.61 y dos personas distintas a 0.91–0.93.
    /// 0.7 deja margen a ambos lados; las correcciones del líder ajustan las huellas.
    static let matchThreshold: Float = 0.7

    /// Voz de cada fragmento: la que más se solapa con él; si ninguna, la anterior.
    static func assign(_ texts: [TimedText], turns: [DiarizedTurn]) -> [Int?] {
        var previous: Int?
        return texts.map { t in
            var best: (speaker: Int, overlap: Double)?
            for turn in turns {
                let overlap = min(t.end, turn.end) - max(t.start, turn.start)
                if overlap > 0, overlap > (best?.overlap ?? 0) { best = (turn.speaker, overlap) }
            }
            if let best { previous = best.speaker }
            return best?.speaker ?? previous
        }
    }

    /// Persona de huella más parecida para cada voz, si está por debajo del umbral.
    /// Varias voces pueden quedar con la misma persona: SpeakerKit a veces parte
    /// a alguien en dos grupos dentro de una misma llamada (visto con audio real).
    static func match(_ centroids: [Int: [Float]], profiles: [VoiceProfile]) -> [Int: VoiceProfile] {
        var result: [Int: VoiceProfile] = [:]
        for (speaker, centroid) in centroids {
            let best = profiles
                .compactMap { p in p.embeddings.map { VoiceMath.cosineDistance(centroid, $0) }.min().map { (p, $0) } }
                .min { $0.1 < $1.1 }
            if let (profile, distance) = best, distance < matchThreshold { result[speaker] = profile }
        }
        return result
    }

    /// Pone etiqueta a cada fragmento: el nombre de la persona reconocida o
    /// "Voz N" (numeradas por orden de aparición). Devuelve también la huella de
    /// cada etiqueta, para guardarla junto a la sesión.
    static func label(_ texts: [TimedText], diarization: Diarization, profiles: [VoiceProfile]) -> (texts: [TimedText], voices: [String: [Float]]) {
        let speakers = assign(texts, turns: diarization.turns)
        let matched = match(diarization.centroids, profiles: profiles)
        var labels: [Int: String] = [:]
        var unknown = 0
        for case let s? in speakers where labels[s] == nil {
            if let p = matched[s] {
                labels[s] = p.name
            } else {
                unknown += 1
                labels[s] = "Voz \(unknown)"
            }
        }
        let labeled = zip(texts, speakers).map { t, s in
            var t = t
            t.speaker = s.flatMap { labels[$0] } ?? "others"
            return t
        }
        var voices: [String: [Float]] = [:]
        for (s, label) in labels { voices[label] = diarization.centroids[s] }
        return (labeled, voices)
    }
}

/// Huellas de voz guardadas en ~/Library/Application Support/AsistentIA/Voices.
struct VoiceStore {
    static let enabledKey = "diarizeCalls"
    static let maxEmbeddingsPerPerson = 10
    static let shared = VoiceStore(root: URL.applicationSupportDirectory.appending(path: "AsistentIA/Voices", directoryHint: .isDirectory))

    let root: URL
    private var profilesURL: URL { root.appending(path: "profiles.json") }
    private func sessionURL(_ id: String) -> URL { root.appending(path: "sessions/\(id).json") }

    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    func profiles() -> [VoiceProfile] {
        (try? Data(contentsOf: profilesURL)).flatMap { try? JSONDecoder().decode([VoiceProfile].self, from: $0) } ?? []
    }

    func saveProfiles(_ profiles: [VoiceProfile]) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(profiles).write(to: profilesURL, options: .atomic)
    }

    /// Agrega una huella a la persona (las más viejas se descartan) y la quita de
    /// cualquier otra persona que la tuviera (por si se había reconocido mal).
    func enroll(personId: String, name: String, embedding: [Float]) throws {
        var all = profiles()
        for i in all.indices where all[i].personId != personId {
            all[i].embeddings.removeAll { $0 == embedding }
        }
        if let i = all.firstIndex(where: { $0.personId == personId }) {
            all[i].name = name
            all[i].embeddings = Array((all[i].embeddings.filter { $0 != embedding } + [embedding]).suffix(Self.maxEmbeddingsPerPerson))
        } else {
            all.append(VoiceProfile(personId: personId, name: name, embeddings: [embedding]))
        }
        try saveProfiles(all.filter { !$0.embeddings.isEmpty })
    }

    func forget(personId: String) throws {
        try saveProfiles(profiles().filter { $0.personId != personId })
    }

    func forgetAll() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Huellas de las voces de una sesión (etiqueta → huella), para nombrarlas después.
    func sessionVoices(_ sessionId: String) -> [String: [Float]] {
        (try? Data(contentsOf: sessionURL(sessionId))).flatMap { try? JSONDecoder().decode([String: [Float]].self, from: $0) } ?? [:]
    }

    func saveSessionVoices(_ sessionId: String, _ voices: [String: [Float]]) throws {
        let url = sessionURL(sessionId)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(voices).write(to: url, options: .atomic)
    }
}
