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

/// Momentos en los que el personaje hace un gesto suelto (además de sus estados).
enum CompanionReaction: String, Codable, CaseIterable, Hashable, Sendable {
    case head, body, feet, random, greet, wake, drag

    static let clicks: [CompanionReaction] = [.head, .body, .feet]
    static let automatic: [CompanionReaction] = [.random, .greet, .wake, .drag]

    var label: String {
        switch self {
        case .head: "Clic en la cabeza"
        case .body: "Clic en el cuerpo"
        case .feet: "Clic en los pies"
        case .random: "Al azar"
        case .greet: "Al aparecer"
        case .wake: "Al despertar"
        case .drag: "Al arrastrarlo"
        }
    }

    var detail: String {
        switch self {
        case .head: "Se reproduce una vez cuando haces clic en la parte de arriba del personaje."
        case .body: "Se reproduce una vez cuando haces clic en la parte media del personaje."
        case .feet: "Se reproduce una vez cuando haces clic en la parte de abajo del personaje."
        case .random: "Gestos que hace por su cuenta cada cierto tiempo, mientras está tranquilo (sin grabar ni avisos)."
        case .greet: "Se reproduce una vez cuando el personaje aparece: al abrir la app o al volver a mostrarlo."
        case .wake: "Se reproduce una vez cuando despierta después de haberse dormido."
        case .drag: "Se repite mientras lo arrastras por la pantalla."
        }
    }

    var systemImage: String {
        switch self {
        case .head: "person.crop.circle"
        case .body: "figure.stand"
        case .feet: "shoeprints.fill"
        case .random: "dice"
        case .greet: "hand.wave"
        case .wake: "sun.max"
        case .drag: "hand.draw"
        }
    }

    /// Se repite hasta que termina lo que lo provocó (soltar el personaje).
    var loops: Bool { self == .drag }
}

/// Un clip de animación: un USDZ entero o un recorte (en segundos) de uno, con velocidad opcional.
/// En `character.json` se escribe como `"idle.usdz"` o `{"file": "all.usdz", "start": 0, "end": 2.5, "speed": 1.5}`.
struct ClipSource: Codable, Equatable, Hashable, Sendable {
    static let speedRange = 0.25 ... 4.0

    var file: String
    var start: Double?
    var end: Double?
    /// Velocidad de reproducción (1 = normal); nil = normal.
    var speed: Double?

    init(file: String, start: Double? = nil, end: Double? = nil, speed: Double? = nil) {
        self.file = file
        self.start = start
        self.end = end
        self.speed = speed
    }

    /// Nombre sin extensión, para mostrar.
    var name: String { (file as NSString).deletingPathExtension }

    var playbackSpeed: Double {
        guard let speed, speed.isFinite else { return 1 }
        return min(max(speed, Self.speedRange.lowerBound), Self.speedRange.upperBound)
    }

    /// El mismo clip sin velocidad: identifica la animación que hay que cargar.
    var resourceKey: ClipSource { ClipSource(file: file, start: start, end: end) }

    private enum CodingKeys: String, CodingKey { case file, start, end, speed }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let name = try? single.decode(String.self) {
            file = name
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        file = try c.decode(String.self, forKey: .file)
        start = try c.decodeIfPresent(Double.self, forKey: .start)
        end = try c.decodeIfPresent(Double.self, forKey: .end)
        speed = try c.decodeIfPresent(Double.self, forKey: .speed)
    }

    func encode(to encoder: Encoder) throws {
        if start == nil, end == nil, speed == nil {
            var c = encoder.singleValueContainer()
            try c.encode(file)
        } else {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(file, forKey: .file)
            try c.encodeIfPresent(start, forKey: .start)
            try c.encodeIfPresent(end, forKey: .end)
            try c.encodeIfPresent(speed, forKey: .speed)
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

    /// Cómo se comporta por su cuenta y dónde están sus zonas de clic.
    struct Behavior: Codable, Equatable, Hashable, Sendable {
        static let zoneRange = 0.1 ... 0.45
        static let minimumInterval: TimeInterval = 5

        /// Hace gestos al azar (los de `reactions.random`) mientras está tranquilo.
        var randomEnabled = true
        /// Segundos entre un gesto al azar y el siguiente (mínimo y máximo).
        var randomMin: TimeInterval = 45
        var randomMax: TimeInterval = 120
        /// Parte del alto del personaje (desde arriba) que cuenta como cabeza, y (desde abajo) como pies.
        var headZone = 0.22
        var feetZone = 0.2

        init() {}

        var randomRange: ClosedRange<TimeInterval> {
            let low = max(randomMin.isFinite ? randomMin : 45, Self.minimumInterval)
            let high = max(randomMax.isFinite ? randomMax : low, low)
            return low ... high
        }

        private enum CodingKeys: String, CodingKey { case randomEnabled, randomEvery, headZone, feetZone }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            randomEnabled = try c.decodeIfPresent(Bool.self, forKey: .randomEnabled) ?? true
            if let every = try c.decodeIfPresent([Double].self, forKey: .randomEvery), let first = every.first {
                randomMin = first
                randomMax = every.count > 1 ? every[1] : first
            }
            headZone = Self.clampZone(try c.decodeIfPresent(Double.self, forKey: .headZone) ?? 0.22)
            feetZone = Self.clampZone(try c.decodeIfPresent(Double.self, forKey: .feetZone) ?? 0.2)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(randomEnabled, forKey: .randomEnabled)
            try c.encode([randomMin, randomMax], forKey: .randomEvery)
            try c.encode(headZone, forKey: .headZone)
            try c.encode(feetZone, forKey: .feetZone)
        }

        static func clampZone(_ value: Double) -> Double {
            guard value.isFinite else { return 0.22 }
            return min(max(value, zoneRange.lowerBound), zoneRange.upperBound)
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
    /// Gestos sueltos: clics por zona, al azar, al aparecer, al despertar y al arrastrar.
    var reactions: [CompanionReaction: [ClipSource]]
    var behavior: Behavior
    var scale: Double
    /// Proporción del cuadro en pantalla (ancho ÷ alto). nil = la de un humanoide (`defaultAspect`).
    var aspect: Double?
    /// Encuadre fijo; nil = la app encuadra sola según el tamaño del modelo (recomendado).
    var camera: Camera?
    /// Estado que se usa cuando falta el clip de otro.
    var fallbacks: [CompanionMood: CompanionMood]

    /// Cuadro alto y angosto: un humanoide de pie con algo de aire para mover los brazos.
    static let defaultAspect = 0.55
    /// El pato de serie es casi tan ancho como alto.
    static let duckAspect = 0.9
    static let aspectRange = 0.4 ... 1.2

    /// Proporción efectiva del cuadro, siempre dentro de `aspectRange`.
    var frameAspect: Double {
        let value = aspect ?? Self.defaultAspect
        guard value.isFinite else { return Self.defaultAspect }
        return min(max(value, Self.aspectRange.lowerBound), Self.aspectRange.upperBound)
    }

    static let legacyDefaultCameras = [Camera(distance: 2.3, height: 0.65), Camera(distance: 2.8, height: 0.65)]

    static let defaultFallbacks: [CompanionMood: CompanionMood] = [
        .listening: .idle, .thinking: .idle, .talking: .idle,
        .happy: .talking, .sad: .idle, .alert: .talking, .sleeping: .idle,
    ]

    init(id: String, name: String, base: String? = nil, clips: [CompanionMood: [ClipSource]],
         reactions: [CompanionReaction: [ClipSource]] = [:], behavior: Behavior = Behavior(),
         scale: Double = 1, aspect: Double? = nil, camera: Camera? = nil, fallbacks: [CompanionMood: CompanionMood] = CharacterPack.defaultFallbacks,
         format: Int = CharacterPack.currentFormat) {
        self.format = format
        self.id = id
        self.name = name
        self.base = base
        self.clips = clips
        self.reactions = reactions.filter { !$0.value.isEmpty }
        self.behavior = behavior
        self.scale = scale
        self.aspect = aspect
        self.camera = camera
        self.fallbacks = fallbacks
    }

    private enum CodingKeys: String, CodingKey { case format, id, name, base, clips, reactions, behavior, scale, aspect, camera, fallbacks }

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
        var reactions: [CompanionReaction: [ClipSource]] = [:]
        for (key, list) in try c.decodeIfPresent([String: ClipList].self, forKey: .reactions) ?? [:] {
            if let reaction = CompanionReaction(rawValue: key), !list.clips.isEmpty { reactions[reaction] = list.clips }
        }
        self.reactions = reactions
        behavior = try c.decodeIfPresent(Behavior.self, forKey: .behavior) ?? Behavior()
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? 1
        aspect = try c.decodeIfPresent(Double.self, forKey: .aspect)
        let camera = try c.decodeIfPresent(Camera.self, forKey: .camera)
        // Las primeras versiones del importador escribían la cámara del pato (2.3/0.65 o 2.8/0.65);
        // esos valores se tratan como "encuadre automático" para no tener que reimportar.
        self.camera = camera.flatMap { Self.legacyDefaultCameras.contains($0) ? nil : $0 }
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
        if !reactions.isEmpty {
            try c.encode(Dictionary(uniqueKeysWithValues: reactions.map { ($0.key.rawValue, ClipList($0.value)) }), forKey: .reactions)
        }
        if behavior != Behavior() { try c.encode(behavior, forKey: .behavior) }
        try c.encode(scale, forKey: .scale)
        try c.encodeIfPresent(aspect, forKey: .aspect)
        try c.encodeIfPresent(camera, forKey: .camera)
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
        var all = Set(allClips.map(\.file))
        if let base { all.insert(base) }
        return all
    }

    /// Todos los clips asignados (estados y reacciones), sin repetir.
    var allClips: [ClipSource] {
        var seen: Set<ClipSource> = []
        var all: [ClipSource] = []
        let lists = CompanionMood.allCases.map { clips[$0] ?? [] } + CompanionReaction.allCases.map { reactions[$0] ?? [] }
        for clip in lists.joined() where seen.insert(clip).inserted { all.append(clip) }
        return all
    }

    // MARK: Apartados (un estado o una reacción) para la pantalla de animaciones

    func clips(in slot: AnimationSlot) -> [ClipSource] {
        switch slot {
        case let .mood(mood): clips[mood] ?? []
        case let .reaction(reaction): reactions[reaction] ?? []
        }
    }

    mutating func setClips(_ list: [ClipSource], in slot: AnimationSlot) {
        switch slot {
        case let .mood(mood): clips[mood] = list.isEmpty ? nil : list
        case let .reaction(reaction): reactions[reaction] = list.isEmpty ? nil : list
        }
    }

    /// Apartados que usan un archivo.
    func slots(using file: String) -> [AnimationSlot] {
        AnimationSlot.all.filter { slot in clips(in: slot).contains { $0.file == file } }
    }

    /// Quita un archivo de todos los apartados.
    mutating func removeFile(_ file: String) {
        for slot in AnimationSlot.all {
            let list = clips(in: slot)
            let kept = list.filter { $0.file != file }
            if kept.count != list.count { setClips(kept, in: slot) }
        }
    }

    var isBuiltIn: Bool { id == CharacterPack.builtInId }

    /// El pato integrado: sin archivos, sus animaciones las genera `ProceduralDuck`.
    static let builtInDuck = CharacterPack(
        id: builtInId, name: "Pato",
        clips: Dictionary(uniqueKeysWithValues: CompanionMood.allCases.map { ($0, [ClipSource(file: $0.rawValue)]) }),
        reactions: [
            .head: [ClipSource(file: CompanionMood.happy.rawValue)],
            .body: [ClipSource(file: CompanionMood.talking.rawValue)],
            .feet: [ClipSource(file: CompanionMood.alert.rawValue)],
            .random: [ClipSource(file: CompanionMood.thinking.rawValue), ClipSource(file: CompanionMood.alert.rawValue)],
            .greet: [ClipSource(file: CompanionMood.alert.rawValue)],
            .wake: [ClipSource(file: CompanionMood.happy.rawValue)],
            .drag: [ClipSource(file: CompanionMood.happy.rawValue)],
        ],
        aspect: duckAspect, camera: Camera(), fallbacks: [:]
    )
}

/// Un apartado al que se le asignan animaciones: un estado o una reacción.
enum AnimationSlot: Hashable, Sendable {
    case mood(CompanionMood)
    case reaction(CompanionReaction)

    static let all: [AnimationSlot] = CompanionMood.allCases.map(AnimationSlot.mood) + CompanionReaction.allCases.map(AnimationSlot.reaction)

    var label: String {
        switch self {
        case let .mood(mood): mood.label
        case let .reaction(reaction): reaction.label
        }
    }
}

/// Un personaje disponible: su paquete y la carpeta con los archivos (nil para el pato).
struct InstalledCharacter: Identifiable, Hashable, Sendable {
    let pack: CharacterPack
    let folder: URL?

    var id: String { pack.id }
    var name: String { pack.name }
    var isBuiltIn: Bool { folder == nil }

    func url(for file: String) -> URL? { folder?.appending(path: file) }

    /// Se puede modificar desde la pantalla de animaciones (los de la app y el pato, no).
    var isEditable: Bool {
        guard let folder else { return false }
        return FileManager.default.isWritableFile(atPath: folder.path)
    }

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

    /// Escribe el `character.json` de un personaje.
    static func save(_ pack: CharacterPack, in folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(pack).write(to: folder.appending(path: CharacterPack.fileName), options: .atomic)
    }

    /// Copia archivos de animación a la carpeta del personaje (reemplaza los que se llamen igual).
    /// Devuelve los nombres con los que quedaron; ignora lo que no sea un modelo USD.
    @discardableResult
    static func addAnimations(_ urls: [URL], to folder: URL) throws -> [String] {
        let fm = FileManager.default
        var added: [String] = []
        for url in urls where CharacterImporter.modelExtensions.contains(url.pathExtension.lowercased()) {
            let destination = folder.appending(path: url.lastPathComponent)
            if destination.standardizedFileURL != url.standardizedFileURL {
                if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                try fm.copyItem(at: url, to: destination)
            }
            added.append(url.lastPathComponent)
        }
        return added
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

    /// Palabras que identifican una reacción; se miran antes que los estados ("head_happy" es clic en la cabeza).
    static let reactionSynonyms: [(reaction: CompanionReaction, words: [String])] = [
        (.head, ["head", "cabeza"]),
        (.feet, ["feet", "foot", "pies"]),
        (.body, ["body", "cuerpo", "torso"]),
        (.random, ["random", "azar", "gesto", "gesture"]),
        (.greet, ["greet", "aparec"]),
        (.wake, ["wake", "despert"]),
        (.drag, ["drag", "arrastr"]),
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
        let all = mapAllByName(files)
        return (all.clips, all.unmatched)
    }

    /// Igual que `mapByName`, pero también reconoce las reacciones (clics, al azar, etc.).
    static func mapAllByName(_ files: [String]) -> (clips: [CompanionMood: [ClipSource]], reactions: [CompanionReaction: [ClipSource]], unmatched: [String]) {
        var clips: [CompanionMood: [ClipSource]] = [:]
        var reactions: [CompanionReaction: [ClipSource]] = [:]
        var unmatched: [String] = []
        for file in files.sorted() {
            let stem = normalize(file)
            if let match = reactionSynonyms.first(where: { entry in entry.words.contains { stem.contains($0) } }) {
                reactions[match.reaction, default: []].append(ClipSource(file: file))
            } else if let mood = matchOrder.first(where: { mood in synonyms[mood, default: []].contains { stem.contains($0) } }) {
                clips[mood, default: []].append(ClipSource(file: file))
            } else {
                unmatched.append(file)
            }
        }
        return (clips, reactions, unmatched)
    }

    static func slug(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        let parts = folded.split { !$0.isLetter && !$0.isNumber }
        let slug = parts.joined(separator: "-")
        return slug.isEmpty ? "personaje" : slug
    }

    static func makePack(id: String, name: String, files: [String]) -> (pack: CharacterPack, unmatched: [String]) {
        let (clips, reactions, unmatched) = mapAllByName(files)
        return (CharacterPack(id: id, name: name, clips: clips, reactions: reactions), unmatched)
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
            try CharacterLibrary.save(pack, in: destination)
        }
        return (InstalledCharacter(pack: pack, folder: destination), unmatched)
    }
}
