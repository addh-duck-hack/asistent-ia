import Foundation

/// Estado de ánimo del personaje; cada uno tiene su animación.
enum CompanionMood: String, Codable, CaseIterable, Hashable, Sendable {
    case idle, listening, thinking, talking, happy, sad, alert, sleeping

    var label: String {
        switch self {
        case .idle: "Tranquilo"
        case .listening: "Escuchando"
        case .thinking: "Pensando"
        case .talking: "Hablando"
        case .happy: "Contento"
        case .sad: "Triste"
        case .alert: "Avisando"
        case .sleeping: "Dormido"
        }
    }
}

/// Un clip de animación: un USDZ entero o un recorte (en segundos) de uno.
/// En `character.json` se escribe como `"idle.usdz"` o `{"file": "all.usdz", "start": 0, "end": 2.5}`.
struct ClipSource: Codable, Equatable, Hashable, Sendable {
    var file: String
    var start: Double?
    var end: Double?

    init(file: String, start: Double? = nil, end: Double? = nil) {
        self.file = file
        self.start = start
        self.end = end
    }

    private enum CodingKeys: String, CodingKey { case file, start, end }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let name = try? single.decode(String.self) {
            file = name
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        file = try c.decode(String.self, forKey: .file)
        start = try c.decodeIfPresent(Double.self, forKey: .start)
        end = try c.decodeIfPresent(Double.self, forKey: .end)
    }

    func encode(to encoder: Encoder) throws {
        if start == nil, end == nil {
            var c = encoder.singleValueContainer()
            try c.encode(file)
        } else {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(file, forKey: .file)
            try c.encodeIfPresent(start, forKey: .start)
            try c.encodeIfPresent(end, forKey: .end)
        }
    }
}

/// Lista de clips que en el JSON puede venir como un solo clip o como arreglo.
struct ClipList: Codable, Equatable, Sendable {
    var clips: [ClipSource]

    init(_ clips: [ClipSource]) { self.clips = clips }

    init(from decoder: Decoder) throws {
        if var list = try? decoder.unkeyedContainer() {
            var clips: [ClipSource] = []
            while !list.isAtEnd { clips.append(try list.decode(ClipSource.self)) }
            self.clips = clips
        } else {
            clips = [try ClipSource(from: decoder)]
        }
    }

    func encode(to encoder: Encoder) throws {
        if clips.count == 1 {
            try clips[0].encode(to: encoder)
        } else {
            var c = encoder.unkeyedContainer()
            for clip in clips { try c.encode(clip) }
        }
    }
}

/// Descripción de un personaje: carpeta con `character.json` y uno o varios USDZ
/// con el mismo esqueleto (RealityKit no lista bien varias animaciones esqueléticas
/// dentro de un mismo archivo; lo fiable es un archivo por estado).
struct CharacterPack: Codable, Identifiable, Equatable, Hashable, Sendable {
    struct Camera: Codable, Equatable, Hashable, Sendable {
        /// Distancia de la cámara al personaje y altura a la que mira (metros, con el personaje de ~1.2 m).
        var distance: Double
        var height: Double

        init(distance: Double = 2.3, height: Double = 0.65) {
            self.distance = distance
            self.height = height
        }

        private enum CodingKeys: String, CodingKey { case distance, height }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            distance = try c.decodeIfPresent(Double.self, forKey: .distance) ?? 2.3
            height = try c.decodeIfPresent(Double.self, forKey: .height) ?? 0.65
        }
    }

    static let currentFormat = 1
    static let fileName = "character.json"
    static let builtInId = "pato"

    var format: Int
    var id: String
    var name: String
    /// Modelo base (con el esqueleto). Si falta, se usa el primer clip.
    var base: String?
    var clips: [CompanionMood: [ClipSource]]
    var scale: Double
    var camera: Camera
    /// Estado que se usa cuando falta el clip de otro.
    var fallbacks: [CompanionMood: CompanionMood]

    static let defaultFallbacks: [CompanionMood: CompanionMood] = [
        .listening: .idle, .thinking: .idle, .talking: .idle,
        .happy: .talking, .sad: .idle, .alert: .talking, .sleeping: .idle,
    ]

    init(id: String, name: String, base: String? = nil, clips: [CompanionMood: [ClipSource]],
         scale: Double = 1, camera: Camera = Camera(), fallbacks: [CompanionMood: CompanionMood] = CharacterPack.defaultFallbacks,
         format: Int = CharacterPack.currentFormat) {
        self.format = format
        self.id = id
        self.name = name
        self.base = base
        self.clips = clips
        self.scale = scale
        self.camera = camera
        self.fallbacks = fallbacks
    }

    private enum CodingKeys: String, CodingKey { case format, id, name, base, clips, scale, camera, fallbacks }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decodeIfPresent(Int.self, forKey: .format) ?? CharacterPack.currentFormat
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        base = try c.decodeIfPresent(String.self, forKey: .base)
        var clips: [CompanionMood: [ClipSource]] = [:]
        for (key, list) in try c.decodeIfPresent([String: ClipList].self, forKey: .clips) ?? [:] {
            if let mood = CompanionMood(rawValue: key), !list.clips.isEmpty { clips[mood] = list.clips }
        }
        self.clips = clips
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? 1
        camera = try c.decodeIfPresent(Camera.self, forKey: .camera) ?? Camera()
        if let raw = try c.decodeIfPresent([String: String].self, forKey: .fallbacks) {
            var fallbacks: [CompanionMood: CompanionMood] = [:]
            for (key, value) in raw {
                if let from = CompanionMood(rawValue: key), let to = CompanionMood(rawValue: value) { fallbacks[from] = to }
            }
            self.fallbacks = fallbacks
        } else {
            fallbacks = CharacterPack.defaultFallbacks
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(format, forKey: .format)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(base, forKey: .base)
        try c.encode(Dictionary(uniqueKeysWithValues: clips.map { ($0.key.rawValue, ClipList($0.value)) }), forKey: .clips)
        try c.encode(scale, forKey: .scale)
        try c.encode(camera, forKey: .camera)
        try c.encode(Dictionary(uniqueKeysWithValues: fallbacks.map { ($0.key.rawValue, $0.value.rawValue) }), forKey: .fallbacks)
    }

    /// Estado cuyo clip se usará para `mood`: el mismo si lo tiene, si no el de respaldo
    /// (siguiendo la cadena sin ciclos) y, en último caso, `idle`. nil si no hay nada.
    func resolvedMood(for mood: CompanionMood) -> CompanionMood? {
        var current = mood
        var seen: Set<CompanionMood> = []
        while !seen.contains(current) {
            if let list = clips[current], !list.isEmpty { return current }
            seen.insert(current)
            guard let next = fallbacks[current] else { break }
            current = next
        }
        if let list = clips[.idle], !list.isEmpty { return .idle }
        return nil
    }

    func resolveClips(for mood: CompanionMood) -> [ClipSource] {
        resolvedMood(for: mood).flatMap { clips[$0] } ?? []
    }

    /// Archivo del modelo base: `base` o el primer clip (idle si existe).
    var baseFile: String? {
        base ?? clips[.idle]?.first?.file ?? CompanionMood.allCases.lazy.compactMap { clips[$0]?.first?.file }.first
    }

    /// Todos los archivos a los que hace referencia.
    var files: Set<String> {
        var all = Set(clips.values.flatMap { $0.map(\.file) })
        if let base { all.insert(base) }
        return all
    }

    var isBuiltIn: Bool { id == CharacterPack.builtInId }

    /// El pato integrado: sin archivos, sus animaciones las genera `ProceduralDuck`.
    static let builtInDuck = CharacterPack(
        id: builtInId, name: "Pato",
        clips: Dictionary(uniqueKeysWithValues: CompanionMood.allCases.map { ($0, [ClipSource(file: $0.rawValue)]) }),
        fallbacks: [:]
    )
}

/// Un personaje disponible: su paquete y la carpeta con los archivos (nil para el pato).
struct InstalledCharacter: Identifiable, Hashable, Sendable {
    let pack: CharacterPack
    let folder: URL?

    var id: String { pack.id }
    var name: String { pack.name }
    var isBuiltIn: Bool { folder == nil }

    func url(for file: String) -> URL? { folder?.appending(path: file) }

    static let duck = InstalledCharacter(pack: .builtInDuck, folder: nil)
}

/// Dónde se buscan los personajes: dentro de la app y en Application Support.
enum CharacterLibrary {
    static let selectedKey = "companionCharacter"

    static var userDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "AsistentIA/Characters", directoryHint: .isDirectory)
    }

    static var bundledDirectory: URL? {
        Bundle.main.resourceURL?.appending(path: "Characters", directoryHint: .isDirectory)
    }

    /// El pato primero; después los paquetes de la app y los del usuario (estos últimos mandan si se repite el id).
    static func installed() -> [InstalledCharacter] {
        var byId: [String: InstalledCharacter] = [:]
        var order: [String] = [InstalledCharacter.duck.id]
        byId[InstalledCharacter.duck.id] = .duck
        for directory in [bundledDirectory, userDirectory].compactMap({ $0 }) {
            for character in packs(in: directory) {
                if byId[character.id] == nil { order.append(character.id) }
                byId[character.id] = character
            }
        }
        return order.compactMap { byId[$0] }
    }

    static func packs(in directory: URL) -> [InstalledCharacter] {
        guard let items = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }
        return items
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .compactMap { try? load(folder: $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func load(folder: URL) throws -> InstalledCharacter {
        let data = try Data(contentsOf: folder.appending(path: CharacterPack.fileName))
        let pack = try JSONDecoder().decode(CharacterPack.self, from: data)
        return InstalledCharacter(pack: pack, folder: folder)
    }

    static func selected(from installed: [InstalledCharacter]? = nil) -> InstalledCharacter {
        let id = UserDefaults.standard.string(forKey: selectedKey) ?? CharacterPack.builtInId
        return (installed ?? self.installed()).first { $0.id == id } ?? .duck
    }
}

/// Importa una carpeta con USDZ: si no trae `character.json`, lo genera mapeando por nombre de archivo.
enum CharacterImporter {
    enum ImportError: LocalizedError {
        case notAFolder
        case noClips([String])

        var errorDescription: String? {
            switch self {
            case .notAFolder: "Elige una carpeta con los archivos .usdz del personaje."
            case let .noClips(files):
                files.isEmpty
                    ? "La carpeta no tiene archivos .usdz."
                    : "No reconocí ningún estado en los nombres: \(files.joined(separator: ", ")). Usa idle, listening, thinking, talking, happy, sad, alert o sleeping."
            }
        }
    }

    static let modelExtensions: Set<String> = ["usdz", "usdc", "usda", "usd", "reality"]

    /// Palabras (sin acentos, en minúsculas) que identifican cada estado en el nombre del archivo.
    static let synonyms: [CompanionMood: [String]] = [
        .idle: ["idle", "tranquil", "reposo", "breath", "neutral"],
        .listening: ["listen", "escuch", "attent", "atent"],
        .thinking: ["think", "piens", "pens", "ponder"],
        .talking: ["talk", "habl", "speak"],
        .happy: ["happy", "feliz", "content", "jump", "salt", "dance", "bail", "celebr", "cheer", "victory"],
        .sad: ["sad", "trist", "cry", "llor", "defeat"],
        .alert: ["alert", "wav", "salud", "hello", "hola", "aviso"],
        .sleeping: ["sleep", "duerm", "dorm", "nap"],
    ]

    /// Los estados más específicos van antes que `idle` ("sad_idle" es triste, no tranquilo).
    private static let matchOrder: [CompanionMood] = [.sleeping, .alert, .sad, .happy, .talking, .thinking, .listening, .idle]

    static func normalize(_ name: String) -> String {
        (name as NSString).deletingPathExtension
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased()
    }

    /// Asigna un estado a cada archivo por su nombre; devuelve también los que no se reconocieron.
    static func mapByName(_ files: [String]) -> (clips: [CompanionMood: [ClipSource]], unmatched: [String]) {
        var clips: [CompanionMood: [ClipSource]] = [:]
        var unmatched: [String] = []
        for file in files.sorted() {
            let stem = normalize(file)
            if let mood = matchOrder.first(where: { mood in synonyms[mood, default: []].contains { stem.contains($0) } }) {
                clips[mood, default: []].append(ClipSource(file: file))
            } else {
                unmatched.append(file)
            }
        }
        return (clips, unmatched)
    }

    static func slug(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        let parts = folded.split { !$0.isLetter && !$0.isNumber }
        let slug = parts.joined(separator: "-")
        return slug.isEmpty ? "personaje" : slug
    }

    static func makePack(id: String, name: String, files: [String]) -> (pack: CharacterPack, unmatched: [String]) {
        let (clips, unmatched) = mapByName(files)
        return (CharacterPack(id: id, name: name, clips: clips), unmatched)
    }

    static func modelFiles(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { modelExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted()
    }

    /// Copia la carpeta a la biblioteca del usuario (reemplaza un personaje con el mismo id)
    /// y escribe `character.json` si no existía.
    @discardableResult
    static func importFolder(_ source: URL, into library: URL = CharacterLibrary.userDirectory) throws -> (character: InstalledCharacter, unmatched: [String]) {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ImportError.notAFolder
        }
        let files = try modelFiles(in: source)
        let jsonURL = source.appending(path: CharacterPack.fileName)
        var pack: CharacterPack
        var unmatched: [String] = []
        if fm.fileExists(atPath: jsonURL.path) {
            pack = try JSONDecoder().decode(CharacterPack.self, from: Data(contentsOf: jsonURL))
        } else {
            (pack, unmatched) = makePack(id: slug(source.lastPathComponent), name: source.lastPathComponent, files: files)
        }
        guard !pack.clips.isEmpty else { throw ImportError.noClips(files) }
        if pack.id == CharacterPack.builtInId { pack.id = "\(pack.id)-importado" }

        try fm.createDirectory(at: library, withIntermediateDirectories: true)
        let destination = library.appending(path: pack.id, directoryHint: .isDirectory)
        if destination.standardizedFileURL != source.standardizedFileURL {
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.copyItem(at: source, to: destination)
        }
        let destinationJSON = destination.appending(path: CharacterPack.fileName)
        if !fm.fileExists(atPath: destinationJSON.path) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(pack).write(to: destinationJSON)
        }
        return (InstalledCharacter(pack: pack, folder: destination), unmatched)
    }
}
