import AppKit
import RealityKit
import SwiftUI
import os

private let log = Logger(subsystem: "cloud.duck-hack.asistent-ia", category: "companion")

/// Personaje de un paquete USDZ: un modelo base y un archivo por animación (todos con el mismo esqueleto).
/// Los clips se cargan cuando hacen falta y, de fondo, el resto: el personaje aparece rápido aunque tenga muchos.
@MainActor
final class ClipCharacter: CharacterActor {
    enum LoadError: LocalizedError {
        case noModel
        var errorDescription: String? { "El paquete no tiene ningún archivo de modelo." }
    }

    let root = Entity()
    private(set) var height: Float = 1.2
    private let model: Entity
    private let folder: URL
    private var pack: CharacterPack
    /// Primera animación de cada archivo ya cargado.
    private var raw: [String: AnimationResource] = [:]
    /// Animación lista para reproducir de cada clip (con su recorte).
    private var resources: [ClipSource: AnimationResource] = [:]
    private var failed: Set<String> = []
    /// Cambia en cada `play`/`perform`: lo que termine de cargar tarde se descarta.
    private var token = 0
    private var playTask: Task<Void, Never>?
    private var preloadTask: Task<Void, Never>?
    private var lastClip: [CompanionMood: ClipSource] = [:]
    private var started = false

    init(character: InstalledCharacter) async throws {
        pack = character.pack
        guard let folder = character.folder, let baseFile = pack.baseFile else { throw LoadError.noModel }
        self.folder = folder
        model = try await Entity(contentsOf: folder.appending(path: baseFile))

        // Normaliza el tamaño (1.2 m de alto por defecto) y apoya los pies en y = 0.
        let bounds = model.visualBounds(relativeTo: nil)
        let largest = max(bounds.extents.x, bounds.extents.y, bounds.extents.z, 0.001)
        let scale = Float(1.2 / Double(largest) * pack.scale)
        model.scale = [scale, scale, scale]
        model.position = [-bounds.center.x * scale, -bounds.min.y * scale, -bounds.center.z * scale]
        height = bounds.extents.y * scale
        root.addChild(model)

        raw[baseFile] = model.availableAnimations.first
        // El reposo listo antes de mostrarlo; lo demás, de fondo.
        if let idle = pack.resolveClips(for: .idle).first { _ = await resource(for: idle) }
        preload()
    }

    private func resource(for clip: ClipSource) async -> AnimationResource? {
        let key = clip.resourceKey
        if let ready = resources[key] { return ready }
        if raw[clip.file] == nil {
            guard !failed.contains(clip.file) else { return nil }
            do {
                let entity = try await Entity(contentsOf: folder.appending(path: clip.file))
                if let animation = entity.availableAnimations.first {
                    raw[clip.file] = animation
                } else {
                    log.error("\(clip.file) no tiene animaciones")
                }
            } catch {
                // Un cambio de estado o un gesto cancela la tarea que estaba cargando: no es un archivo dañado,
                // se vuelve a intentar la próxima vez que se pida (si no, el clip quedaba vetado y el personaje congelado).
                if error is CancellationError || Task.isCancelled { return nil }
                log.error("No se pudo cargar \(clip.file): \(error.localizedDescription)")
            }
        }
        guard var animation = raw[clip.file] else {
            if !Task.isCancelled { failed.insert(clip.file) }
            return nil
        }
        if let start = clip.start, let end = clip.end, end > start,
           let trimmed = try? AnimationResource.generate(with: animation.definition.trimmed(start: start, end: end)) {
            animation = trimmed
        }
        resources[key] = animation
        return animation
    }

    private func preload() {
        preloadTask?.cancel()
        let clips = pack.allClips
        preloadTask = Task { [weak self] in
            for clip in clips {
                guard let self, !Task.isCancelled else { return }
                _ = await self.resource(for: clip)
            }
        }
    }

    @discardableResult
    private func start(_ animation: AnimationResource, clip: ClipSource, loops: Bool) -> AnimationPlaybackController {
        // La primera animación entra sin mezcla: si no, se ve un instante la pose base (en T).
        let controller = model.playAnimation(loops ? animation.repeat() : animation, transitionDuration: started ? 0.3 : 0)
        started = true
        controller.speed = Float(clip.playbackSpeed)
        return controller
    }

    func play(_ mood: CompanionMood) {
        token += 1
        let mine = token
        playTask?.cancel()
        guard let clip = CompanionModel.pick(from: pack.resolveClips(for: mood), avoiding: lastClip[mood]) else {
            model.stopAllAnimations()
            return
        }
        lastClip[mood] = clip
        if let ready = resources[clip.resourceKey] {
            start(ready, clip: clip, loops: true)
            return
        }
        playTask = Task { [weak self] in
            guard let self, let animation = await self.resource(for: clip), self.token == mine else { return }
            self.start(animation, clip: clip, loops: true)
        }
    }

    func perform(_ clip: ClipSource, loops: Bool, completion: @escaping @MainActor () -> Void) {
        token += 1
        let mine = token
        playTask?.cancel()
        playTask = Task { [weak self] in
            guard let self else { return }
            guard let animation = await self.resource(for: clip) else {
                if self.token == mine { completion() }
                return
            }
            guard self.token == mine else { return }
            let controller = self.start(animation, clip: clip, loops: loops)
            guard !loops else { return }
            // Avisa un poco antes del final para que la vuelta al estado se mezcle sin tirón.
            let seconds = max(controller.duration / clip.playbackSpeed - 0.25, 0.2)
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, self.token == mine else { return }
            completion()
        }
    }

    func variants(for mood: CompanionMood) -> Int { pack.resolveClips(for: mood).count }

    func apply(_ pack: CharacterPack) {
        self.pack = pack
        failed = []
        preload()
    }

    func look(toward point: SIMD2<Float>?) {
        var target = Transform()
        if let p = point {
            target.rotation = simd_quatf(angle: p.x * 0.3, axis: [0, 1, 0])
        }
        root.move(to: target, relativeTo: root.parent, duration: 0.25, timingFunction: .easeOut)
    }

    func stop() {
        token += 1
        playTask?.cancel()
        preloadTask?.cancel()
    }
}

/// Encuadre automático: la cámara se aleja lo justo para que el personaje llene el cuadro
/// con un margen para que las animaciones no se salgan.
enum CharacterFraming {
    /// Proporción (ancho ÷ alto) por debajo de la cual el ancho del cuadro ya no aleja la cámara:
    /// un cuadro más angosto recorta los lados en lugar de achicar al personaje.
    static let referenceAspect = Float(CharacterPack.duckAspect)
    /// Parte del alto del cuadro que ocupa el personaje.
    static let fill: Float = 0.95
    static let tPoseWidthFactor: Float = 0.75

    /// Ancho de un humanoide de pie respecto a su alto, con aire para balancearse y mover los brazos.
    static let standingWidthFactor: Float = 0.5

    static func frame(extents: SIMD3<Float>, center: SIMD3<Float>, fieldOfViewDegrees: Float,
                      zoom: Float = 1, aspect: Float = referenceAspect) -> (position: SIMD3<Float>, target: SIMD3<Float>) {
        // Lo que debe caber a lo alto: el alto real o el ancho llevado a la proporción del cuadro.
        // El modelo se mide en su pose base, que en Mixamo es en T (brazos extendidos, ancho ≈ alto),
        // pero en las animaciones los brazos van abajo: el ancho cuenta solo en parte.
        // En un cuadro angosto el ancho de la pose T no cuenta entero (alejaría demasiado la cámara), pero
        // el cuerpo de pie sí tiene que caber: por debajo de cierta proporción el personaje se achica en vez de cortarse.
        let poseWidth = extents.x * tPoseWidthFactor
        let standingWidth = min(poseWidth, extents.y * standingWidthFactor)
        let needed = max(extents.y, poseWidth / effectiveAspect(aspect), standingWidth / max(aspect, 0.1), 0.01) / fill
        let halfAngle = fieldOfViewDegrees * .pi / 360
        let distance = (needed / 2) / tan(halfAngle) / max(zoom, 0.1) + extents.z / 2
        // Un poco por encima del centro, mirando ligeramente hacia abajo.
        let target = center
        let position = SIMD3<Float>(center.x, center.y + extents.y * 0.08, center.z + distance)
        return (position, target)
    }

    static func effectiveAspect(_ aspect: Float) -> Float { max(aspect, referenceAspect) }
}

/// La escena 3D del personaje (`ARView` con fondo transparente; `RealityView` pinta fondo opaco en macOS).
struct CharacterSceneView: NSViewRepresentable {
    let character: InstalledCharacter
    /// Cambia para volver a cargar los archivos del personaje (se reemplazó alguno en disco).
    var revision = 0
    let mood: CompanionMood
    let idleVariant: Int
    let look: SIMD2<Float>?
    var gesture: CompanionModel.Gesture?
    var onGestureEnd: (@MainActor (UUID) -> Void)?

    func makeNSView(context: Context) -> ARView {
        let view = ARView(frame: .zero)
        view.environment.background = .color(.clear)
        let coordinator = context.coordinator
        coordinator.attach(to: view)
        coordinator.onGestureEnd = onGestureEnd
        coordinator.gesture = gesture
        coordinator.revision = revision
        coordinator.load(character, mood: mood)
        return view
    }

    func updateNSView(_ view: ARView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onGestureEnd = onGestureEnd
        coordinator.gesture = gesture
        if coordinator.needsReload(character, revision: revision) {
            coordinator.revision = revision
            coordinator.load(character, mood: mood)
        } else {
            let packChanged = coordinator.apply(character.pack)
            if coordinator.mood != mood || packChanged {
                coordinator.play(mood)
            } else if coordinator.idleVariant != idleVariant, coordinator.canVary(mood) {
                coordinator.play(mood)
            }
            coordinator.syncGesture()
        }
        coordinator.idleVariant = idleVariant
        coordinator.look(look)
    }

    static func dismantleNSView(_ view: ARView, coordinator: Coordinator) {
        coordinator.unload()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        private let anchor = AnchorEntity(world: .zero)
        private let camera = PerspectiveCamera()
        private var actor: CharacterActor?
        private var loadTask: Task<Void, Never>?
        private var lastLook: SIMD2<Float>?
        private var pack: CharacterPack?
        private var restBounds: BoundingBox?
        /// Gesto que pide el modelo, el último que ya se mandó a reproducir y el que sigue en marcha.
        var gesture: CompanionModel.Gesture?
        private var requestedGesture: UUID?
        private var activeGesture: UUID?
        var onGestureEnd: (@MainActor (UUID) -> Void)?
        var characterId: String?
        var revision = 0
        var mood: CompanionMood = .idle
        var idleVariant = 0

        func attach(to view: ARView) {
            let light = DirectionalLight()
            light.light.intensity = 1500
            light.position = [1, 3, 2]
            light.look(at: [0, 0.6, 0], from: light.position, relativeTo: nil)
            anchor.addChild(light)
            anchor.addChild(camera)
            view.scene.addAnchor(anchor)
        }

        /// Otro personaje, otros archivos en disco, o un cambio que mueve el modelo o la cámara.
        func needsReload(_ character: InstalledCharacter, revision: Int) -> Bool {
            guard characterId == character.id, self.revision == revision, let pack else { return true }
            let new = character.pack
            return pack.baseFile != new.baseFile
        }

        /// Coloca la cámara según el zoom, la proporción y el encuadre del paquete (sin recargar el modelo).
        private func frameCamera(for pack: CharacterPack) {
            guard let actor else { return }
            if let cam = pack.camera {
                let position = SIMD3<Float>(0, Float(cam.height) + actor.height * 0.35, Float(cam.distance))
                camera.look(at: [0, Float(cam.height), 0], from: position, relativeTo: nil)
            } else if let bounds = restBounds {
                let frame = CharacterFraming.frame(extents: bounds.extents, center: bounds.center,
                                                   fieldOfViewDegrees: camera.camera.fieldOfViewInDegrees,
                                                   zoom: Float(pack.scale), aspect: Float(pack.frameAspect))
                camera.look(at: frame.target, from: frame.position, relativeTo: nil)
            }
        }

        /// Pasa al personaje los cambios del paquete. Devuelve true si cambiaron las animaciones del estado actual.
        func apply(_ new: CharacterPack) -> Bool {
            guard let old = pack, old != new else { return false }
            pack = new
            actor?.apply(new)
            if old.scale != new.scale || old.frameAspect != new.frameAspect || old.camera != new.camera {
                frameCamera(for: new)
            }
            return old.resolveClips(for: mood) != new.resolveClips(for: mood)
        }

        func load(_ character: InstalledCharacter, mood: CompanionMood) {
            loadTask?.cancel()
            unload()
            characterId = character.id
            pack = character.pack
            self.mood = mood
            loadTask = Task { @MainActor [weak self] in
                let actor: CharacterActor
                if character.isBuiltIn {
                    actor = ProceduralDuck()
                } else {
                    do {
                        actor = try await ClipCharacter(character: character)
                    } catch {
                        log.error("Personaje \(character.id): \(error.localizedDescription); se usa el pato")
                        actor = ProceduralDuck()
                    }
                }
                guard let self, !Task.isCancelled else { return }
                self.actor = actor
                self.anchor.addChild(actor.root)
                // Medido en la pose base, antes de animar: sirve para reencuadrar al cambiar zoom o proporción.
                self.restBounds = actor.root.visualBounds(relativeTo: nil)
                self.frameCamera(for: self.pack ?? character.pack)
                if let latest = self.pack, latest != character.pack { actor.apply(latest) }
                actor.play(self.mood)
                // Un gesto pedido mientras cargaba (el saludo al aparecer).
                self.requestedGesture = nil
                self.syncGesture()
            }
        }

        func unload() {
            loadTask?.cancel()
            actor?.stop()
            actor?.root.removeFromParent()
            actor = nil
            if let old = activeGesture {
                activeGesture = nil
                notifyEnd(old)
            }
        }

        /// Cambia de estado; si había un gesto en marcha, lo interrumpe.
        func play(_ mood: CompanionMood) {
            self.mood = mood
            if let old = activeGesture {
                activeGesture = nil
                notifyEnd(old)
            }
            actor?.play(mood)
        }

        /// En reposo siempre varía; en otros estados, solo si tienen varias animaciones y no hay un gesto en marcha.
        func canVary(_ mood: CompanionMood) -> Bool {
            guard activeGesture == nil, let actor else { return false }
            return mood == .idle || actor.variants(for: mood) > 1
        }

        /// Empieza el gesto que pide el modelo, o vuelve al estado si lo quitó.
        func syncGesture() {
            guard gesture?.id != requestedGesture, let actor else { return }
            requestedGesture = gesture?.id
            guard let gesture else {
                if activeGesture != nil {
                    activeGesture = nil
                    actor.play(mood)
                }
                return
            }
            if let old = activeGesture { notifyEnd(old) }
            activeGesture = gesture.id
            let id = gesture.id
            actor.perform(gesture.clip, loops: gesture.loops) { [weak self] in
                guard let self, self.activeGesture == id else { return }
                self.activeGesture = nil
                self.actor?.play(self.mood)
                self.notifyEnd(id)
            }
        }

        /// Fuera del ciclo de actualización de la vista (cambia el estado del modelo).
        private func notifyEnd(_ id: UUID) {
            guard let onGestureEnd else { return }
            Task { @MainActor in onGestureEnd(id) }
        }

        func look(_ point: SIMD2<Float>?) {
            guard point != lastLook else { return }
            lastLook = point
            actor?.look(toward: point)
        }
    }
}
