import Foundation
import Observation

/// Estado del personaje: ánimo, cola de globos, sueño y chat. Lógica pura, sin AppKit, para poder probarla.
@MainActor
@Observable
final class CompanionModel {
    struct Action: Equatable {
        let title: String
        let perform: @MainActor () -> Void

        static func == (a: Action, b: Action) -> Bool { a.title == b.title }
    }

    struct Bubble: Identifiable, Equatable {
        enum Kind: Equatable { case info, progress, error }

        let id: UUID
        var kind: Kind
        var text: String
        /// Ánimo mientras el globo está a la vista (si no, el que toque por fase).
        var mood: CompanionMood?
        /// Contador en marcha (grabando).
        var elapsedSince: Date?
        var progress: Double?
        var action: Action?
        /// Se cierra solo pasado este tiempo desde que se muestra; nil, hasta que el usuario lo cierre.
        var dismissAfter: TimeInterval?
        var shownAt: Date?

        init(kind: Kind = .info, text: String, mood: CompanionMood? = nil, elapsedSince: Date? = nil, progress: Double? = nil,
             action: Action? = nil, dismissAfter: TimeInterval? = nil) {
            id = UUID()
            self.kind = kind
            self.text = text
            self.mood = mood
            self.elapsedSince = elapsedSince
            self.progress = progress
            self.action = action
            self.dismissAfter = dismissAfter
        }
    }

    /// Un gesto suelto en curso: un clip que se reproduce una vez (o en bucle) encima del estado.
    struct Gesture: Identifiable, Equatable {
        let id: UUID
        let clip: ClipSource
        let loops: Bool
        /// Qué lo provocó; nil si es una prueba desde la pantalla de animaciones.
        let reaction: CompanionReaction?
        /// Se da por terminado a esta hora aunque la escena no avise (personaje oculto, clip que no carga).
        var until: Date?
    }

    /// Tiempo máximo que se espera a que la escena avise que un gesto terminó.
    static let gestureTimeout: TimeInterval = 30

    static let sleepAfter: TimeInterval = 10 * 60
    static let idleChangeRange: ClosedRange<TimeInterval> = 20 ... 60

    private(set) var bubbles: [Bubble] = []
    /// Ánimo que impone la grabación (escuchando, pensando) o idle.
    private(set) var phaseMood: CompanionMood = .idle
    private(set) var asleep = false
    /// Cambia cada 20–60 s sin actividad; la escena lo usa para variar la animación de reposo.
    private(set) var idleVariant = 0
    var chatOpen = false
    let chat: CompanionChat
    /// Personaje activo: de aquí salen sus reacciones y cada cuánto hace gestos al azar.
    var pack: CharacterPack = .builtInDuck {
        didSet {
            if pack.id != oldValue.id || pack.behavior != oldValue.behavior { scheduleRandom() }
        }
    }
    private(set) var gesture: Gesture?

    /// Acciones que requieren cosas que el modelo no tiene (las pone el controlador).
    var onRestartMic: (@MainActor () -> Void)?
    var onRecover: (@MainActor () -> Void)?
    /// Con el personaje visible no se muestra la ventana de grabación: los globos llevan sus acciones.
    var onStopRecording: (@MainActor () -> Void)?
    var onShowRecorder: (@MainActor () -> Void)?

    private let now: () -> Date
    private var lastInteraction: Date
    private var nextIdleChange: Date
    private var lastNoticeId: UUID?
    private var lastErrorMessage: String?
    private var lastFailure: String?
    private var lastMicProblem: String?
    private var announcedInterrupted = false
    private var lastFinishedSession: String?
    private var pendingFinished: String?
    private var nextRandom: Date = .distantFuture
    private var lastGestureClip: [CompanionReaction: ClipSource] = [:]

    init(now: @escaping () -> Date = { .now }, chat: CompanionChat = CompanionChat()) {
        self.now = now
        self.chat = chat
        lastInteraction = now()
        nextIdleChange = now().addingTimeInterval(Self.idleChangeRange.lowerBound)
        scheduleRandom()
    }

    // MARK: Ánimo

    /// Globo a la vista: el primero que no sea de progreso; si no hay, el de progreso.
    var current: Bubble? { bubbles.first { $0.kind != .progress } ?? bubbles.first }

    /// Estado que se está probando desde Ajustes (manda sobre todo lo demás mientras dura).
    private(set) var previewMood: CompanionMood?
    private var previewUntil: Date?

    func preview(_ mood: CompanionMood, for seconds: TimeInterval = 6) {
        wake()
        previewMood = mood
        previewUntil = now().addingTimeInterval(seconds)
    }

    func stopPreview() {
        previewMood = nil
        previewUntil = nil
    }

    var mood: CompanionMood {
        if let previewMood { return previewMood }
        if let mood = current?.mood { return mood }
        if phaseMood != .idle { return phaseMood }
        if chatOpen { return chat.asking ? .thinking : .listening }
        return asleep ? .sleeping : .idle
    }

    /// Cualquier interacción: despierta y reinicia el contador de sueño.
    func wake() {
        lastInteraction = now()
        if asleep {
            asleep = false
            perform(.wake)
        }
    }

    // MARK: Gestos

    /// Hace el gesto de una reacción (uno de sus clips, sin repetir el anterior). Devuelve false si no tiene ninguno.
    @discardableResult
    func perform(_ reaction: CompanionReaction) -> Bool {
        let options = pack.reactions[reaction] ?? []
        guard let clip = Self.pick(from: options, avoiding: lastGestureClip[reaction]) else { return false }
        lastGestureClip[reaction] = clip
        gesture = Gesture(id: UUID(), clip: clip, loops: reaction.loops, reaction: reaction,
                          until: reaction.loops ? nil : now().addingTimeInterval(Self.gestureTimeout))
        return true
    }

    /// Reproduce un clip cualquiera (para probarlo): una vez, o en bucle durante `seconds`.
    func play(_ clip: ClipSource, loopingFor seconds: TimeInterval? = nil) {
        wake()
        gesture = Gesture(id: UUID(), clip: clip, loops: seconds != nil, reaction: nil,
                          until: now().addingTimeInterval(seconds ?? Self.gestureTimeout))
    }

    /// La escena avisa que el gesto terminó (o que un cambio de estado lo interrumpió).
    func endGesture(_ id: UUID) {
        if gesture?.id == id { gesture = nil }
    }

    func endGesture(of reaction: CompanionReaction) {
        if gesture?.reaction == reaction { gesture = nil }
    }

    func stopGesture() {
        gesture = nil
    }

    /// Elige un clip al azar; si hay varios, evita repetir el último.
    static func pick(from options: [ClipSource], avoiding last: ClipSource?) -> ClipSource? {
        guard options.count > 1, let last else { return options.randomElement() }
        return options.filter { $0 != last }.randomElement() ?? options.first
    }

    private func scheduleRandom() {
        nextRandom = now().addingTimeInterval(.random(in: pack.behavior.randomRange))
    }

    /// Zona de un clic según su altura dentro del cuadro del personaje (0 = abajo, 1 = arriba).
    static func zone(atHeight fraction: Double, behavior: CharacterPack.Behavior) -> CompanionReaction {
        if fraction >= 1 - behavior.headZone { return .head }
        if fraction <= behavior.feetZone { return .feet }
        return .body
    }

    // MARK: Entradas de la app

    /// Deriva ánimo y globos de lo que pasa en la app. Se puede llamar cuantas veces sea; no repite avisos.
    func apply(phase: RecordingService.Phase, title: String? = nil, micProblem: String? = nil,
               hasInterrupted: Bool = false, notice: AppStore.Notice? = nil, error: String? = nil) {
        let subject = title.map { "«\($0)»" } ?? "la reunión"
        switch phase {
        case .idle:
            phaseMood = .idle
            removeProgress()
        case let .recording(since):
            phaseMood = .listening
            setProgress("Grabando \(subject)", elapsedSince: since,
                        action: onStopRecording.map { Action(title: "Detener y analizar", perform: $0) })
        case let .preparingModel(progress):
            phaseMood = .thinking
            setProgress("Preparando el modelo de transcripción…", progress: progress)
        case let .transcribing(progress):
            phaseMood = .thinking
            setProgress("Transcribiendo \(subject) en esta Mac…", progress: progress)
        case .separatingVoices:
            phaseMood = .thinking
            setProgress("Separando las voces de la llamada…")
        case .uploading:
            phaseMood = .thinking
            setProgress("Enviando la transcripción para análisis…")
        case let .finished(sessionId):
            phaseMood = .idle
            removeProgress()
            if lastFinishedSession != sessionId {
                lastFinishedSession = sessionId
                pendingFinished = sessionId
                say("Sesión creada. Claude está analizando \(subject); te aviso cuando esté.", mood: .happy, dismissAfter: 10)
            }
        case let .failed(message):
            phaseMood = .idle
            removeProgress()
            if lastFailure != message {
                lastFailure = message
                let details = onShowRecorder.map { Action(title: "Ver detalles", perform: $0) }
                say(message, kind: .error, mood: .sad, action: details, dismissAfter: 30)
            }
        }
        if case .failed = phase {} else { lastFailure = nil }

        if let micProblem {
            if micProblem != lastMicProblem {
                lastMicProblem = micProblem
                let restart = onRestartMic.map { Action(title: "Reiniciar micrófono", perform: $0) }
                say("Problema con el micrófono: \(micProblem)", kind: .error, mood: .alert, action: restart, dismissAfter: 30)
            }
        } else {
            lastMicProblem = nil
        }

        if hasInterrupted, !announcedInterrupted, !phase.isBusy {
            announcedInterrupted = true
            let recover = onRecover.map { Action(title: "Recuperar", perform: $0) }
            say("Tengo una grabación interrumpida. ¿La recupero?", mood: .alert, action: recover, dismissAfter: 60)
        }

        if let notice, notice.id != lastNoticeId {
            lastNoticeId = notice.id
            say(notice.text, mood: .talking, dismissAfter: 8)
        }

        if let error {
            if error != lastErrorMessage {
                lastErrorMessage = error
                say(error, kind: .error, mood: .sad, dismissAfter: 15)
            }
        } else {
            lastErrorMessage = nil
        }
        tick()
    }

    /// Id de la sesión recién creada (una sola vez) para vigilar su análisis.
    func takePendingFinished() -> String? {
        defer { pendingFinished = nil }
        return pendingFinished
    }

    // MARK: Globos

    func say(_ text: String, kind: Bubble.Kind = .info, mood: CompanionMood? = nil, action: Action? = nil, dismissAfter: TimeInterval? = 8) {
        bubbles.append(Bubble(kind: kind, text: text, mood: mood, action: action, dismissAfter: dismissAfter))
        tick()
    }

    func dismissCurrent() {
        guard let current else { return }
        bubbles.removeAll { $0.id == current.id }
        wake()
        tick()
    }

    func dismissAll() {
        bubbles.removeAll { $0.kind != .progress }
    }

    /// Hay un solo globo de progreso; se actualiza en lugar de apilarse.
    private func setProgress(_ text: String, elapsedSince: Date? = nil, progress: Double? = nil, action: Action? = nil) {
        if let index = bubbles.firstIndex(where: { $0.kind == .progress }) {
            bubbles[index].text = text
            bubbles[index].elapsedSince = elapsedSince
            bubbles[index].progress = progress
            bubbles[index].action = action
        } else {
            bubbles.append(Bubble(kind: .progress, text: text, elapsedSince: elapsedSince, progress: progress, action: action))
        }
    }

    private func removeProgress() {
        bubbles.removeAll { $0.kind == .progress }
    }

    // MARK: Reloj

    /// Llamar cada segundo (y tras cada cambio): cierra globos vencidos, duerme y varía el reposo.
    func tick() {
        let now = now()
        if let until = previewUntil, now >= until { stopPreview() }
        if let until = gesture?.until, now >= until { gesture = nil }
        if let index = bubbles.firstIndex(where: { $0.id == current?.id }) {
            if bubbles[index].shownAt == nil { bubbles[index].shownAt = now }
            if let shownAt = bubbles[index].shownAt, let after = bubbles[index].dismissAfter, now >= shownAt.addingTimeInterval(after) {
                bubbles.remove(at: index)
                tick()
                return
            }
        }
        let quiet = phaseMood == .idle && bubbles.isEmpty && !chatOpen
        asleep = quiet && now.timeIntervalSince(lastInteraction) >= Self.sleepAfter
        if now >= nextIdleChange {
            idleVariant += 1
            nextIdleChange = now.addingTimeInterval(.random(in: Self.idleChangeRange))
        }
        // Gestos al azar: solo tranquilo y despierto; no cuentan como interacción (no evitan que se duerma).
        if now >= nextRandom {
            if pack.behavior.randomEnabled, quiet, !asleep, gesture == nil, previewMood == nil { perform(.random) }
            scheduleRandom()
        }
    }

    // MARK: Cumpleaños

    /// Texto con los cumpleaños y aniversarios de los próximos 7 días, o nil.
    static func upcomingText(people: [TeamMember], now: Date = .now) -> String? {
        let lines = people.compactMap { person in person.upcomingDate(now: now).map { "\(person.name): \($0)" } }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

/// Conversación propia del personaje con "Preguntar" (no toca la que está abierta en la app).
@MainActor
@Observable
final class CompanionChat {
    private(set) var conversation: Conversation?
    private(set) var asking = false
    private(set) var error: String?
    var question = ""

    private let api = APIClient()

    var lastQuestion: ConversationMessage? { conversation?.messages.last { $0.isUser } }
    var lastAnswer: ConversationMessage? { conversation?.messages.last { !$0.isUser } }

    /// Envía la pregunta escrita; devuelve false si no se pudo (y la deja en el campo).
    @discardableResult
    func send() async -> Bool {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !asking else { return false }
        question = ""
        asking = true
        error = nil
        defer { asking = false }
        do {
            conversation = if let current = conversation {
                try await api.ask(conversationId: current.id, question: q)
            } else {
                try await api.createConversation(.init(question: q))
            }
            return true
        } catch {
            self.error = error.localizedDescription
            question = q
            return false
        }
    }

    func reset() {
        conversation = nil
        error = nil
        question = ""
    }
}

/// Dónde va el panel: el personaje tiene un tamaño fijo y el globo crece hacia arriba.
enum CompanionGeometry {
    /// Tamaño del personaje al 100 %.
    static let characterSize = CGSize(width: 180, height: 200)
    /// Escala mínima y máxima del personaje (60 % ≈ 108 × 120 pt).
    static let minScale = 0.6
    static let maxScale = 2.5
    static let menuGap: CGFloat = 8

    static func clampScale(_ scale: Double) -> Double {
        guard scale.isFinite else { return 1 }
        return min(max(scale, minScale), maxScale)
    }

    /// El alto sale de la escala; el ancho, de la proporción del personaje (ancho ÷ alto).
    static func characterSize(scale: Double, aspect: Double = CharacterPack.duckAspect) -> CGSize {
        let height = characterSize.height * clampScale(scale)
        return CGSize(width: (height * aspect).rounded(), height: height.rounded())
    }

    /// Al cambiar de tamaño con el menú abierto queda fijo el borde del personaje que da al menú:
    /// con el menú a la derecha crece hacia la izquierda; con el menú a la izquierda, hacia la derecha.
    static func resizedOrigin(origin: CGPoint, from old: CGSize, to new: CGSize, menuOnRight: Bool) -> CGPoint {
        menuOnRight ? CGPoint(x: origin.x + old.width - new.width, y: origin.y) : origin
    }

    /// Mismo punto inferior central al cambiar el ancho del cuadro.
    static func recentered(origin: CGPoint, from old: CGSize, to new: CGSize) -> CGPoint {
        CGPoint(x: (origin.x + (old.width - new.width) / 2).rounded(), y: origin.y)
    }
    static let bubbleWidth: CGFloat = 300
    static let spacing: CGFloat = 6

    struct Layout: Equatable {
        var frame: CGRect
        /// El globo sobresale hacia la izquierda del personaje (cerca del borde derecho de la pantalla).
        var bubbleOnLeft: Bool
        var characterSize: CGSize = CompanionGeometry.characterSize
    }

    /// Frame del panel para un personaje con esquina inferior izquierda en `origin` y un contenido de `contentSize`
    /// (el personaje solo, o personaje + globo). Siempre dentro de `screen`.
    static func layout(characterOrigin origin: CGPoint, contentSize: CGSize, screen: CGRect,
                       character: CGSize = characterSize) -> Layout {
        let width = max(contentSize.width, character.width)
        let height = max(contentSize.height, character.height)
        var x = origin.x
        var bubbleOnLeft = false
        let extra = width - character.width
        if extra > 0, origin.x + width > screen.maxX, origin.x - extra >= screen.minX {
            bubbleOnLeft = true
            x = origin.x - extra
        }
        let frame = clamp(CGRect(x: x, y: origin.y, width: width, height: height), to: screen)
        return Layout(frame: frame, bubbleOnLeft: bubbleOnLeft, characterSize: character)
    }

    /// Mete el frame en la pantalla; si no cabe, se alinea a la esquina inferior izquierda.
    static func clamp(_ frame: CGRect, to screen: CGRect) -> CGRect {
        var f = frame
        if f.maxX > screen.maxX { f.origin.x = screen.maxX - f.width }
        if f.minX < screen.minX { f.origin.x = screen.minX }
        if f.maxY > screen.maxY { f.origin.y = screen.maxY - f.height }
        if f.minY < screen.minY { f.origin.y = screen.minY }
        return f
    }

    /// Esquina inferior izquierda del personaje dentro de un panel ya colocado.
    static func characterOrigin(in layout: Layout) -> CGPoint {
        CGPoint(x: layout.bubbleOnLeft ? layout.frame.maxX - layout.characterSize.width : layout.frame.minX, y: layout.frame.minY)
    }

    /// Posición inicial: abajo a la derecha, con margen.
    static func defaultOrigin(in screen: CGRect, character: CGSize = characterSize) -> CGPoint {
        CGPoint(x: screen.maxX - character.width - 24, y: screen.minY + 24)
    }

    /// Menú junto al personaje: a la derecha si cabe completo, si no a la izquierda;
    /// alineado arriba con el personaje y siempre dentro de la pantalla.
    static func menuFrame(size: CGSize, beside character: CGRect, screen: CGRect, gap: CGFloat = menuGap) -> CGRect {
        var x = character.maxX + gap
        if x + size.width > screen.maxX, character.minX - gap - size.width >= screen.minX {
            x = character.minX - gap - size.width
        }
        let y = character.maxY - size.height
        return clamp(CGRect(origin: CGPoint(x: x, y: y), size: size), to: screen)
    }
}
