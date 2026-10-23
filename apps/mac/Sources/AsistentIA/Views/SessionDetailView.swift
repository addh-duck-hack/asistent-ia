import SwiftUI

struct SessionDetailView: View {
    @Environment(AppStore.self) private var store
    @State private var replacing = false

    var body: some View {
        Group {
            if let detail = store.detail, detail.session.id == store.selectedSessionId {
                content(detail)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func content(_ detail: SessionDetail) -> some View {
        let session = detail.session
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header(session)

                switch session.status {
                case .pending, .analyzing:
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(session.status == .pending ? "En cola para análisis…" : "Claude está analizando la sesión…")
                            .foregroundStyle(.secondary)
                    }
                case .failed:
                    Label(session.error ?? "El análisis falló.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                case .done:
                    EmptyView()
                }

                VoicesSection(detail: detail).id(detail.session.id)

                if let analysis = detail.analysis {
                    AnalysisMeta(analysis: analysis)
                    AnalysisSections(result: analysis.result)
                }

                if let transcript = detail.transcript {
                    DisclosureGroup("Transcripción") {
                        VStack(alignment: .leading, spacing: 8) {
                            Button {
                                replacing = true
                            } label: {
                                Label("Buscar y reemplazar…", systemImage: "text.magnifyingglass")
                            }
                            .disabled(session.status.isInProgress)
                            Text(transcript.text)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.top, 6)
                    }
                    .sheet(isPresented: $replacing) { ReplaceSheet(detail: detail) }
                }
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
        }
        .toolbar {
            ShareToolbarButtons(
                copy: { Task { await store.copy(session: session) } },
                export: { Task { await store.export(session: session) } }
            )
            .disabled(detail.analysis == nil)

            Menu {
                ForEach(AnalysisDepth.allCases) { depth in
                    Button {
                        Task { await store.reanalyze(depth: depth) }
                    } label: {
                        let model = store.profile(for: depth).map { " (\($0.modelName))" } ?? ""
                        Text("\(depth.label)\(model)\(depth == session.depth ? " — actual" : "")")
                    }
                }
            } label: {
                Label("Re-analizar", systemImage: "arrow.clockwise")
            } primaryAction: {
                Task { await store.reanalyze() }
            }
            .disabled(session.status.isInProgress)
            .help("Clic: mismo nivel · Flecha: elegir otro nivel")

            Button(role: .destructive) {
                store.pendingDeletion = .session(session)
            } label: {
                Label("Eliminar sesión", systemImage: "trash")
            }
            .help("Eliminar sesión")
        }
    }

    private func header(_ session: Session) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(session.title).font(.largeTitle.bold())
                StatusBadge(status: session.status)
            }
            Text("\(session.date.formatted(date: .complete, time: .shortened)) · \(session.type.label)")
                .foregroundStyle(.secondary)
            if let people = session.participants, !people.isEmpty {
                Text(people.joined(separator: ", ")).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

private struct AnalysisSections: View {
    let result: AnalysisResult

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(result.summary.executive)
                .font(.title3)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .textSelection(.enabled)

            section("Decisiones", systemImage: "checkmark.seal", items: result.decisions) { d in
                VStack(alignment: .leading, spacing: 2) {
                    Text(d.decision).bold()
                    Text([d.decidedBy.map { "Decidió: \($0)" }, d.context].compactMap { $0 }.joined(separator: " · "))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            section("Action items", systemImage: "checklist", items: result.actionItems) { a in
                HStack(alignment: .firstTextBaseline) {
                    PriorityDot(priority: a.priority)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(a.task)
                        Text([a.owner ?? "Sin responsable", a.dueDate.map { "vence \($0)" }].compactMap { $0 }.joined(separator: " · "))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }

            section("Bloqueos", systemImage: "hand.raised", items: result.blockers) { b in
                HStack(alignment: .firstTextBaseline) {
                    PriorityDot(priority: b.severity)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(b.description)
                        if let affected = b.affected { Text("Afecta: \(affected)").font(.callout).foregroundStyle(.secondary) }
                    }
                }
            }

            section("Riesgos", systemImage: "exclamationmark.triangle", items: result.risks) { r in
                HStack(alignment: .firstTextBaseline) {
                    PriorityDot(priority: r.severity)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.description)
                        if let m = r.mitigation { Text("Mitigación: \(m)").font(.callout).foregroundStyle(.secondary) }
                    }
                }
            }

            section("Preguntas abiertas", systemImage: "questionmark.bubble", items: result.openQuestions) { q in
                Text(q)
            }

            if hasSignals {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Señales del equipo", systemImage: "person.3").font(.headline)
                    if let w = result.teamSignals.workload { Text("Carga: \(w)") }
                    if let m = result.teamSignals.morale { Text("Ánimo: \(m)") }
                    ForEach(result.teamSignals.dependencies, id: \.self) { Text("• \($0)") }
                }
            }

            section("Temas", systemImage: "list.bullet.rectangle", items: result.topics) { t in
                VStack(alignment: .leading, spacing: 2) {
                    Text([t.timestamp, t.title].compactMap { $0 }.joined(separator: "  ")).bold()
                    ForEach(t.keyPoints, id: \.self) { Text("• \($0)").font(.callout) }
                }
            }

            if let detailed = result.summary.detailed {
                DisclosureGroup("Resumen detallado") {
                    Text(detailed)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                }
            }
        }
    }

    private var hasSignals: Bool {
        result.teamSignals.workload != nil || result.teamSignals.morale != nil || !result.teamSignals.dependencies.isEmpty
    }

    @ViewBuilder
    private func section<Item: Hashable, Row: View>(
        _ title: String, systemImage: String, items: [Item], @ViewBuilder row: @escaping (Item) -> Row
    ) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Label("\(title) (\(items.count))", systemImage: systemImage).font(.headline)
                ForEach(items, id: \.self) { item in
                    row(item).textSelection(.enabled)
                }
            }
        }
    }
}

/// Nivel, modelo, effort, tokens y costo estimado del análisis.
private struct AnalysisMeta: View {
    let analysis: Analysis

    var body: some View {
        let parts: [String] = [
            analysis.depth?.label,
            ModelName.pretty(analysis.model),
            analysis.effort.map { "effort \($0)" },
            analysis.usage.map { "\($0.totalTokens.formatted()) tokens" },
            analysis.usage?.costUsd.map { "≈ \(Money.usd($0))" },
        ].compactMap { $0 }
        Label(parts.joined(separator: " · "), systemImage: "cpu")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

private struct PriorityDot: View {
    let priority: String

    var body: some View {
        Circle()
            .fill(priority == "high" ? Color.red : priority == "medium" ? .orange : .gray)
            .frame(width: 8, height: 8)
            .accessibilityLabel("Prioridad \(priority)")
    }
}

/// Voces de una llamada separada por voz: Claude sugiere quién es cada una y
/// el líder confirma. Confirmar guarda la huella en esta Mac para reconocer a
/// la persona sola en las próximas reuniones.
struct VoicesSection: View {
    @Environment(AppStore.self) private var store
    let detail: SessionDetail
    @State private var selection: [String: String] = [:] // etiqueta → personId
    @State private var saving = false
    private var player: ClipPlayer { ClipPlayer.shared }

    private var voices: [String: [Float]] { VoiceStore.shared.sessionVoices(detail.session.id) }

    /// Etiquetas de voz de la transcripción ("me" y "others" no cuentan).
    private var labels: [String] {
        let fromTranscript = (detail.transcript?.segments ?? []).compactMap(\.speaker).filter { $0 != "me" && $0 != "others" }
        var seen = Set<String>()
        let all = (fromTranscript + voices.keys.sorted()).filter { seen.insert($0).inserted }
        // Primero las que faltan por nombrar.
        return all.sorted { isUnknown($0) && !isUnknown($1) }
    }

    private func isUnknown(_ label: String) -> Bool { label.range(of: #"^Voz \d+$"#, options: .regularExpression) != nil }

    var body: some View {
        if detail.session.type == .meeting, labels.contains(where: { isUnknown($0) || voices[$0] != nil }) {
            VStack(alignment: .leading, spacing: 10) {
                Label("Voces de la llamada", systemImage: "person.wave.2").font(.headline)
                ForEach(labels, id: \.self) { label in
                    HStack(alignment: .firstTextBaseline) {
                        Text(label).frame(width: 150, alignment: .leading)
                            .foregroundStyle(isUnknown(label) ? .primary : .secondary)
                        Picker("", selection: Binding(get: { selection[label] ?? "" }, set: { selection[label] = $0.isEmpty ? nil : $0 })) {
                            Text("Sin nombre").tag("")
                            ForEach(store.people) { Text($0.name).tag($0.id) }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 240)
                        PlayVoiceButton(sessionId: detail.session.id, label: label, segments: detail.transcript?.segments ?? [])
                        if voices[label] == nil {
                            Image(systemName: "waveform.slash").foregroundStyle(.tertiary)
                                .help("Sin huella guardada en esta Mac: se renombra, pero no se reconocerá sola después")
                        }
                    }
                    if let clip = player.playingId.flatMap({ PlayVoiceButton.clip(playing: $0, label: label, segments: detail.transcript?.segments ?? []) }) {
                        Text("“\(clip.text)”").font(.caption).italic().foregroundStyle(.secondary)
                            .lineLimit(2).padding(.leading, 158)
                    }
                    if let guess = guess(for: label) {
                        Text("Claude: \(guess.name ?? "sin identificar") — \(guess.evidence)")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.leading, 158)
                    }
                }
                HStack {
                    Button(saving ? "Guardando…" : "Guardar nombres") {
                        let names = selection.compactMapValues { id in store.people.first { $0.id == id } }
                        saving = true
                        Task { await store.nameVoices(names); saving = false }
                    }
                    .disabled(saving || selection.isEmpty || detail.session.status.isInProgress)
                    Text("Si cambias un nombre, la sesión se vuelve a analizar.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .background(.purple.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            .onAppear(perform: prefill)
            .onChange(of: detail.analysis?.createdAt) { prefill() }
        }
    }

    private func guess(for label: String) -> AnalysisResult.SpeakerGuess? {
        detail.analysis?.result.speakerIdentification?.first { $0.label == label }
    }

    /// Propone: si la etiqueta ya es un nombre, esa persona; si es "Voz N", lo que sugirió Claude.
    private func prefill() {
        var s: [String: String] = [:]
        for label in labels {
            let name = isUnknown(label) ? guess(for: label)?.name : label
            if let name, let person = member(named: name) { s[label] = person.id }
        }
        selection = s
    }

    private func member(named name: String) -> TeamMember? {
        let key = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        return store.people.first { p in
            ([p.name] + p.aliases).contains { $0.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current) == key }
        }
    }
}

/// Reproduce extractos de una voz (sus fragmentos más largos); cada clic pasa al siguiente.
struct PlayVoiceButton: View {
    let sessionId: String
    let label: String
    let segments: [Segment]
    @State private var next = 0
    private var player: ClipPlayer { ClipPlayer.shared }

    private var clips: [Clip] { Clip.samples(for: label, in: segments) }
    private var audio: URL? { SessionAudio.shared.url(sessionId: sessionId, track: label == "me" ? .mic : .system) }
    private var isPlaying: Bool { player.playingId?.hasPrefix("\(sessionId)|\(label)|") == true }

    var body: some View {
        if let audio, !clips.isEmpty {
            Button {
                if isPlaying { player.stop(); return }
                let clip = clips[next % clips.count]
                player.play(audio, from: clip.start, to: clip.end, id: Self.id(sessionId, label, next % clips.count))
                next += 1
            } label: {
                Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle.fill").font(.title3)
            }
            .buttonStyle(.plain)
            .help("Escuchar un extracto de esta voz (\(clips.count) disponibles; cada clic, el siguiente)")
        }
    }

    static func id(_ sessionId: String, _ label: String, _ index: Int) -> String { "\(sessionId)|\(label)|\(index)" }

    /// El extracto que está sonando, si es de esta voz.
    static func clip(playing id: String, label: String, segments: [Segment]) -> Clip? {
        let parts = id.split(separator: "|")
        guard parts.count == 3, parts[1] == label, let i = Int(parts[2]) else { return nil }
        let clips = Clip.samples(for: label, in: segments)
        return clips.indices.contains(i) ? clips[i] : nil
    }
}
