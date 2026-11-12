import AppKit

/// Ventana del personaje: sin bordes, flotante sobre todo, en todos los escritorios,
/// y no activa la app al hacer clic (solo toma el teclado cuando el chat lo pide).
final class CompanionPanel: NSPanel {
    init() {
        super.init(contentRect: CGRect(origin: .zero, size: CompanionGeometry.characterSize),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        isMovableByWindowBackground = false
        animationBehavior = .none
        identifier = NSUserInterfaceItemIdentifier("companion")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Capa invisible sobre el personaje: solo los clics dentro de su silueta son suyos
/// (el resto pasa al escritorio) y gestiona arrastre, clic, doble clic, menú y hover.
final class CompanionInteractionView: NSView {
    var onClick: ((NSPoint) -> Void)?
    var onDoubleClick: (() -> Void)?
    var onDrag: ((CGVector) -> Void)?
    var onDragEnd: (() -> Void)?
    var onHover: ((SIMD2<Float>?) -> Void)?

    private var lastDragLocation: NSPoint?
    private var dragging = false
    private var pendingClick: Task<Void, Never>?

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        return isInsideCharacter(local) ? self : nil
    }

    /// Elipse centrada que cubre al personaje (no las esquinas transparentes).
    func isInsideCharacter(_ point: NSPoint) -> Bool {
        let rx = bounds.width * 0.36, ry = bounds.height * 0.46
        guard rx > 0, ry > 0 else { return false }
        let dx = (point.x - bounds.midX) / rx, dy = (point.y - bounds.midY) / ry
        return dx * dx + dy * dy <= 1
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hover(event) }
    override func mouseMoved(with event: NSEvent) { hover(event) }
    override func mouseExited(with event: NSEvent) { onHover?(nil) }

    private func hover(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard bounds.width > 0, bounds.height > 0 else { return }
        onHover?(SIMD2(Float(p.x / bounds.width * 2 - 1), Float(p.y / bounds.height * 2 - 1)))
    }

    override func mouseDown(with event: NSEvent) {
        lastDragLocation = NSEvent.mouseLocation
        dragging = false
        pendingClick?.cancel()
        pendingClick = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let last = lastDragLocation else { return }
        let now = NSEvent.mouseLocation
        let delta = CGVector(dx: now.x - last.x, dy: now.y - last.y)
        if !dragging, hypot(delta.dx, delta.dy) < 4 { return }
        dragging = true
        lastDragLocation = now
        onDrag?(delta)
    }

    override func mouseUp(with event: NSEvent) {
        lastDragLocation = nil
        if dragging {
            dragging = false
            onDragEnd?()
            return
        }
        if event.clickCount >= 2 {
            pendingClick?.cancel()
            pendingClick = nil
            onDoubleClick?()
            return
        }
        // Espera por si viene un doble clic; si no, es un clic normal.
        let point = convert(event.locationInWindow, from: nil)
        pendingClick = Task { [weak self] in
            try? await Task.sleep(for: .seconds(NSEvent.doubleClickInterval))
            guard !Task.isCancelled, let self else { return }
            self.onClick?(point)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onClick?(convert(event.locationInWindow, from: nil))
    }
}
