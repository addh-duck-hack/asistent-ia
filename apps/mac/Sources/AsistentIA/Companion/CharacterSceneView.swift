import AppKit
import RealityKit
import SwiftUI
import os

private let log = Logger(subsystem: "cloud.duck-hack.asistent-ia", category: "companion")

/// Personaje de un paquete USDZ: un modelo base y un clip por estado (archivos con el mismo esqueleto).
@MainActor
final class ClipCharacter: CharacterActor {
    enum LoadError: LocalizedError {
        case noModel
        var errorDescription: String? { "El paquete no tiene ningún archivo de modelo." }
    }

    let root = Entity()
    private(set) var height: Float = 1.2
    private let model: Entity
    private var clips: [CompanionMood: [AnimationResource]] = [:]
    private let pack: CharacterPack

    init(character: InstalledCharacter) async throws {
        pack = character.pack
        guard let folder = character.folder, let baseFile = pack.baseFile else { throw LoadError.noModel }
        model = try await Entity(contentsOf: folder.appending(path: baseFile))

        // Normaliza el tamaño (1.2 m de alto por defecto) y apoya los pies en y = 0.
        let bounds = model.visualBounds(relativeTo: nil)
        let largest = max(bounds.extents.x, bounds.extents.y, bounds.extents.z, 0.001)
        let scale = Float(1.2 / Double(largest) * pack.scale)
        model.scale = [scale, scale, scale]
        model.position = [-bounds.center.x * scale, -bounds.min.y * scale, -bounds.center.z * scale]
        height = bounds.extents.y * scale
        root.addChild(model)

        var loaded: [String: Entity] = [baseFile: model]
        for mood in CompanionMood.allCases {
            for clip in pack.clips[mood] ?? [] {
                let entity: Entity
                if let cached = loaded[clip.file] {
                    entity = cached
                } else {
                    do {
                        entity = try await Entity(contentsOf: folder.appending(path: clip.file))
                        loaded[clip.file] = entity
                    } catch {
                        log.error("No se pudo cargar \(clip.file): \(error.localizedDescription)")
                        continue
                    }
                }
                guard var animation = entity.availableAnimations.first else {
                    log.error("\(clip.file) no tiene animaciones")
                    continue
                }
                if let start = clip.start, let end = clip.end, end > start,
                   let trimmed = try? AnimationResource.generate(with: animation.definition.trimmed(start: start, end: end)) {
                    animation = trimmed
                }
                clips[mood, default: []].append(animation)
            }
        }
    }

    func play(_ mood: CompanionMood) {
        guard let resolved = pack.resolvedMood(for: mood), let options = clips[resolved], let clip = options.randomElement() else {
            model.stopAllAnimations()
            return
        }
        model.playAnimation(clip.repeat(), transitionDuration: 0.3)
    }

    func look(toward point: SIMD2<Float>?) {
        var target = Transform()
        if let p = point {
            target.rotation = simd_quatf(angle: p.x * 0.3, axis: [0, 1, 0])
        }
        root.move(to: target, relativeTo: root.parent, duration: 0.25, timingFunction: .easeOut)
    }

    func stop() {}
}

/// La escena 3D del personaje (`ARView` con fondo transparente; `RealityView` pinta fondo opaco en macOS).
struct CharacterSceneView: NSViewRepresentable {
    let character: InstalledCharacter
    let mood: CompanionMood
    let idleVariant: Int
    let look: SIMD2<Float>?

    func makeNSView(context: Context) -> ARView {
        let view = ARView(frame: .zero)
        view.environment.background = .color(.clear)
        context.coordinator.attach(to: view)
        context.coordinator.load(character, mood: mood)
        return view
    }

    func updateNSView(_ view: ARView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.characterId != character.id {
            coordinator.load(character, mood: mood)
        } else if coordinator.mood != mood || (mood == .idle && coordinator.idleVariant != idleVariant) {
            coordinator.play(mood)
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
        var characterId: String?
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

        func load(_ character: InstalledCharacter, mood: CompanionMood) {
            loadTask?.cancel()
            unload()
            characterId = character.id
            self.mood = mood
            let camera = camera
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
                let cam = character.pack.camera
                let position = SIMD3<Float>(0, Float(cam.height) + actor.height * 0.35, Float(cam.distance))
                camera.look(at: [0, Float(cam.height), 0], from: position, relativeTo: nil)
                actor.play(self.mood)
            }
        }

        func unload() {
            loadTask?.cancel()
            actor?.stop()
            actor?.root.removeFromParent()
            actor = nil
        }

        func play(_ mood: CompanionMood) {
            self.mood = mood
            actor?.play(mood)
        }

        func look(_ point: SIMD2<Float>?) {
            guard point != lastLook else { return }
            lastLook = point
            actor?.look(toward: point)
        }
    }
}
