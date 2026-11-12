import AppKit
import SwiftUI

/// Contenido del panel: el globo (aviso o chat) arriba y el personaje abajo.
struct CompanionRootView: View {
    let controller: CompanionController
    @AppStorage(CompanionController.followsCursorKey) private var followsCursor = true

    var body: some View {
        let model = controller.model
        let layout = controller.layout
        VStack(alignment: layout.bubbleOnLeft ? .trailing : .leading, spacing: CompanionGeometry.spacing) {
            if model.chatOpen {
                ChatBubble(controller: controller)
                    .frame(width: CompanionGeometry.bubbleWidth)
            } else if let bubble = model.current {
                SpeechBubble(bubble: bubble, tailOnRight: layout.bubbleOnLeft) { model.dismissCurrent() }
                    .frame(width: CompanionGeometry.bubbleWidth)
            }
            ZStack {
                CharacterSceneView(character: controller.character, mood: model.mood, idleVariant: model.idleVariant,
                                   look: followsCursor ? controller.lookPoint : nil)
                InteractionLayer(controller: controller)
            }
            .frame(width: CompanionGeometry.characterSize.width, height: CompanionGeometry.characterSize.height)
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
            controller.showMenu(at: point, in: view)
        }
        view.onDoubleClick = { controller.openMainWindow() }
        view.onDrag = { controller.drag(by: $0) }
        view.onDragEnd = { controller.endDrag() }
        view.onHover = { controller.hover($0) }
        return view
    }

    func updateNSView(_ view: CompanionInteractionView, context: Context) {}
}

/// Globo de diálogo con un aviso: texto, contador o progreso y, si hay, una acción.
struct SpeechBubble: View {
    let bubble: CompanionModel.Bubble
    let tailOnRight: Bool
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(bubble.text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.trailing, 16)
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
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(tint.opacity(0.6)))
        .overlay(alignment: .topTrailing) {
            Button(action: dismiss) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(6)
            .help("Cerrar")
        }
        .overlay(alignment: tailOnRight ? .bottomTrailing : .bottomLeading) {
            BubbleTail(tint: tint).offset(x: tailOnRight ? -28 : 28, y: 9)
        }
        .padding(.bottom, 10)
    }

    private var tint: Color {
        switch bubble.kind {
        case .error: .red
        case .progress: .blue
        case .info: .green
        }
    }
}

/// Pico del globo, apuntando al personaje.
private struct BubbleTail: View {
    let tint: Color

    var body: some View {
        Image(systemName: "arrowtriangle.down.fill")
            .font(.system(size: 16))
            .foregroundStyle(.regularMaterial)
            .overlay(Image(systemName: "arrowtriangle.down").font(.system(size: 16)).foregroundStyle(tint.opacity(0.6)))
    }
}

/// Globo con el chat: la pregunta va a "Preguntar" y la respuesta se muestra con sus citas.
struct ChatBubble: View {
    let controller: CompanionController
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
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.blue.opacity(0.5)))
        .padding(.bottom, 10)
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
