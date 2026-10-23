import SwiftUI

/// Resúmenes semanales del proyecto (los lunes automáticamente o con "Generar ahora").
struct DigestListView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            if store.digests.isEmpty {
                ContentUnavailableView("Sin resúmenes", systemImage: "calendar",
                                       description: Text("Cada lunes a las 8:00 se genera el resumen de la semana. También puedes generarlo ahora."))
                    .frame(maxHeight: .infinity)
            } else {
                List(store.digests, selection: $store.selectedDigestId) { digest in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(digest.periodLabel).font(.headline)
                        Text([
                            "\(digest.sessionCount) \(digest.sessionCount == 1 ? "sesión" : "sesiones")",
                            digest.source == "scheduled" ? "Automático" : "Manual",
                            digest.usage?.costUsd.map { Money.usd($0) },
                        ].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                    .tag(digest.id)
                    .contextMenu {
                        Button("Copiar para compartir") { store.copy(.digest(digest, projectName: store.selectedProject?.name)) }
                        Button("Exportar a Obsidian") { store.export(digest: digest) }
                        Divider()
                        Button("Eliminar resumen…", role: .destructive) { store.pendingDeletion = .digest(digest) }
                    }
                }
            }
            Divider()
            Button {
                Task { await store.generateDigest() }
            } label: {
                if store.generatingDigest {
                    HStack { ProgressView().controlSize(.small); Text("Generando…") }
                } else {
                    Label("Generar resumen de los últimos 7 días", systemImage: "sparkles")
                }
            }
            .disabled(store.generatingDigest)
            .padding(8)
        }
    }
}

struct DigestDetailView: View {
    @Environment(AppStore.self) private var store
    let digest: WeeklyDigest

    var body: some View {
        let r = digest.result
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Semana \(digest.periodLabel)").font(.largeTitle.bold())
                    Text([
                        "\(digest.sessionCount) sesiones",
                        ModelName.pretty(digest.model),
                        digest.usage?.costUsd.map { "≈ \(Money.usd($0))" },
                    ].compactMap { $0 }.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                }

                Text(r.summary)
                    .font(.title3)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    .textSelection(.enabled)

                block("Requieren atención", "exclamationmark.triangle", r.attention) { a in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(a.task).bold()
                        Text("\(a.owner ?? "Sin responsable") · \(a.reason)").font(.callout).foregroundStyle(.secondary)
                    }
                }
                block("Foco para la siguiente semana", "scope", r.nextWeekFocus) { Text($0) }
                block("Avances", "star", r.highlights) { Text($0) }
                block("Decisiones", "checkmark.seal", r.decisions) { d in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(d.decision)
                        Text(d.session).font(.caption).foregroundStyle(.secondary)
                    }
                }
                block("Pendientes cerrados", "checkmark.circle", r.completed) { Text($0) }
                block("Riesgos", "exclamationmark.shield", r.risks) { x in
                    Text("\(x.description) (\(x.severity == "high" ? "alto" : x.severity == "medium" ? "medio" : "bajo"))")
                }
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
        }
        .toolbar {
            ShareToolbarButtons(
                copy: { store.copy(.digest(digest, projectName: store.selectedProject?.name)) },
                export: { store.export(digest: digest) }
            )
        }
    }

    @ViewBuilder
    private func block<Item: Hashable, Row: View>(
        _ title: String, _ icon: String, _ items: [Item], @ViewBuilder row: @escaping (Item) -> Row
    ) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("\(title) (\(items.count))", systemImage: icon).font(.headline)
                ForEach(items, id: \.self) { row($0).textSelection(.enabled) }
            }
        }
    }
}
