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
    nonisolated static let clickActionKey = "companionClickAction"
    /// Minutos sin actividad para que el personaje se duerma; 0 = nunca.
    nonisolated static let sleepMinutesKey = "companionSleepMinutes"
    nonisolated static let sleepMinuteOptions = [1, 2, 5, 10, 15, 30, 60, 0]

    /// "Después de 10 minutos sin actividad." o "Nunca se duerme."
    nonisolated static func sleepDescription(minutes: Int) -> String {
        switch minutes {
        case ..<1: "Nunca se duerme."
        case 1: "Después de 1 minuto sin actividad."
        default: "Después de \(minutes) minutos sin actividad."
        }
    }

    nonisolated static func sleepLabel(minutes: Int) -> String {
        switch minutes {
        case ..<1: "Nunca"
        case 1: "1 minuto"
        case 60: "1 hora"
        default: "\(minutes) minutos"
        }
    }

    nonisolated static var sleepMinutes: Int { UserDefaults.standard.integer(forKey: sleepMinutesKey) }

    // Recordatorios de pendientes (Ajustes → Personaje → Recordatorios).
    nonisolated static let remindersKey = "companionReminders"
    nonisolated static let reminderMinutesKey = "companionReminderMinutes"
    nonisolated static let reminderWorkHoursKey = "companionReminderWorkHours"
    /// Recordatorios ya dichos hoy: primera línea la fecha, luego una clave por línea.
    nonisolated static let remindersShownKey = "companionRemindersShown"
    nonisolated static let reminderMinuteOptions = [30, 60, 120, 180]
    /// Sin tocar teclado ni ratón este tiempo, se da por hecho que no hay nadie y no se recuerda nada.
    nonisolated static let awayAfter: TimeInterval = 5 * 60

    nonisolated static func reminderLabel(minutes: Int) -> String {
        switch minutes {
        case 60: "Cada hora, más o menos"
        case let m where m % 60 == 0: "Cada \(m / 60) horas, más o menos"
        default: "Cada \(minutes) minutos, más o menos"
        }
    }

    nonisolated static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Claves de los recordatorios dichos hoy (se olvidan al cambiar el día).
    nonisolated static func shownReminders(now: Date = .now) -> Set<String> {
        let lines = (UserDefaults.standard.string(forKey: remindersShownKey) ?? "").split(separator: "\n").map(String.init)
        guard lines.first == dayKey(now) else { return [] }
        return Set(lines.dropFirst())
    }

    nonisolated static func markReminderShown(_ key: String, now: Date = .now) {
        let keys = shownReminders(now: now).union([key]).sorted()
        UserDefaults.standard.set(([dayKey(now)] + keys).joined(separator: "\n"), forKey: remindersShownKey)
    }

    /// Segundos desde la última tecla, clic, movimiento o desplazamiento en la Mac.
    nonisolated static func secondsSinceUserInput() -> TimeInterval {
        let types: [CGEventType] = [.keyDown, .mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel]
        return types.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? 0
    }
    nonisolated static let hideInterval: TimeInterval = 3600
    nonisolated static let analysisTimeout: TimeInterval = 15 * 60

    /// Qué hace un clic normal en el personaje (el clic derecho siempre abre el menú).
    enum ClickAction: String, CaseIterable, Identifiable {
        case menu, react

        var id: String { rawValue }
        var label: String {
            switch self {
            case .menu: "Reacciona y abre el menú"
            case .react: "Solo reacciona (menú con clic derecho o ⌃clic)"
            }
        }

        static var current: ClickAction {
            ClickAction(rawValue: UserDefaults.standard.string(forKey: clickActionKey) ?? "") ?? .menu
        }
    }

    private(set) static var shared: CompanionController?

    let model: CompanionModel
    let store: AppStore
    let recorder: RecordingService
    private(set) var character: InstalledCharacter = .duck {
        didSet {
            model.pack = character.pack
            guard character.pack.frameAspect != oldValue.pack.frameAspect, panel != nil else { return }
            let old = CompanionGeometry.characterSize(scale: scale, aspect: oldValue.pack.frameAspect)
            characterOrigin = CompanionGeometry.recentered(origin: characterOrigin, from: old, to: characterSize)
            applyLayout(persist: true)
            positionMenu()
        }
    }
    /// Sube cuando se reemplazan archivos del personaje en disco: la escena lo vuelve a cargar.
    private(set) var characterRevision = 0
    /// Muestra sobre el personaje las zonas de cabeza, cuerpo y pies (mientras se ajustan).
    var showsZones = false
    private(set) var layout = CompanionGeometry.Layout(frame: CGRect(origin: .zero, size: CompanionGeometry.characterSize), bubbleOnLeft: false)
    private(set) var lookPoint: SIMD2<Float>?
    private(set) var isVisible = false
    /// El usuario lo ocultó (1 hora o hasta reiniciar): mientras tanto se muestra el icono de la barra
    /// para poder traerlo de vuelta. `hiddenUntil` es nil si es hasta reiniciar.
    private(set) var isHiddenByUser = false
    private(set) var hiddenUntilDate: Date?
    private(set) var menuOpen = false
    /// Escala del personaje (Ajustes → Personaje → Tamaño, el menú o pellizcar con el trackpad).
    private(set) var scale: Double = 1
    var characterSize: CGSize { CompanionGeometry.characterSize(scale: scale, aspect: character.pack.frameAspect) }

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
    @ObservationIgnored private var lastPhase: RecordingService.Phase = .idle
    @ObservationIgnored private var dragging = false

    init(store: AppStore, recorder: RecordingService) {
        self.store = store
        self.recorder = recorder
        model = CompanionModel()
        UserDefaults.standard.register(defaults: [Self.followsCursorKey: true, Self.birthdaysKey: true, Self.scaleKey: 1.0, Self.sleepMinutesKey: 10,
                                                  Self.remindersKey: true, Self.reminderMinutesKey: 60, Self.reminderWorkHoursKey: true])
        model.onReminderDue = { [weak self] in self?.reminderDue() }
        model.onRestartMic = { [weak self] in self?.recorder.restartMic() }
        model.onRecover = { WindowRouter.shared.open("recorder") }
        model.onShowRecorder = { WindowRouter.shared.open("recorder") }
        model.onStopRecording = { [weak self] in
            guard let self else { return }
            Task { await self.recorder.stopAndProcess() }
        }
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
        applySleepSetting()
        applyReminderSetting()
        characterOrigin = savedOrigin() ?? CompanionGeometry.defaultOrigin(in: mainScreen(), character: characterSize)
        applyLayout(persist: true)
        updateVisibility()
        observeApp()
        startTicking()
        // ASISTENT_COMPANION_DEMO=1 muestra un globo de ejemplo al arrancar (para probar el diseño).
        // ASISTENT_COMPANION_DEMO=menu abre el menú al arrancar.
        // ASISTENT_COMPANION_DEMO=animations abre la pantalla de animaciones al arrancar.
        // ASISTENT_COMPANION_DEMO=chat abre el globo de Preguntar al arrancar.
        // ASISTENT_COMPANION_DEMO=reminder dice un recordatorio de pendientes al arrancar.
        if ProcessInfo.processInfo.environment["ASISTENT_COMPANION_DEMO"] == "menu" {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                if let self, let view = self.panel?.contentView { self.showMenu(at: .zero, in: view) }
            }
        } else if ProcessInfo.processInfo.environment["ASISTENT_COMPANION_DEMO"] == "animations" {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                WindowRouter.shared.open("animations")
            }
        } else if ProcessInfo.processInfo.environment["ASISTENT_COMPANION_DEMO"] == "reminder" {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(4))
                await self?.showReminder(test: true)
            }
        } else if ProcessInfo.processInfo.environment["ASISTENT_COMPANION_DEMO"] == "chat" {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                self?.openChat()
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
        applySleepSetting()
        applyReminderSetting()
        let newScale = CompanionGeometry.clampScale(UserDefaults.standard.double(forKey: Self.scaleKey))
        if newScale != scale {
            let oldSize = characterSize
            scale = newScale
            // Con el menú abierto (su control de tamaño), el menú se queda quieto y el personaje
            // crece hacia el lado contrario; si se moviera, el control se escaparía del cursor.
            if let menu = menuPanel {
                characterOrigin = CompanionGeometry.resizedOrigin(origin: characterOrigin, from: oldSize, to: characterSize,
                                                                  menuOnRight: menu.frame.midX > characterOrigin.x + oldSize.width / 2)
            }
            applyLayout(persist: true)
        }
        updateVisibility()
    }

    private func applySleepSetting() {
        let minutes = Self.sleepMinutes
        let after: TimeInterval? = minutes > 0 ? TimeInterval(minutes) * 60 : nil
        guard model.sleepAfter != after else { return }
        model.sleepAfter = after
        model.tick() // "Nunca" lo despierta en el momento; un tiempo menor lo duerme si ya pasó
    }

    private func applyReminderSetting() {
        let minutes = UserDefaults.standard.integer(forKey: Self.reminderMinutesKey)
        let every: TimeInterval? = UserDefaults.standard.bool(forKey: Self.remindersKey) && minutes > 0 ? TimeInterval(minutes) * 60 : nil
        if model.reminderEvery != every { model.reminderEvery = every }
    }

    // MARK: Recordatorios de pendientes

    @ObservationIgnored private var reminderInFlight = false

    /// Toca un recordatorio: solo con el personaje a la vista, en horario (si se pidió) y con alguien en la Mac.
    private func reminderDue() {
        guard isVisible, !reminderInFlight else { return }
        if UserDefaults.standard.bool(forKey: Self.reminderWorkHoursKey), !PendingReminders.isWorkTime(.now) { return }
        guard Self.secondsSinceUserInput() < Self.awayAfter else { return }
        Task { await showReminder() }
    }

    /// Pide los pendientes abiertos y dice uno de los recordatorios que todavía no dijo hoy.
    /// `test` (Ajustes → "Probar ahora"): puede repetir y no cuenta como dicho. Devuelve false si no dijo nada.
    @discardableResult
    func showReminder(test: Bool = false) async -> Bool {
        guard !reminderInFlight else { return false }
        reminderInFlight = true
        defer { reminderInFlight = false }
        if test { show() }
        guard let items = try? await api.actionItems(projectId: nil, statuses: [.open, .inProgress, .blocked]) else {
            if test { model.say("No pude traer los pendientes del servidor.", kind: .error, mood: .sad, dismissAfter: 10) }
            return false
        }
        let candidates = PendingReminders.candidates(items: items, people: store.people)
        guard let reminder = PendingReminders.pick(from: candidates, avoiding: test ? [] : Self.shownReminders()) else { return false }
        // Mientras llegaban los pendientes pudo aparecer otro globo o abrirse el chat.
        guard test || (model.bubbles.isEmpty && !model.chatOpen) else { return false }
        if !test { Self.markReminderShown(reminder.key) }
        let action = reminder.target.map { target in
            CompanionModel.Action(title: reminder.actionTitle ?? "Revisar") { [weak self] in self?.open(target) }
        }
        model.remind(reminder.text, action: action)
        return true
    }

    private func open(_ target: PendingReminder.Target) {
        model.dismissCurrent()
        switch target {
        case let .project(id):
            Task { await store.showItems(projectId: id, itemId: nil) }
        case let .item(id, projectId):
            Task { await store.showItems(projectId: projectId, itemId: id) }
        case let .person(id):
            store.sidebar = .person(id)
            store.personTab = .items
        }
        openMainWindow()
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
        if visible != isVisible {
            isVisible = visible
            recorderWindowFollowsVisibility(visible)
            if visible { model.perform(.greet) }
        }
        let hiddenByUser = presence.showsCharacter && (hiddenUntilRelaunch || hiddenForNow)
        if hiddenByUser != isHiddenByUser { isHiddenByUser = hiddenByUser }
        let until = hiddenForNow ? hiddenUntil : nil
        if until != hiddenUntilDate { hiddenUntilDate = until }
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
        if !dragging {
            dragging = true
            model.perform(.drag)
        }
        applyLayout(persist: false)
    }

    func endDrag() {
        suppressNextClick = false
        dragging = false
        model.endGesture(of: .drag)
        applyLayout(persist: true)
    }

    func hover(_ point: SIMD2<Float>?) {
        if point != lookPoint { lookPoint = point }
        if point != nil { model.wake() }
    }

    // MARK: Clic

    /// Clic en el personaje: reacciona según la zona (cabeza, cuerpo o pies) y, según lo elegido
    /// en la pantalla de animaciones, abre además el menú. Sin animación para esa zona, abre el menú.
    func click(at point: NSPoint, in view: NSView) {
        // Con el menú abierto (o recién cerrado por este mismo clic) el clic solo lo cierra.
        if suppressNextClick || menuOpen {
            showMenu(at: point, in: view)
            return
        }
        model.wake()
        let fraction = view.bounds.height > 0 ? Double(point.y / view.bounds.height) : 0.5
        let zone = CompanionModel.zone(atHeight: fraction, behavior: character.pack.behavior)
        // "Solo reacciona": el clic izquierdo nunca abre el menú mientras el personaje tenga alguna
        // animación de clic; si la zona no tiene, usa la de otra zona. Sin ninguna, abre el menú
        // para que el clic no se quede sin hacer nada.
        let onlyReact = ClickAction.current == .react
        let reacted = model.performClick(on: zone, anyZone: onlyReact)
        if reacted, onlyReact { return }
        showMenu(at: point, in: view)
    }

    // MARK: Animaciones del personaje (pantalla de animaciones)

    /// Cambia el paquete del personaje activo y lo guarda en su `character.json`.
    /// Devuelve false si el personaje no se puede modificar (el pato o uno incluido en la app).
    @discardableResult
    func updatePack(_ change: (inout CharacterPack) -> Void) -> Bool {
        guard character.isEditable, let folder = character.folder else { return false }
        var pack = character.pack
        // El modelo base queda fijo: quitar o reordenar animaciones no debe cambiar el modelo.
        if pack.base == nil { pack.base = pack.baseFile }
        change(&pack)
        guard pack != character.pack else { return true }
        do {
            try CharacterLibrary.save(pack, in: folder)
        } catch {
            model.say("No pude guardar los cambios del personaje: \(error.localizedDescription)", kind: .error, mood: .sad)
            return false
        }
        character = InstalledCharacter(pack: pack, folder: folder)
        return true
    }

    /// Vuelve a leer el personaje de disco y recarga sus archivos (se importaron o reemplazaron animaciones).
    func reloadCharacter() {
        character = CharacterLibrary.selected()
        characterRevision += 1
    }

    /// Reproduce un clip en el personaje para probarlo: una vez, o en bucle unos segundos.
    func preview(_ clip: ClipSource, loopingFor seconds: TimeInterval? = nil) {
        previewTask?.cancel()
        if previewingAll { previewingAll = false }
        if !isVisible { show() }
        model.stopPreview()
        model.play(clip, loopingFor: seconds)
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
            AssistantAction(id: "animations", title: "Animaciones…", systemImage: "figure.dance", separatorBefore: true) {
                WindowRouter.shared.open("animations")
            },
            AssistantAction(id: "hide-1h", title: "Ocultar 1 hora", systemImage: "clock") { [weak self] in
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
        let previous = lastPhase
        lastPhase = inputs.phase
        recorderWindowFollowsPhase(from: previous, to: inputs.phase)
        if inputs.peopleCount > 0 { checkBirthdays(force: true) }
    }

    // MARK: Probar animaciones (Ajustes → Personaje)

    @ObservationIgnored private var previewTask: Task<Void, Never>?
    private(set) var previewingAll = false

    /// Muestra el personaje (si estaba oculto) y lo pone en un estado unos segundos.
    func preview(_ mood: CompanionMood) {
        previewTask?.cancel()
        if previewingAll { previewingAll = false }
        if !isVisible { show() }
        model.preview(mood)
    }

    /// Recorre todos los estados, unos segundos cada uno.
    func previewAll(secondsEach: TimeInterval = 4) {
        previewTask?.cancel()
        if !isVisible { show() }
        previewingAll = true
        previewTask = Task { [weak self] in
            for mood in CompanionMood.allCases {
                guard let self, !Task.isCancelled else { return }
                self.model.preview(mood, for: secondsEach + 1)
                try? await Task.sleep(for: .seconds(secondsEach))
            }
            guard let self, !Task.isCancelled else { return }
            self.model.stopPreview()
            self.previewingAll = false
        }
    }

    func stopPreview() {
        previewTask?.cancel()
        previewingAll = false
        model.stopPreview()
        model.stopGesture()
    }

    // MARK: Ventana de grabación

    /// Con el personaje visible, él muestra la grabación y el procesamiento: la ventana
    /// "Grabar reunión" solo se usa para empezar (o para confirmar cancelar y ver errores).
    private func recorderWindowFollowsPhase(from old: RecordingService.Phase, to new: RecordingService.Phase) {
        guard isVisible else { return }
        switch new {
        case .recording:
            if case .recording = old {} else { closeRecorderWindow() }
        case .finished:
            closeRecorderWindow()
            recorder.reset() // la próxima vez la ventana abre lista para otra grabación
        default:
            break
        }
    }

    /// Al ocultar el personaje a media grabación vuelve la ventana; al mostrarlo, se cierra.
    private func recorderWindowFollowsVisibility(_ visible: Bool) {
        let phase = recorder.phase
        var finished = false
        if case .finished = phase { finished = true }
        var failed = false
        if case .failed = phase { failed = true }
        if visible {
            if phase.isBusy || finished { closeRecorderWindow() }
            if finished { recorder.reset() }
        } else if phase.isBusy || finished || failed {
            WindowRouter.shared.open("recorder")
        }
    }

    private func closeRecorderWindow() {
        NSApp.windows.first { $0.identifier?.rawValue == "recorder" }?.close()
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
