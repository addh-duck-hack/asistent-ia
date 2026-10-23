import AppKit
import SwiftUI

/// Ventana para grabar una reunión: datos → grabando → transcribiendo → listo.
struct RecorderView: View {
    @Environment(AppStore.self) private var store
    @Environment(RecordingService.self) private var recorder
    @Environment(\.openWindow) private var openWindow

    @State private var projectId: String?
    @State private var title = RecorderView.defaultTitle()
    @AppStorage("lastAnalysisDepth") private var depth: AnalysisDepth = .standard
    @AppStorage("recordingConsentAck") private var consent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch recorder.phase {
            case .idle:
                setup
            case let .recording(since):
                recording(since: since)
            case let .preparingModel(progress):
                working("Preparando el modelo de transcripción…",
                        detail: "Se descarga una sola vez (~626 MB).", progress: progress)
            case let .transcribing(progress):
                working("Transcribiendo en esta Mac…",
                        detail: "El audio no sale del equipo.", progress: progress)
            case .separatingVoices:
                working("Separando las voces de la llamada…",
                        detail: "Reconoce a quien ya identificaste antes. Todo en esta Mac.", progress: nil)
            case .uploading:
                working("Enviando la transcripción para análisis…", detail: nil, progress: nil)
            case let .finished(sessionId):
                finished(sessionId)
            case let .failed(message):
                failed(message)
            }
        }
        .padding(24)
        .frame(width: 460)
        .task {
            if store.projects.isEmpty { await store.loadProjects() }
            if projectId == nil { projectId = store.selectedProjectId ?? store.projects.first?.id }
        }
    }

    private var setup: some View {
        Group {
            Text("Grabar reunión").font(.title2.bold())
            Form {
                Picker("Proyecto", selection: $projectId) {
                    ForEach(store.projects) { Text($0.name).tag(Optional($0.id)) }
                }
                TextField("Título", text: $title)
                Picker("Nivel de análisis", selection: $depth) {
                    ForEach(AnalysisDepth.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Avisé a los participantes que la reunión se graba", isOn: $consent)
                LabeledContent("Micrófono") {
                    HStack {
                        Text(AudioDevices.selected()?.name ?? "Predeterminado (\(AudioDevices.defaultInput()?.name ?? "—"))")
                            .foregroundStyle(.secondary)
                        Button("Probar audio…") { openWindow(id: "audio-test") }
                    }
                }
            }
            .formStyle(.grouped)
            Text("Se graba tu micrófono y el audio de la llamada. Se transcribe en esta Mac y solo se envía el texto.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button {
                    guard let projectId else { return }
                    Task { await recorder.start(.init(projectId: projectId, title: title, depth: depth)) }
                } label: {
                    Label("Comenzar a grabar", systemImage: "record.circle")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(projectId == nil || title.trimmingCharacters(in: .whitespaces).isEmpty || !consent)
            }
        }
    }

    private func recording(since: Date) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "record.circle.fill").foregroundStyle(.red).symbolEffect(.pulse)
                Text(recorder.meta?.title ?? "Grabando").font(.title2.bold())
            }
            TimelineView(.periodic(from: since, by: 1)) { context in
                Text(Duration.seconds(context.date.timeIntervalSince(since)).formatted(.time(pattern: .hourMinuteSecond)))
                    .font(.system(size: 44, weight: .light, design: .monospaced))
            }
            LevelMeter(label: "Yo (\(recorder.micDeviceName))", level: recorder.micLevel)
            LevelMeter(label: "Llamada (audio del sistema)", level: recorder.systemLevel)
            if let problem = recorder.micProblem {
                HStack(alignment: .top) {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Spacer()
                    Button("Reiniciar micrófono") { recorder.restartMic() }
                }
                .font(.callout)
            } else if recorder.micRestarts > 0 {
                Text("El micrófono se reconectó \(recorder.micRestarts) \(recorder.micRestarts == 1 ? "vez" : "veces") (cambio de dispositivo).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let warning = recorder.warning {
                Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button(role: .destructive) {
                    Task { await recorder.stopAndProcess() }
                } label: {
                    Label("Detener y analizar", systemImage: "stop.circle")
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func working(_ title: String, detail: String?, progress: Double?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            if let progress {
                ProgressView(value: progress)
                Text(progress.formatted(.percent.precision(.fractionLength(0)))).font(.caption).monospacedDigit()
            } else {
                ProgressView().controlSize(.small)
            }
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func finished(_ sessionId: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Transcripción enviada", systemImage: "checkmark.circle.fill")
                .font(.title2.bold()).foregroundStyle(.green)
            Text("Claude está analizando la sesión; el resultado aparece en la ventana principal.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Nueva grabación") { title = Self.defaultTitle(); recorder.reset() }
                Spacer()
                Button("Ver sesión") {
                    Task { await store.show(sessionId: sessionId, projectId: projectId) }
                    openWindow(id: "main")
                    NSApplication.shared.activate()
                    recorder.reset()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func failed(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("No se pudo completar", systemImage: "exclamationmark.triangle.fill")
                .font(.title2.bold()).foregroundStyle(.red)
            Text(message).textSelection(.enabled).font(.callout)
            HStack {
                Button("Descartar") { recorder.reset() }
                Spacer()
                Button("Reintentar transcripción") { Task { await recorder.retry() } }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    static func defaultTitle() -> String {
        "Reunión \(Date.now.formatted(date: .abbreviated, time: .shortened))"
    }
}

private struct LevelMeter: View {
    let label: String
    let level: Float

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(level > 0.85 ? Color.orange : .green)
                        .frame(width: geo.size.width * CGFloat(level))
                        .animation(.linear(duration: 0.1), value: level)
                }
            }
            .frame(height: 6)
        }
    }
}
