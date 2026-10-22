import SwiftUI

struct SessionDetailView: View {
    @Environment(AppStore.self) private var store

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

                if let result = detail.analysis?.result {
                    AnalysisSections(result: result)
                }

                if let transcript = detail.transcript {
                    DisclosureGroup("Transcripción") {
                        Text(transcript.text)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
        }
        .toolbar {
            Button {
                Task { await store.reanalyze() }
            } label: {
                Label("Re-analizar", systemImage: "arrow.clockwise")
            }
            .disabled(session.status.isInProgress)
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

            DisclosureGroup("Resumen detallado") {
                Text(result.summary.detailed)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
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

private struct PriorityDot: View {
    let priority: String

    var body: some View {
        Circle()
            .fill(priority == "high" ? Color.red : priority == "medium" ? .orange : .gray)
            .frame(width: 8, height: 8)
            .accessibilityLabel("Prioridad \(priority)")
    }
}
