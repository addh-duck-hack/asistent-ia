import SwiftUI

/// Ventana "Probar audio": verificar micrófono y audio de la llamada antes de una reunión.
struct AudioTestView: View {
    @Environment(RecordingService.self) private var recorder
    @State private var model = AudioTestModel()

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 18) {
            Text("Probar audio").font(.title2.bold())

            if recorder.phase.isBusy {
                Label("Hay una grabación en curso; la prueba se activa cuando termine.", systemImage: "record.circle")
                    .foregroundStyle(.secondary)
            } else {
                micSection(model: model)
                Divider()
                systemSection
                Divider()
                Label {
                    Text("Deja la cancelación de eco desactivada: en algunas Macs deja el micrófono en silencio, y el eco de las bocinas ya se elimina al unir las pistas. Elige aquí el mismo micrófono que usas en Teams.")
                } icon: {
                    Image(systemName: "headphones")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(width: 520)
        .task { if !recorder.phase.isBusy { await model.start() } }
        .onDisappear { Task { await model.stop() } }
    }

    private func micSection(model: AudioTestModel) -> some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("1. Tu micrófono").font(.headline)
                Spacer()
                CheckBadge(check: model.micCheck, okText: "Se escucha tu voz", waitingText: "Habla para probar")
            }
            Picker("Micrófono", selection: $model.selectedUID) {
                Text("Predeterminado del sistema (\(model.defaultDeviceName))").tag("")
                ForEach(model.devices) { Text($0.name).tag($0.uid) }
            }
            Toggle("Cancelación de eco (experimental)", isOn: $model.voiceProcessing)
            Meter(level: model.micLevel)
            if let note = model.note {
                Text(note).font(.caption).foregroundStyle(.orange)
            }
            HStack(alignment: .top) {
                Button {
                    Task { await model.recordSample() }
                } label: {
                    Label("Grabar 5 s y transcribir", systemImage: "waveform.badge.mic")
                }
                .disabled(model.sample == .transcribing || { if case .recording = model.sample { true } else { false } }())
                Button("Actualizar lista") { model.refreshDevices() }
                    .buttonStyle(.link)
            }
            sampleResult(model.sample)
        }
    }

    @ViewBuilder
    private func sampleResult(_ sample: AudioTestModel.Sample) -> some View {
        switch sample {
        case .idle:
            EmptyView()
        case let .recording(left):
            Label("Grabando… habla ahora (\(left) s)", systemImage: "record.circle.fill").foregroundStyle(.red)
        case .transcribing:
            HStack { ProgressView().controlSize(.small); Text("Transcribiendo…") }
        case let .result(text):
            Label("“\(text)”", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .textSelection(.enabled)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }

    private var systemSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("2. Audio de la llamada").font(.headline)
                Spacer()
                CheckBadge(check: model.systemCheck, okText: "Se capta el audio", waitingText: "Reproduce algo")
            }
            Text("Reproduce la frase de prueba (o cualquier video) y revisa que el medidor se mueva. Debe sonar por donde escuchas la llamada.")
                .font(.caption).foregroundStyle(.secondary)
            Meter(level: model.systemLevel)
            Button {
                model.playTestPhrase()
            } label: {
                Label("Reproducir frase de prueba", systemImage: "speaker.wave.2")
            }
        }
    }
}

private struct CheckBadge: View {
    let check: AudioTestModel.Check
    let okText: String
    let waitingText: String

    var body: some View {
        switch check {
        case .waiting:
            Label(waitingText, systemImage: "circle.dotted").foregroundStyle(.secondary)
        case .ok:
            Label(okText, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case let .problem(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 300, alignment: .trailing)
        }
    }
}

struct Meter: View {
    let level: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(level > 0.85 ? Color.orange : .green)
                    .frame(width: geo.size.width * CGFloat(level))
                    .animation(.linear(duration: 0.1), value: level)
            }
        }
        .frame(height: 8)
    }
}
