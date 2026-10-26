import AppKit
import SwiftUI

@main
struct AsistentIAApp: App {
    @State private var store = AppStore()
    @State private var recorder = RecordingService()

    var body: some Scene {
        // Window (no WindowGroup): una sola ventana principal; openWindow la trae
        // al frente en lugar de abrir otra.
        Window("Asistent IA", id: "main") {
            ContentView()
                .environment(store)
                .frame(minWidth: 1000, minHeight: 620)
        }

        Window("Grabar reunión", id: "recorder") {
            RecorderView()
                .environment(store)
                .environment(recorder)
        }
        .windowResizability(.contentSize)

        Window("Probar audio", id: "audio-test") {
            AudioTestView()
                .environment(recorder)
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
                .environment(store)
        }

        MenuBarExtra("Asistent IA", systemImage: recorder.micProblem != nil ? "exclamationmark.triangle.fill"
                       : recorder.isRecording ? "record.circle.fill" : "waveform.badge.magnifyingglass") {
            MenuBarContent()
                .environment(store)
                .environment(recorder)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Panel de la barra superior: la misma vista de grabación que la ventana
/// (proyecto, título, nivel, voces; detener o cancelar) más accesos rápidos.
private struct MenuBarContent: View {
    @Environment(RecordingService.self) private var recorder
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            RecorderView()
            Divider()
            HStack(spacing: 14) {
                Button("Abrir Asistent IA") {
                    openWindow(id: "main")
                    NSApplication.shared.activate()
                }
                Button("Probar audio…") {
                    openWindow(id: "audio-test")
                    NSApplication.shared.activate()
                }
                .disabled(recorder.phase.isBusy)
                Spacer()
                SettingsLink { Text("Ajustes…") }
                Button("Salir") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .buttonStyle(.link)
            .font(.callout)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
        }
    }
}
