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
    }
}

private struct MenuBarContent: View {
    @Environment(AppStore.self) private var store
    @Environment(RecordingService.self) private var recorder
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Abrir Asistent IA") {
            openWindow(id: "main")
            NSApplication.shared.activate()
        }
        if recorder.isRecording {
            Button("Detener y analizar") {
                openWindow(id: "recorder")
                Task { await recorder.stopAndProcess() }
            }
        } else {
            Button("Grabar reunión…") {
                openWindow(id: "recorder")
                NSApplication.shared.activate()
            }
            .disabled(recorder.phase.isBusy)
            Button("Probar audio…") {
                openWindow(id: "audio-test")
                NSApplication.shared.activate()
            }
            .disabled(recorder.phase.isBusy)
        }
        Divider()
        SettingsLink { Text("Ajustes…") }
        Button("Salir") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
