import SwiftUI

/// Columna central de Registro: lo que no se pudo procesar y se puede reenviar.
struct FailedSessionsListView: View {
    @Environment(AppStore.self) private var store
    @Environment(RecordingService.self) private var recorder
    @Environment(\.openWindow) private var openWindow

    private var recorderError: String? {
        if case let .failed(message) = recorder.phase { message } else { nil }
    }

    var body: some View {
        @Bindable var store = store
        List(selection: $store.selectedFailedSessionId) {
            Section {
                if let problem = store.logsLoadError {
                    Label(problem, systemImage: "exclamationmark.icloud")
                        .font(.callout).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else if store.failedSessions.isEmpty {
                    Text("Ninguna: todos los análisis terminaron bien.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(store.failedSessions) { session in
                    FailedSessionRow(session: session)
                        .tag(session.id)
                        .contextMenu {
                            Button("Reenviar a analizar") { Task { await store.retry(failed: session) } }
                            Button("Abrir sesión") { Task { await store.show(sessionId: session.id, projectId: session.projectId) } }
                            Divider()
                            Button("Eliminar sesión…", role: .destructive) { store.pendingDeletion = .session(session) }
                        }
                }
                if !store.failedSessions.isEmpty {
                    Text("La transcripción ya está en el servidor: al reenviar, solo se vuelve a pedir el análisis a Claude.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .selectionDisabled()
                }
            } header: {
                Text("No se pudieron analizar")
            }

            if recorderError != nil || !recorder.interrupted.isEmpty {
                Section {
                    if let recorderError {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(recorder.meta?.title ?? "Última grabación").font(.headline).lineLimit(1)
                            Text(recorderError).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                            Button("Reintentar transcribir y enviar") { Task { await recorder.retry() } }
                                .disabled(recorder.phase.isBusy)
                        }
                        .padding(.vertical, 4)
                    }
                    ForEach(recorder.interrupted) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.manifest.meta.title).font(.headline).lineLimit(1)
                            Text("\(item.manifest.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(Duration.seconds(item.seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))")
                                .font(.caption).foregroundStyle(.secondary)
                            if item.needsProject {
                                Button("Elegir proyecto y enviar…") { openWindow(id: "recorder") }
                            } else {
                                Button("Transcribir y enviar") {
                                    openWindow(id: "recorder")
                                    Task { await recorder.recover(item) }
                                }
                                .disabled(recorder.phase.isBusy)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("Grabaciones sin subir (en esta Mac)")
                }
            }
        }
        .navigationTitle("Registro")
        .toolbar {
            Button {
                Task { await store.retryAllFailed() }
            } label: {
                Label("Reenviar todas", systemImage: "arrow.clockwise.circle")
            }
            .help("Vuelve a pedir el análisis de todas las sesiones que fallaron")
            .disabled(store.failedSessions.isEmpty || store.retryingFailed)
        }
        .refreshable { await store.loadLogs() }
        .task {
            recorder.scanInterrupted()
            await store.loadLogs()
        }
    }
}

private struct FailedSessionRow: View {
    @Environment(AppStore.self) private var store
    let session: Session

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(session.title).font(.headline).lineLimit(1)
                Spacer()
                Button("Reenviar") { Task { await store.retry(failed: session) } }
                    .controlSize(.small)
            }
            Text([session.projectName, session.date.formatted(date: .abbreviated, time: .shortened), session.depth?.label]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
            if let error = session.error {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(3)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Detalle de Registro: historial de errores, para copiar o guardar.
struct ErrorLogView: View {
    @Environment(AppStore.self) private var store
    @State private var confirmingClear = false

    var body: some View {
        @Bindable var store = store
        let lines = store.logLines
        VStack(spacing: 0) {
            HStack {
                if let id = store.selectedFailedSessionId, let session = store.failedSessions.first(where: { $0.id == id }) {
                    Text("Errores de «\(session.title)»").font(.headline)
                    Button("Ver todos") { store.selectedFailedSessionId = nil }.buttonStyle(.link)
                } else {
                    Text("Historial de errores").font(.headline)
                }
                Spacer()
                Toggle("Mostrar resueltos", isOn: $store.showResolvedLogs).toggleStyle(.checkbox)
            }
            .padding(.horizontal).padding(.vertical, 10)
            Divider()
            if lines.isEmpty {
                ContentUnavailableView("Sin errores", systemImage: "checkmark.seal",
                                       description: Text("Aquí quedan los fallos del análisis y de las grabaciones."))
            } else {
                List(lines) { line in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(line.date.formatted(date: .abbreviated, time: .standard)).font(.caption.monospacedDigit())
                            Text(line.origin.rawValue)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.secondary.opacity(0.15), in: Capsule())
                            if line.resolved {
                                Label("Resuelto", systemImage: "checkmark.circle.fill").font(.caption2).foregroundStyle(.green)
                            }
                            Text("«\(line.title)»").font(.caption.weight(.semibold)).lineLimit(1)
                        }
                        .foregroundStyle(.secondary)
                        Text(line.message)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .foregroundStyle(line.resolved ? .secondary : .primary)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .toolbar {
            Button { store.copyLogs() } label: { Label("Copiar registro", systemImage: "doc.on.doc") }
                .help("Copiar registro").disabled(lines.isEmpty)
            Button { store.saveLogs() } label: { Label("Guardar registro…", systemImage: "square.and.arrow.down") }
                .help("Guardar el registro en un archivo .txt").disabled(lines.isEmpty)
            Menu {
                Button("Borrar los resueltos") { Task { await store.clearLogs(onlyResolved: true) } }
                Button("Borrar todo el historial…", role: .destructive) { confirmingClear = true }
            } label: {
                Label("Limpiar", systemImage: "trash")
            }
            .help("Limpiar el historial")
        }
        .confirmationDialog("¿Borrar todo el historial de errores?", isPresented: $confirmingClear) {
            Button("Borrar", role: .destructive) { Task { await store.clearLogs(onlyResolved: false) } }
        } message: {
            Text("Se borra del servidor y de esta Mac. Las sesiones con error siguen en la lista para reenviarse.")
        }
    }
}
