import SwiftUI

/// Columna central de "Preguntar": conversaciones guardadas.
struct ConversationListView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            if store.conversations.isEmpty {
                ContentUnavailableView("Sin conversaciones", systemImage: "bubble.left.and.text.bubble.right",
                                       description: Text("Pregunta sobre decisiones, pendientes o personas; Claude busca en tus sesiones y cita de dónde sale cada respuesta."))
                    .frame(maxHeight: .infinity)
            } else {
                List(store.conversations, selection: $store.selectedConversationId) { c in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(c.title).font(.headline).lineLimit(2)
                        Text([
                            store.scopeLabel(projectId: c.projectId, personId: c.personId),
                            c.updatedAt.formatted(date: .abbreviated, time: .shortened),
                            c.costUsd.map { Money.usd($0) },
                        ].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                    .tag(c.id)
                    .contextMenu {
                        Button("Eliminar conversación…", role: .destructive) { store.pendingDeletion = .conversation(c) }
                    }
                }
            }
            Divider()
            Button { store.startConversation() } label: {
                Label("Nueva conversación", systemImage: "square.and.pencil")
            }
            .padding(8)
        }
        .navigationTitle("Preguntar")
        .task { await store.loadConversations() }
    }
}

/// Detalle: los mensajes y el campo para preguntar.
struct ConversationView: View {
    @Environment(AppStore.self) private var store
    @State private var question = ""
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let c = store.conversation {
                            Text(store.scopeLabel(projectId: c.projectId, personId: c.personId))
                                .font(.caption).foregroundStyle(.secondary)
                            ForEach(c.messages) { MessageBubble(message: $0, sessions: c.sessions) }
                        } else {
                            NewConversationHeader()
                        }
                        if store.asking {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Claude está buscando en tus sesiones…").foregroundStyle(.secondary)
                            }
                            .id("asking")
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(24)
                    .frame(maxWidth: 820, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: store.conversation?.messages.count) { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: store.asking) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                TextField(store.conversation == nil ? "¿Qué quieres saber?" : "Pregunta de seguimiento…", text: $question, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(send)
                    .padding(8)
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .buttonStyle(.plain)
                    .disabled(store.asking || question.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(12)
        }
        .environment(\.openURL, OpenURLAction { url in
            guard let id = Citations.sessionId(from: url) else { return .systemAction }
            let projectId = store.conversation?.sessions.first { $0.id == id }?.projectId
            Task { await store.show(sessionId: id, projectId: projectId) }
            return .handled
        })
        .onAppear { focused = true }
        .task(id: store.selectedConversationId) { await store.loadConversation() }
    }

    private func send() {
        let q = question
        question = ""
        Task {
            if !(await store.ask(q)) { question = q }
        }
    }
}

private struct NewConversationHeader: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 14) {
            Text("Pregunta sobre tu historial").font(.largeTitle.bold())
            Picker("Sobre", selection: Binding(
                get: { store.newConversationScope.projectId.map { "p:\($0)" } ?? store.newConversationScope.personId.map { "u:\($0)" } ?? "" },
                set: { v in
                    store.newConversationScope = v.hasPrefix("p:") ? (String(v.dropFirst(2)), nil)
                        : v.hasPrefix("u:") ? (nil, String(v.dropFirst(2))) : (nil, nil)
                }
            )) {
                Text("Todo el historial").tag("")
                Section("Proyectos") { ForEach(store.projects) { Text($0.name).tag("p:\($0.id)") } }
                Section("Equipo") { ForEach(store.people) { Text($0.name).tag("u:\($0.id)") } }
            }
            .frame(maxWidth: 360)
            VStack(alignment: .leading, spacing: 6) {
                Text("Por ejemplo:").font(.callout).foregroundStyle(.secondary)
                ForEach(["¿Qué se decidió sobre los pagos y cuándo?",
                         "¿Qué ha estado bloqueando a Tavo este mes?",
                         "¿Qué pendientes llevan más de dos semanas abiertos?"], id: \.self) { example in
                    Button("“\(example)”") { Task { await store.ask(example) } }
                        .buttonStyle(.link)
                }
            }
            Text("Claude busca en los análisis y transcripciones guardados; cada respuesta cuesta unos centavos.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct MessageBubble: View {
    let message: ConversationMessage
    let sessions: [Conversation.CitedSession]

    var body: some View {
        if message.isUser {
            HStack {
                Spacer(minLength: 80)
                Text(message.content)
                    .textSelection(.enabled)
                    .padding(10)
                    .background(.blue.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text(rendered)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text([
                    message.model.map(ModelName.pretty),
                    message.toolCalls.map { "\($0) búsquedas" },
                    message.usage?.costUsd.map { Money.usd($0) },
                ].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private var rendered: AttributedString {
        let md = Citations.markdown(message.content, sessions: sessions)
        return (try? AttributedString(markdown: md, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(md)
    }
}
