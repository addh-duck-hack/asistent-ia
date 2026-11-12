import AppKit
import RealityKit
import simd

/// Lo que sabe hacer un personaje en la escena, sea el pato integrado o un paquete USDZ.
@MainActor
protocol CharacterActor: AnyObject {
    var root: Entity { get }
    /// Altura aproximada (metros) para encuadrar la cámara.
    var height: Float { get }
    func play(_ mood: CompanionMood)
    /// Gira hacia un punto normalizado (-1…1 en x e y); nil vuelve al frente.
    func look(toward point: SIMD2<Float>?)
    /// Detiene tareas en segundo plano (parpadeo) al quitar el personaje.
    func stop()
}

extension Transform {
    func translated(by delta: SIMD3<Float>) -> Transform {
        var t = self
        t.translation += delta
        return t
    }

    /// Rota en grados sobre los ejes locales.
    func rotated(x: Float = 0, y: Float = 0, z: Float = 0) -> Transform {
        var t = self
        let qx = simd_quatf(angle: x * .pi / 180, axis: [1, 0, 0])
        let qy = simd_quatf(angle: y * .pi / 180, axis: [0, 1, 0])
        let qz = simd_quatf(angle: z * .pi / 180, axis: [0, 0, 1])
        t.rotation = t.rotation * qy * qx * qz
        return t
    }
}

/// Pato de prueba hecho con primitivas; sus animaciones se generan por código,
/// así la app funciona sin ningún modelo externo.
@MainActor
final class ProceduralDuck: CharacterActor {
    let root = Entity()
    let height: Float = 1.3

    private let torso = Entity()
    private let head = Entity()
    private let beak = Entity()
    private let leftWing = Entity()
    private let rightWing = Entity()
    private var eyes: [Entity] = []
    private var blinkTask: Task<Void, Never>?

    private static let torsoRest = Transform()
    private static let headRest = Transform(translation: [0, 0.95, 0.2])
    private static let beakRest = Transform(rotation: simd_quatf(angle: .pi / 2, axis: [1, 0, 0]), translation: [0, -0.04, 0.3])
    private static let leftWingRest = Transform(translation: [-0.36, 0.55, 0])
    private static let rightWingRest = Transform(translation: [0.36, 0.55, 0])

    init() {
        func material(_ color: NSColor, roughness: Float = 0.7) -> SimpleMaterial {
            var m = SimpleMaterial(color: color, isMetallic: false)
            m.roughness = .float(roughness)
            return m
        }
        let yellow = material(NSColor(red: 1.0, green: 0.80, blue: 0.18, alpha: 1))
        let orange = material(NSColor(red: 1.0, green: 0.52, blue: 0.12, alpha: 1), roughness: 0.5)
        let white = material(.white, roughness: 0.3)
        let black = material(NSColor(white: 0.08, alpha: 1), roughness: 0.2)

        let body = ModelEntity(mesh: .generateSphere(radius: 0.42), materials: [yellow])
        body.position = [0, 0.45, 0]
        body.scale = [1, 0.85, 1.15]
        let tail = ModelEntity(mesh: .generateSphere(radius: 0.14), materials: [yellow])
        tail.position = [0, 0.55, -0.45]
        tail.scale = [0.7, 0.5, 1]

        let headMesh = ModelEntity(mesh: .generateSphere(radius: 0.3), materials: [yellow])
        let beakMesh = ModelEntity(mesh: .generateCone(height: 0.28, radius: 0.12), materials: [orange])
        beakMesh.position = [0, 0.08, 0]
        beak.addChild(beakMesh)
        beak.transform = Self.beakRest

        var eyes: [Entity] = []
        for side: Float in [-1, 1] {
            let eye = Entity()
            eye.position = [side * 0.12, 0.09, 0.24]
            let sclera = ModelEntity(mesh: .generateSphere(radius: 0.075), materials: [white])
            let pupil = ModelEntity(mesh: .generateSphere(radius: 0.038), materials: [black])
            pupil.position = [0, 0, 0.055]
            eye.addChild(sclera)
            eye.addChild(pupil)
            eyes.append(eye)
        }
        self.eyes = eyes

        head.transform = Self.headRest
        head.addChild(headMesh)
        head.addChild(beak)
        for eye in eyes { head.addChild(eye) }

        for (wing, side) in [(leftWing, Float(-1)), (rightWing, Float(1))] {
            let mesh = ModelEntity(mesh: .generateSphere(radius: 0.2), materials: [yellow])
            mesh.scale = [0.35, 0.65, 1.0]
            mesh.position = [side * 0.12, -0.08, 0]
            wing.addChild(mesh)
            wing.transform = side < 0 ? Self.leftWingRest : Self.rightWingRest
        }
        for side: Float in [-1, 1] {
            let foot = ModelEntity(mesh: .generateBox(size: [0.2, 0.05, 0.28], cornerRadius: 0.02), materials: [orange])
            foot.position = [side * 0.16, 0.025, 0.1]
            root.addChild(foot)
        }
        torso.addChild(body)
        torso.addChild(tail)
        torso.addChild(head)
        torso.addChild(leftWing)
        torso.addChild(rightWing)
        root.addChild(torso)
    }

    func play(_ mood: CompanionMood) {
        stopAll()
        let hr = Self.headRest, tr = Self.torsoRest, lw = Self.leftWingRest, rw = Self.rightWingRest, br = Self.beakRest
        switch mood {
        case .idle:
            loop(torso, from: tr, to: tr.translated(by: [0, 0.025, 0]), duration: 1.4)
            switch Int.random(in: 0 ..< 3) {
            case 0: loop(head, from: hr.rotated(z: -4), to: hr.rotated(z: 4), duration: 2.4)
            case 1: loop(head, from: hr.rotated(y: -22), to: hr.rotated(y: 22), duration: 3.4)
            default: loop(head, from: hr, to: hr.translated(by: [0, 0.02, 0]), duration: 1.4)
            }
            blinking(true)
        case .listening:
            let tilt = hr.rotated(y: 12, z: 18)
            loop(head, from: tilt, to: tilt.rotated(z: 5), duration: 1.6)
            loop(torso, from: tr, to: tr.translated(by: [0, 0.015, 0]), duration: 0.9)
            blinking(true)
        case .thinking:
            loop(head, from: hr.rotated(x: -10, y: -28), to: hr.rotated(x: -10, y: 28), duration: 2.6)
            loop(torso, from: tr, to: tr.translated(by: [0, 0.012, 0]), duration: 2.0)
            blinking(true)
        case .talking:
            loop(beak, from: br, to: br.rotated(x: -22), duration: 0.17, timing: .linear)
            loop(head, from: hr, to: hr.translated(by: [0, 0.02, 0]).rotated(z: 3), duration: 0.5)
            blinking(true)
        case .happy:
            loop(torso, from: tr, to: tr.translated(by: [0, 0.3, 0]), duration: 0.32, timing: .easeOut)
            loop(leftWing, from: lw, to: lw.rotated(z: -55), duration: 0.2)
            loop(rightWing, from: rw, to: rw.rotated(z: 55), duration: 0.2)
            loop(beak, from: br, to: br.rotated(x: -15), duration: 0.32)
            blinking(true)
        case .sad:
            move(head, to: hr.rotated(x: 26).translated(by: [0, -0.07, 0]))
            move(leftWing, to: lw.rotated(z: 20))
            move(rightWing, to: rw.rotated(z: -20))
            loop(torso, from: tr, to: tr.translated(by: [0, 0.01, 0]), duration: 2.8)
            blinking(true)
        case .alert:
            loop(rightWing, from: rw.rotated(z: 95), to: rw.rotated(z: 150), duration: 0.22, timing: .linear)
            let up = hr.translated(by: [0, 0.03, 0])
            loop(head, from: up, to: up.rotated(z: -7), duration: 0.7)
            blinking(true)
        case .sleeping:
            move(head, to: hr.rotated(x: 22).translated(by: [0, -0.05, 0]), duration: 1.0)
            loop(torso, from: tr, to: tr.translated(by: [0, 0.012, 0]), duration: 2.8)
            setEyes(closed: true)
        }
    }

    func look(toward point: SIMD2<Float>?) {
        var target = Transform()
        if let p = point {
            target.rotation = simd_quatf(angle: p.x * 0.35, axis: [0, 1, 0]) * simd_quatf(angle: -p.y * 0.15, axis: [1, 0, 0])
        }
        root.move(to: target, relativeTo: root.parent, duration: 0.25, timingFunction: .easeOut)
    }

    func stop() { blinking(false) }

    // MARK: Animaciones

    private func loop(_ entity: Entity, from: Transform, to: Transform, duration: TimeInterval,
                      timing: AnimationTimingFunction = .easeInOut) {
        let definition = FromToByAnimation<Transform>(from: from, to: to, duration: duration, timing: timing,
                                                      bindTarget: .transform, repeatMode: .autoReverse)
        guard let resource = try? AnimationResource.generate(with: definition) else { return }
        entity.playAnimation(resource.repeat())
    }

    private func move(_ entity: Entity, to target: Transform, duration: TimeInterval = 0.8) {
        entity.move(to: target, relativeTo: entity.parent, duration: duration, timingFunction: .easeInOut)
    }

    private func stopAll() {
        blinking(false)
        for (entity, rest) in [(torso, Self.torsoRest), (head, Self.headRest), (beak, Self.beakRest),
                               (leftWing, Self.leftWingRest), (rightWing, Self.rightWingRest)] {
            entity.stopAllAnimations()
            entity.transform = rest
        }
        setEyes(closed: false)
    }

    private func setEyes(closed: Bool) {
        for eye in eyes {
            eye.stopAllAnimations()
            eye.scale = closed ? [1, 0.12, 1] : [1, 1, 1]
        }
    }

    private func blinking(_ on: Bool) {
        blinkTask?.cancel()
        blinkTask = nil
        guard on else { return }
        blinkTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Double.random(in: 2.5 ... 5.5)))
                guard !Task.isCancelled, let self else { return }
                self.blink()
            }
        }
    }

    private func blink() {
        for eye in eyes {
            let open = eye.transform
            var closed = open
            closed.scale.y = 0.12
            let close = FromToByAnimation<Transform>(from: open, to: closed, duration: 0.07, timing: .easeIn, bindTarget: .transform)
            let reopen = FromToByAnimation<Transform>(from: closed, to: open, duration: 0.09, timing: .easeOut, bindTarget: .transform)
            guard let a = try? AnimationResource.generate(with: close),
                  let b = try? AnimationResource.generate(with: reopen),
                  let sequence = try? AnimationResource.sequence(with: [a, b]) else { continue }
            eye.playAnimation(sequence)
        }
    }
}
