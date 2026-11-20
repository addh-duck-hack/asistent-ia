import AppKit
import SwiftUI

/// Contenido del panel: el globo (aviso o chat) arriba y el personaje abajo.
struct CompanionRootView: View {
    let controller: CompanionController
    @AppStorage(CompanionController.followsCursorKey) private var followsCursor = true

    var body: some View {
        let model = controller.model
        let layout = controller.layout
        let tip = SpeechBalloonShape.tip(characterWidth: controller.characterSize.width, bubbleWidth: CompanionGeometry.bubbleWidth)
        VStack(alignment: layout.bubbleOnLeft ? .trailing : .leading, spacing: CompanionGeometry.spacing) {
            if model.chatOpen {
                ChatBubble(controller: controller, tailOnRight: layout.bubbleOnLeft, tip: tip)
                    .frame(width: CompanionGeometry.bubbleWidth)
            } else if let bubble = model.current {
                SpeechBubble(bubble: bubble, tailOnRight: layout.bubbleOnLeft, tip: tip) { model.dismissCurrent() }
                    .frame(width: CompanionGeometry.bubbleWidth)
            }
            ZStack {
                CharacterSceneView(character: controller.character, revision: controller.characterRevision,
                                   mood: model.mood, idleVariant: model.idleVariant,
                                   look: followsCursor ? controller.lookPoint : nil,
                                   gesture: model.gesture, onGestureEnd: { model.endGesture($0) })
                if controller.showsZones {
                    ZoneGuide(behavior: controller.character.pack.behavior)
                }
                InteractionLayer(controller: controller)
            }
            .frame(width: controller.characterSize.width, height: controller.characterSize.height)
        }
        .fixedSize()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { controller.reportContentSize($0) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: layout.bubbleOnLeft ? .bottomTrailing : .bottomLeading)
        .captureWindowRouter()
    }
}

private struct InteractionLayer: NSViewRepresentable {
    let controller: CompanionController

    func makeNSView(context: Context) -> CompanionInteractionView {
        let view = CompanionInteractionView()
        let controller = controller
        view.onClick = { [weak view] point in
            guard let view else { return }
            controller.click(at: point, in: view)
        }
        view.onMenu = { [weak view] point in
            guard let view else { return }
            controller.showMenu(at: point, in: view)
        }
        view.onDoubleClick = { controller.openMainWindow() }
        view.onDrag = { controller.drag(by: $0) }
        view.onDragEnd = { controller.endDrag() }
        view.onHover = { controller.hover($0) }
        view.onMagnify = { controller.magnify(by: $0) }
        return view
    }

    func updateNSView(_ view: CompanionInteractionView, context: Context) {}
}

/// Guía de las zonas de clic (cabeza, cuerpo, pies) sobre el personaje, mientras se ajustan.
private struct ZoneGuide: View {
    let behavior: CharacterPack.Behavior

    var body: some View {
        GeometryReader { proxy in
            let head = proxy.size.height * behavior.headZone
            let feet = proxy.size.height * behavior.feetZone
            VStack(spacing: 0) {
                band("Cabeza", .blue).frame(height: head)
                band("Cuerpo", .green)
                band("Pies", .orange).frame(height: feet)
            }
        }
        .allowsHitTesting(false)
    }

    private func band(_ title: String, _ color: Color) -> some View {
        color.opacity(0.22)
            .overlay(Rectangle().strokeBorder(color.opacity(0.7), lineWidth: 1))
            .overlay(alignment: .topLeading) {
                Text(title).font(.caption2.bold()).foregroundStyle(.white)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(color.opacity(0.85), in: RoundedRectangle(cornerRadius: 3))
                    .padding(3)
            }
    }
}

/// Globo de diálogo con un aviso: texto, contador o progreso y, si hay, una acción.
/// Tiene forma de globo de cómic: rectángulo de esquinas redondeadas a mano, borde negro grueso,
/// pico recto hacia el personaje y sombra suave.
struct SpeechBubble: View {
    let bubble: CompanionModel.Bubble
    let tailOnRight: Bool
    /// Dónde cae la punta del pico (ver `SpeechBalloonShape.tip`).
    var tip: CGFloat = 0.8
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                Text(bubble.text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: dismiss) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Cerrar")
            }
            if let since = bubble.elapsedSince {
                TimelineView(.periodic(from: since, by: 1)) { context in
                    Text(Duration.seconds(context.date.timeIntervalSince(since)).formatted(.time(pattern: .hourMinuteSecond)))
                        .font(.system(.title3, design: .monospaced))
                }
            }
            if let progress = bubble.progress {
                ProgressView(value: progress)
            } else if bubble.kind == .progress, bubble.elapsedSince == nil {
                ProgressView().controlSize(.small)
            }
            if let action = bubble.action {
                Button(action.title) { action.perform() }
                    .controlSize(.small)
            }
        }
        // Alto mínimo: con una sola línea el globo no queda como una píldora.
        .frame(minHeight: 40, alignment: .center)
        .comicBalloon(tailOnRight: tailOnRight, tip: tip,
                      stroke: bubble.kind == .error ? Color(red: 0.8, green: 0.15, blue: 0.15) : .black)
    }
}

extension View {
    /// Dibuja el contenido dentro del globo de cómic (aviso o chat), con su pico hacia el personaje.
    func comicBalloon(tailOnRight: Bool, tip: CGFloat, stroke: Color = .black) -> some View {
        let margin = SpeechBalloonShape.margin
        return padding(.horizontal, 20 + margin)
            .padding(.top, 18 + margin)
            .padding(.bottom, 18 + margin + SpeechBalloonShape.tailHeight)
            .foregroundStyle(.black)
            .background {
                let shape = SpeechBalloonShape(tailOnRight: tailOnRight, tip: tip)
                ZStack {
                    shape.fill(.white)
                    shape.stroke(stroke, style: StrokeStyle(lineWidth: SpeechBalloonShape.lineWidth, lineJoin: .round))
                }
                .compositingGroup()
                .shadow(color: .black.opacity(0.35), radius: 3, x: -3, y: 3)
            }
            // El globo es blanco siempre, así que el texto y los controles van en claro también en modo oscuro.
            .environment(\.colorScheme, .light)
    }
}

/// Contorno del globo: rectángulo con esquinas redondeadas un poco irregulares (como dibujado a mano)
/// y un pico recto abajo, en un solo trazo.
struct SpeechBalloonShape: Shape {
    static let tailHeight: CGFloat = 22
    static let lineWidth: CGFloat = 3.5
    /// Espacio alrededor del dibujo para el borde y la sombra (que cae hacia abajo a la izquierda).
    static let margin: CGFloat = 8
    var tailOnRight = true
    /// Punta del pico, en fracción del ancho medida desde el lado contrario al pico (0.5 = centro).
    var tip: CGFloat = 0.8

    /// Punta sobre el centro del personaje, que queda pegado al lado del pico.
    static func tip(characterWidth: CGFloat, bubbleWidth: CGFloat) -> CGFloat {
        min(max(1 - characterWidth / 2 / max(bubbleWidth, 1), 0.5), 0.8)
    }

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: Self.margin, dy: Self.margin)
        let b = CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height - Self.tailHeight)
        // Coordenadas para el pico a la derecha; se reflejan si va a la izquierda.
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: tailOnRight ? x : b.minX + b.maxX - x, y: y)
        }
        // Radios de cada esquina (horizontal, vertical): un poco distintos entre sí, como en el dibujo.
        let cap = b.height * 0.36
        let tl = (min(b.width * 0.12, 34), min(26, cap)), tr = (min(b.width * 0.09, 26), min(34, cap))
        let br = (min(b.width * 0.08, 24), min(24, cap)), bl = (min(b.width * 0.11, 30), min(26, cap))
        let k: CGFloat = 0.55
        let bulge: CGFloat = 1.5
        let tipX = b.minX + b.width * tip
        var path = Path()
        path.move(to: p(b.minX + tl.0, b.minY + 1))
        // Arriba: casi recta, sube apenas hacia la derecha.
        path.addLine(to: p(b.maxX - tr.0, b.minY))
        path.addCurve(to: p(b.maxX, b.minY + tr.1), control1: p(b.maxX - tr.0 * (1 - k), b.minY),
                      control2: p(b.maxX, b.minY + tr.1 * (1 - k)))
        // Derecha: apenas abombada.
        path.addQuadCurve(to: p(b.maxX - 1, b.maxY - br.1), control: p(b.maxX + bulge, b.midY))
        path.addCurve(to: p(b.maxX - 1 - br.0, b.maxY), control1: p(b.maxX - 1, b.maxY - br.1 * (1 - k)),
                      control2: p(b.maxX - 1 - br.0 * (1 - k), b.maxY))
        // Abajo hasta el pico; pico recto con la punta un poco hacia atrás.
        path.addLine(to: p(tipX + b.width * 0.065, b.maxY))
        path.addLine(to: p(tipX - b.width * 0.01, r.maxY))
        path.addLine(to: p(tipX - b.width * 0.045, b.maxY))
        // Abajo a la izquierda: el borde sube un poco antes de la esquina.
        path.addQuadCurve(to: p(b.minX + bl.0, b.maxY - 2), control: p(b.minX + bl.0 * 2.5, b.maxY))
        path.addCurve(to: p(b.minX + 1, b.maxY - bl.1), control1: p(b.minX + bl.0 * (1 - k), b.maxY - 3),
                      control2: p(b.minX + 1, b.maxY - bl.1 * (1 - k)))
        // Izquierda: apenas abombada.
        path.addQuadCurve(to: p(b.minX + 2, b.minY + tl.1), control: p(b.minX - bulge, b.midY))
        path.addCurve(to: p(b.minX + tl.0, b.minY + 1), control1: p(b.minX + 2, b.minY + tl.1 * (1 - k)),
                      control2: p(b.minX + tl.0 * (1 - k), b.minY + 1))
        path.closeSubpath()
        return path
    }
}

/// Globo con el chat: la pregunta va a "Preguntar" y la respuesta se muestra con sus citas.
struct ChatBubble: View {
    let controller: CompanionController
    let tailOnRight: Bool
    var tip: CGFloat = 0.8
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var chat = controller.model.chat
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(chat.conversation?.title ?? "Pregúntame sobre tus reuniones")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button { controller.closeChat() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Cerrar")
            }
            if let question = chat.lastQuestion {
                Text(question.content).font(.callout).foregroundStyle(.secondary).lineLimit(3)
            }
            if chat.asking {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Claude está buscando en tus sesiones…").font(.caption).foregroundStyle(.secondary)
                }
            } else if let answer = chat.lastAnswer {
                ScrollView {
                    AnswerText(message: answer, sessions: chat.conversation?.sessions ?? [])
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
            }
            if let error = chat.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack(alignment: .bottom, spacing: 6) {
                TextField(chat.conversation == nil ? "¿Qué quieres saber?" : "Pregunta de seguimiento…", text: $chat.question, axis: .vertical)
                    .lineLimit(1 ... 4)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(send)
                    .padding(6)
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .buttonStyle(.plain)
                    .disabled(chat.asking || chat.question.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let conversation = chat.conversation {
                HStack {
                    Button("Abrir en la app") { controller.openConversationInApp(conversation.id) }
                    Button("Nueva pregunta") { chat.reset() }
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
        .comicBalloon(tailOnRight: tailOnRight, tip: tip)
        .environment(\.openURL, OpenURLAction { url in
            guard let id = Citations.sessionId(from: url) else { return .systemAction }
            let projectId = chat.conversation?.sessions.first { $0.id == id }?.projectId
            controller.showSession(id: id, projectId: projectId)
            return .handled
        })
        .onAppear { focused = true }
    }

    private func send() {
        Task { await controller.model.chat.send() }
    }
}
