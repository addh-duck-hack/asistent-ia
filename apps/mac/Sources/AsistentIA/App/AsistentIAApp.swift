import AppKit
import SwiftUI

@main
struct AsistentIAApp: App {
    @State private var store: AppStore
    @State private var recorder: RecordingService
    /// Vive mientras la app; muestra el personaje al terminar de arrancar.
    private let companion: CompanionController
    @AppStorage(CompanionController.presenceKey) private var presence = CompanionController.Presence.character.rawValue

    init() {
        let store = AppStore()
        let recorder = RecordingService()
        _store = State(initialValue: store)
        _recorder = State(initialValue: recorder)
        companion = CompanionController(store: store, recorder: recorder)
    }

    var body: some Scene {
        // Window (no WindowGroup): una sola ventana principal; openWindow la trae
        // al frente en lugar de abrir otra.
        Window("Asistent IA", id: "main") {
            ContentView()
                .environment(store)
                .environment(recorder)
                .frame(minWidth: 1000, minHeight: 620)
                .captureWindowRouter()
        }

        Window("Grabar reunión", id: "recorder") {
            RecorderView()
                .environment(store)
                .environment(recorder)
                .captureWindowRouter()
        }
        .windowResizability(.contentSize)

        Window("Probar audio", id: "audio-test") {
            AudioTestView()
                .environment(recorder)
                .captureWindowRouter()
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
                .environment(store)
        }

        // El icono de la barra se quita cuando el personaje lo reemplaza (Ajustes → Personaje).
        MenuBarExtra("Asistent IA", systemImage: recorder.micProblem != nil ? "exclamationmark.triangle.fill"
                       : recorder.isRecording ? "record.circle.fill" : "waveform.badge.magnifyingglass",
                     isInserted: menuBarInserted) {
            AssistantMenuItems()
                .environment(store)
                .environment(recorder)
        }
    }

    private var menuBarInserted: Binding<Bool> {
        Binding(
            get: { (CompanionController.Presence(rawValue: presence) ?? .character).showsMenuBar },
            set: { inserted in
                // Si el usuario saca el icono de la barra (⌘-arrastrar), queda solo el personaje.
                if !inserted {
                    presence = CompanionController.Presence.character.rawValue
                } else if presence == CompanionController.Presence.character.rawValue {
                    presence = CompanionController.Presence.both.rawValue
                }
            }
        )
    }
}
