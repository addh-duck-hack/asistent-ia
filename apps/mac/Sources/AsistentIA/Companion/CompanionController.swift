import AppKit
import Observation
import SwiftUI

/// Dueño del personaje: crea el panel, observa la app para que el personaje reaccione,
/// guarda su posición y resuelve el menú, el chat y los avisos de análisis y cumpleaños.
@MainActor
@Observable
final class CompanionController {
    enum Presence: String, CaseIterable, Identifiable {
        case character, menuBar, both

        var id: String { rawValue }
        var label: String {
            switch self {
            case .character: "Personaje en el escritorio"
            case .menuBar: "Icono en la barra superior"
            case .both: "Los dos"
            }
        }
        var showsCharacter: Bool { self != .menuBar }
        var showsMenuBar: Bool { self != .character }

        static var current: Presence {
            Presence(rawValue: UserDefaults.standard.string(forKey: presenceKey) ?? "") ?? .character
        }
    }

    nonisolated static let presenceKey = "companionPresence"
    nonisolated static let originKey = "companionOrigin"
    nonisolated static let scaleKey = "companionScale"
    nonisolated static let followsCursorKey = "companionFollowsCursor"
    nonisolated static let birthdaysKey = "companionBirthdays"
    nonisolated static let lastBirthdayNoticeKey = "companionLastBirthdayNotice"
    nonisolated static let hideInterval: TimeInterval = 3600
    nonisolated static let analysisTimeout: TimeInterval = 15 * 60

    private(set) static var shared: CompanionController?

    let model: CompanionModel
    let store: AppStore
    let recorder: RecordingService
    private(set) var character: InstalledCharacter = .duck
    private(set) var layout = CompanionGeometry.Layout(frame: CGRect(origin: .zero, size: CompanionGeometry.characterSize), bubbleOnLeft: false)
    private(set) var lookPoint: SIMD2<Float>?
    private(set) var isVisible = false
    private(set) var menuOpen = false
    /// Escala del personaje (Ajustes → Personaje → Tamaño, el menú o pellizcar con el trackpad).
    private(set) var scale: Double = 1
    var characterSize: CGSize { CompanionGeometry.characterSize(scale: scale) }

    @ObservationIgnored private var contentSize = CompanionGeometry.characterSize
    @ObservationIgnored private var characterOrigin: CGPoint = .zero
    @ObservationIgnored private var panel: CompanionPanel?
    @ObservationIgnored private var hiddenUntil: Date?
    @ObservationIgnored private var hiddenUntilRelaunch = false
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var lastBirthdayCheck = Date.distantPast
    @ObservationIgnored private let api = APIClient()
    @ObservationIgnored private var menuPanel: CompanionPanel?
    @ObservationIgnored private var menuMonitors: [Any] = []
    @ObservationIgnored private var suppressNextClick = false

    init(store: AppStore, recorder: RecordingService) {
        self.store = store
        self.recorder = recorder
        model = CompanionModel()
        UserDefaults.standard.register(defaults: [Self.followsCursorKey: true, Self.birthdaysKey: true, Self.scaleKey: 1.0])
        model.onRestartMic = { [weak self] in self?.recorder.restartMic() }
        model.onRecover = { WindowRouter.shared.open("recorder") }
        Self.shared = self
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.start() }
        })
    }

    /// Crea el panel (una sola vez) y empieza a observar la app.
    func start() {
        guard panel == nil else { return }
        let panel = CompanionPanel()
        let hosting = FirstMouseHostingView(rootView: CompanionRootView(controller: self))
        hosting.sizingOptions = []
        panel.contentView = hosting
        self.panel = panel
        character = CharacterLibrary.selected()
        scale = CompanionGeometry.clampScale(UserDefaults.standard.double(forKey: Self.scaleKey))
        characterOrigin = savedOrigin() ?? CompanionGeometry.defaultOrigin(in: mainScreen(), character: characterSize)
        applyLayout(persist: true)
        updateVisibility()
        observeApp()
        startTicking()
        // ASISTENT_COMPANION_DEMO=1 muestra un globo de ejemplo al arrancar (para probar el diseño).
        // ASISTENT_COMPANION_DEMO=menu abre el menú al arrancar.
        if ProcessInfo.processInfo.environment["ASISTENT_COMPANION_DEMO"] == "menu" {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                if let self, let view = self.panel?.contentView { self.showMenu(at: .zero, in: view) }
            }
        } else if ProcessInfo.processInfo.environment["ASISTENT_COMPANION_DEMO"] != nil {
            model.say("¡Hola! Soy tu asistente. Haz clic en mí para grabar, preguntar o ajustar.", mood: .happy,
                      action: .init(title: "Preguntar") { [weak self] in self?.openChat() }, dismissAfter: nil)
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applyLayout(persist: true) }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.settingsChanged() }
        })
    }

    private func settingsChanged() {
        // Releer la biblioteca solo si cambió el personaje elegido (el pellizco escribe aquí muchas veces por segundo).
        let selectedId = UserDefaults.standard.string(forKey: CharacterLibrary.selectedKey) ?? CharacterPack.builtInId
        if selectedId != character.id { character = CharacterLibrary.selected() }
        let newScale = CompanionGeometry.clampScale(UserDefaults.standard.double(forKey: Self.scaleKey))
        if newScale != scale {
            scale = newScale
            applyLayout(persist: true)
            positionMenu()
        }
        updateVisibility()
    }

    func setScale(_ value: Double) {
        UserDefaults.standard.set(CompanionGeometry.clampScale(value), forKey: Self.scaleKey)
    }

    func magnify(by amount: CGFloat) {
        setScale(scale * (1 + Double(amount)))
    }

    // MARK: Visibilidad

    var presence: Presence { Presence.current }

    private func updateVisibility() {
        let hiddenForNow = hiddenUntil.map { $0 > .now } ?? false
        let visible = presence.showsCharacter && !hiddenUntilRelaunch && !hiddenForNow
        if visible != isVisible { isVisible = visible }
        guard let panel else { return }
        if visible {
            if !panel.isVisible { panel.orderFrontRegardless() }
        } else if panel.isVisible {
            model.chatOpen = false
            closeMenu()
            panel.orderOut(nil)
        }
    }

    func hide(for interval: TimeInterval?) {
        if let interval {
            hiddenUntil = Date.now.addingTimeInterval(interval)
        } else {
            hiddenUntilRelaunch = true
        }
        updateVisibility()
    }

    func show() {
        hiddenUntil = nil
        hiddenUntilRelaunch = false
        if !presence.showsCharacter {
            UserDefaults.standard.set(Presence.both.rawValue, forKey: Self.presenceKey)
        }
        updateVisibility()
    }

    // MARK: Posición

    private func mainScreen() -> CGRect {
        (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }

    private func screen(for point: CGPoint) -> CGRect {
        NSScreen.screens.first { $0.frame.contains(point) }?.visibleFrame ?? mainScreen()
    }

    private func savedOrigin() -> CGPoint? {
        UserDefaults.standard.string(forKey: Self.originKey).map { NSPointFromString($0) }
    }

    private func applyLayout(persist: Bool) {
        let screen = screen(for: CGPoint(x: characterOrigin.x + 10, y: characterOrigin.y + 10))
        if persist {
            characterOrigin = CompanionGeometry.clamp(CGRect(origin: characterOrigin, size: characterSize), to: screen).origin
            UserDefaults.standard.set(NSStringFromPoint(characterOrigin), forKey: Self.originKey)
        }
        let new = CompanionGeometry.layout(characterOrigin: characterOrigin, contentSize: contentSize, screen: screen,
                                           character: characterSize)
        if new != layout { layout = new }
        panel?.setFrame(new.frame, display: true)
    }

    /// La vista reporta su tamaño ideal (personaje solo, o con globo) y el panel se ajusta.
    func reportContentSize(_ size: CGSize) {
        guard size != contentSize, size.width > 0, size.height > 0 else { return }
        contentSize = size
        applyLayout(persist: false)
    }

    func drag(by delta: CGVector) {
        let moved = CGPoint(x: characterOrigin.x + delta.dx, y: characterOrigin.y + delta.dy)
        let screen = screen(for: NSEvent.mouseLocation)
        characterOrigin = CompanionGeometry.clamp(CGRect(origin: moved, size: characterSize), to: screen).origin
        closeMenu()
        model.wake()
        applyLayout(persist: false)
    }

    func endDrag() {
        suppressNextClick = false
        applyLayout(persist: true)
    }

    func hover(_ point: SIMD2<Float>?) {
        if point != lookPoint { lookPoint = point }
        if point != nil { model.wake() }
    }

    // MARK: Menú, ventanas y chat

    /// Clic en el personaje: abre (o cierra) el menú propio a su lado.
    func showMenu(at point: NSPoint, in view: NSView) {
        if suppressNextClick {
            suppressNextClick = false
            return
        }
        if menuOpen {
            closeMenu()
            return
        }
        model.wake()
        let menu = CompanionPanel(identifier: "companion-menu")
        menu.level = .floating
        // El fondo de material deja píxeles transparentes y macOS dejaría pasar los clics
        // a la app de atrás; ponerlo explícitamente en false hace que el menú reciba todos.
        menu.ignoresMouseEvents = false
        let hosting = FirstMouseHostingView(rootView: CompanionMenuView(controller: self, actions: menuActions()))
        hosting.sizingOptions = []
        menu.contentView = hosting
        menuPanel = menu
        menuOpen = true
        positionMenu()
        menu.orderFrontRegardless()
        menu.makeKey()
        installMenuMonitors()
    }

    /// Las acciones de la barra, más ocultar el personaje (antes de Ajustes y Salir).
    func menuActions() -> [AssistantAction] {
        var actions = AssistantActions.items(store: store, recorder: recorder, ask: { [weak self] in self?.openChat() })
        let hide = [
            AssistantAction(id: "hide-1h", title: "Ocultar 1 hora", systemImage: "clock", separatorBefore: true) { [weak self] in
                self?.hide(for: Self.hideInterval)
            },
            AssistantAction(id: "hide", title: "Ocultar hasta reiniciar", systemImage: "eye.slash") { [weak self] in
                self?.hide(for: nil)
            },
        ]
        if let index = actions.firstIndex(where: { $0.id == "settings" }) {
            actions.insert(contentsOf: hide, at: index)
        } else {
            actions += hide
        }
        return actions
    }

    func perform(_ action: AssistantAction) {
        closeMenu()
        action.perform()
    }

    private func positionMenu() {
        guard let menu = menuPanel, let content = menu.contentView as? FirstMouseHostingView<CompanionMenuView> else { return }
        // fittingSize sale chico antes del primer dibujo; se mide el SwiftUI directamente.
        let ideal = NSHostingController(rootView: content.rootView).sizeThatFits(in: CGSize(width: 10_000, height: 10_000))
        let character = CGRect(origin: CompanionGeometry.characterOrigin(in: layout), size: characterSize)
        let screen = screen(for: CGPoint(x: character.midX, y: character.midY))
        let frame = CompanionGeometry.menuFrame(size: ideal, beside: character, screen: screen)
        menu.setFrame(frame, display: true)
    }

    func closeMenu() {
        for monitor in menuMonitors { NSEvent.removeMonitor(monitor) }
        menuMonitors = []
        menuPanel?.orderOut(nil)
        menuPanel = nil
        if menuOpen { menuOpen = false }
    }

    /// Cierra el menú con Esc o con un clic fuera de él (en otra app o en el personaje).
    private func installMenuMonitors() {
        // Con la app inactiva, macOS también pasa por aquí los clics en nuestros propios paneles
        // (no activan la app): solo se cierra si el clic cae fuera del menú y del personaje.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            let location = NSEvent.mouseLocation
            Task { @MainActor in self?.handleGlobalClick(at: location) }
        }) {
            menuMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown], handler: { [weak self] event in
            // NSEvent no es Sendable: se pasan solo los datos que importan.
            let isKey = event.type == .keyDown
            // keyCode solo existe en eventos de teclado: en un clic lanza una excepción y AppKit descarta el evento.
            let keyCode: UInt16 = isKey ? event.keyCode : 0
            let windowNumber = event.window?.windowNumber
            let consume = MainActor.assumeIsolated {
                self?.handleMenuEvent(isKey: isKey, keyCode: keyCode, windowNumber: windowNumber) ?? false
            }
            return consume ? nil : event
        }) {
            menuMonitors.append(local)
        }
    }

    private func handleGlobalClick(at location: CGPoint) {
        guard menuOpen else { return }
        if menuPanel?.frame.contains(location) == true { return }
        if panel?.frame.contains(location) == true {
            // Lo resuelve el personaje: su clic cierra el menú (toggle en showMenu).
            return
        }
        closeMenu()
    }

    /// Devuelve true si el evento se consume (Esc).
    private func handleMenuEvent(isKey: Bool, keyCode: UInt16, windowNumber: Int?) -> Bool {
        guard menuOpen else { return false }
        if isKey {
            guard keyCode == 53 else { return false } // Esc
            closeMenu()
            return true
        }
        if let windowNumber, windowNumber == menuPanel?.windowNumber { return false }
        // El clic en el personaje solo cierra el menú (no lo vuelve a abrir).
        if let windowNumber, windowNumber == panel?.windowNumber { suppressNextClick = true }
        closeMenu()
        return false
    }

    func openMainWindow() {
        suppressNextClick = false
        closeMenu()
        WindowRouter.shared.open("main")
    }

    func openChat() {
        model.wake()
        model.chatOpen = true
        panel?.makeKeyAndOrderFront(nil)
    }

    func closeChat() {
        model.chatOpen = false
    }

    /// Muestra la conversación del personaje en "Preguntar" de la ventana principal.
    func openConversationInApp(_ id: String) {
        store.selectedConversationId = id
        store.conversation = nil
        store.sidebar = .ask
        Task {
            await store.loadConversations()
            await store.loadConversation()
        }
        openMainWindow()
    }

    func showSession(id: String, projectId: String?) {
        Task { await store.show(sessionId: id, projectId: projectId) }
        openMainWindow()
    }

    // MARK: Observación de la app

    private struct Inputs {
        var phase: RecordingService.Phase
        var title: String?
        var micProblem: String?
        var hasInterrupted: Bool
        var notice: AppStore.Notice?
        var error: String?
        var peopleCount: Int
    }

    /// Lee lo que importa con `withObservationTracking` y se vuelve a armar en cada cambio
    /// (sigue vivo aunque el panel esté oculto, a diferencia de `.onChange` en la vista).
    private func observeApp() {
        let inputs = withObservationTracking {
            Inputs(phase: recorder.phase, title: recorder.meta?.title, micProblem: recorder.micProblem,
                   hasInterrupted: !recorder.interrupted.isEmpty, notice: store.notice, error: store.errorMessage,
                   peopleCount: store.people.count)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeApp() }
        }
        model.apply(phase: inputs.phase, title: inputs.title, micProblem: inputs.micProblem,
                    hasInterrupted: inputs.hasInterrupted, notice: inputs.notice, error: inputs.error)
        if let sessionId = model.takePendingFinished() { watchAnalysis(sessionId: sessionId) }
        if inputs.peopleCount > 0 { checkBirthdays(force: true) }
    }

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.model.tick()
                if let until = self.hiddenUntil, until <= .now {
                    self.hiddenUntil = nil
                    self.updateVisibility()
                }
                self.checkBirthdays()
            }
        }
    }

    /// Tras subir una grabación, vigila la sesión hasta que el análisis termine.
    private func watchAnalysis(sessionId: String) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            let deadline = Date.now.addingTimeInterval(Self.analysisTimeout)
            while !Task.isCancelled, Date.now < deadline {
                try? await Task.sleep(for: .seconds(5))
                guard let self, let detail = try? await self.api.session(id: sessionId) else { continue }
                let session = detail.session
                if session.status.isInProgress { continue }
                if session.status == .done {
                    let see = CompanionModel.Action(title: "Ver") { [weak self] in
                        self?.showSession(id: session.id, projectId: session.projectId)
                    }
                    self.model.say("El análisis de «\(session.title)» está listo.", mood: .happy, action: see, dismissAfter: 90)
                } else {
                    self.model.say("El análisis de «\(session.title)» falló\(session.error.map { ": \($0)" } ?? ".")",
                                   kind: .error, mood: .sad, dismissAfter: 30)
                }
                return
            }
        }
    }

    /// Avisa cumpleaños y aniversarios próximos, una vez al día.
    private func checkBirthdays(force: Bool = false) {
        guard UserDefaults.standard.bool(forKey: Self.birthdaysKey), !store.people.isEmpty else { return }
        let now = Date.now
        guard force || now.timeIntervalSince(lastBirthdayCheck) > 3600 else { return }
        lastBirthdayCheck = now
        let today = now.formatted(.iso8601.year().month().day())
        guard UserDefaults.standard.string(forKey: Self.lastBirthdayNoticeKey) != today,
              let text = CompanionModel.upcomingText(people: store.people, now: now) else { return }
        UserDefaults.standard.set(today, forKey: Self.lastBirthdayNoticeKey)
        model.say(text, mood: .talking, dismissAfter: 30)
    }
}
