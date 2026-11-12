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

    /// Acciones que requieren cosas que el modelo no tiene (las pone el controlador).
    var onRestartMic: (@MainActor () -> Void)?
    var onRecover: (@MainActor () -> Void)?

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

    init(now: @escaping () -> Date = { .now }, chat: CompanionChat = CompanionChat()) {
        self.now = now
        self.chat = chat
        lastInteraction = now()
        nextIdleChange = now().addingTimeInterval(Self.idleChangeRange.lowerBound)
    }

    // MARK: Ánimo

    /// Globo a la vista: el primero que no sea de progreso; si no hay, el de progreso.
    var current: Bubble? { bubbles.first { $0.kind != .progress } ?? bubbles.first }

    var mood: CompanionMood {
        if let mood = current?.mood { return mood }
        if phaseMood != .idle { return phaseMood }
        if chatOpen { return chat.asking ? .thinking : .listening }
        return asleep ? .sleeping : .idle
    }

    /// Cualquier interacción: despierta y reinicia el contador de sueño.
    func wake() {
        lastInteraction = now()
        asleep = false
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
            setProgress("Grabando \(subject)", elapsedSince: since)
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
                say(message, kind: .error, mood: .sad, dismissAfter: 20)
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
    private func setProgress(_ text: String, elapsedSince: Date? = nil, progress: Double? = nil) {
        if let index = bubbles.firstIndex(where: { $0.kind == .progress }) {
            bubbles[index].text = text
            bubbles[index].elapsedSince = elapsedSince
            bubbles[index].progress = progress
        } else {
            bubbles.append(Bubble(kind: .progress, text: text, elapsedSince: elapsedSince, progress: progress))
        }
    }

    private func removeProgress() {
        bubbles.removeAll { $0.kind == .progress }
    }

    // MARK: Reloj

    /// Llamar cada segundo (y tras cada cambio): cierra globos vencidos, duerme y varía el reposo.
    func tick() {
        let now = now()
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
    static let characterSize = CGSize(width: 180, height: 200)
    static let bubbleWidth: CGFloat = 300
    static let spacing: CGFloat = 6

    struct Layout: Equatable {
        var frame: CGRect
        /// El globo sobresale hacia la izquierda del personaje (cerca del borde derecho de la pantalla).
        var bubbleOnLeft: Bool
    }

    /// Frame del panel para un personaje con esquina inferior izquierda en `origin` y un contenido de `contentSize`
    /// (el personaje solo, o personaje + globo). Siempre dentro de `screen`.
    static func layout(characterOrigin origin: CGPoint, contentSize: CGSize, screen: CGRect) -> Layout {
        let width = max(contentSize.width, characterSize.width)
        let height = max(contentSize.height, characterSize.height)
        var x = origin.x
        var bubbleOnLeft = false
        let extra = width - characterSize.width
        if extra > 0, origin.x + width > screen.maxX, origin.x - extra >= screen.minX {
            bubbleOnLeft = true
            x = origin.x - extra
        }
        let frame = clamp(CGRect(x: x, y: origin.y, width: width, height: height), to: screen)
        return Layout(frame: frame, bubbleOnLeft: bubbleOnLeft)
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
        CGPoint(x: layout.bubbleOnLeft ? layout.frame.maxX - characterSize.width : layout.frame.minX, y: layout.frame.minY)
    }

    /// Posición inicial: abajo a la derecha, con margen.
    static func defaultOrigin(in screen: CGRect) -> CGPoint {
        CGPoint(x: screen.maxX - characterSize.width - 24, y: screen.minY + 24)
    }
}
