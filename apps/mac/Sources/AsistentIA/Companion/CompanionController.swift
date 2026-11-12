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

    init(store: AppStore, recorder: RecordingService) {
        self.store = store
        self.recorder = recorder
        model = CompanionModel()
        UserDefaults.standard.register(defaults: [Self.followsCursorKey: true, Self.birthdaysKey: true])
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
        let hosting = NSHostingView(rootView: CompanionRootView(controller: self))
        hosting.sizingOptions = []
        panel.contentView = hosting
        self.panel = panel
        character = CharacterLibrary.selected()
        characterOrigin = savedOrigin() ?? CompanionGeometry.defaultOrigin(in: mainScreen())
        applyLayout(persist: true)
        updateVisibility()
        observeApp()
        startTicking()
        // ASISTENT_COMPANION_DEMO=1 muestra un globo de ejemplo al arrancar (para probar el diseño).
        if ProcessInfo.processInfo.environment["ASISTENT_COMPANION_DEMO"] != nil {
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
        let selected = CharacterLibrary.selected()
        if selected != character { character = selected }
        updateVisibility()
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
            characterOrigin = CompanionGeometry.clamp(CGRect(origin: characterOrigin, size: CompanionGeometry.characterSize), to: screen).origin
            UserDefaults.standard.set(NSStringFromPoint(characterOrigin), forKey: Self.originKey)
        }
        let new = CompanionGeometry.layout(characterOrigin: characterOrigin, contentSize: contentSize, screen: screen)
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
        characterOrigin = CompanionGeometry.clamp(CGRect(origin: moved, size: CompanionGeometry.characterSize), to: screen).origin
        model.wake()
        applyLayout(persist: false)
    }

    func endDrag() {
        applyLayout(persist: true)
    }

    func hover(_ point: SIMD2<Float>?) {
        if point != lookPoint { lookPoint = point }
        if point != nil { model.wake() }
    }

    // MARK: Menú, ventanas y chat

    func showMenu(at point: NSPoint, in view: NSView) {
        model.wake()
        var actions = AssistantActions.items(store: store, recorder: recorder, ask: { [weak self] in self?.openChat() })
        let hide = [
            AssistantAction(id: "hide-1h", title: "Ocultar el personaje 1 hora", separatorBefore: true) { [weak self] in
                self?.hide(for: Self.hideInterval)
            },
            AssistantAction(id: "hide", title: "Ocultar hasta reiniciar") { [weak self] in self?.hide(for: nil) },
        ]
        if let index = actions.firstIndex(where: { $0.id == "settings" }) {
            actions.insert(contentsOf: hide, at: index)
        } else {
            actions += hide
        }
        NSMenu.assistant(actions).popUp(positioning: nil, at: point, in: view)
    }

    func openMainWindow() {
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
