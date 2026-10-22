import AppKit
import SwiftUI

@main
struct AsistentIAApp: App {
    @State private var store = AppStore()

    var body: some Scene {
        WindowGroup("Asistent IA", id: "main") {
            ContentView()
                .environment(store)
                .frame(minWidth: 1000, minHeight: 620)
        }

        Settings {
            SettingsView()
                .environment(store)
        }

        MenuBarExtra("Asistent IA", systemImage: "waveform.badge.magnifyingglass") {
            MenuBarContent()
                .environment(store)
        }
    }
}

private struct MenuBarContent: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Abrir Asistent IA") {
            openWindow(id: "main")
            NSApplication.shared.activate()
        }
        // Fase 2: grabar / detener reunión.
        Button("Grabar reunión (Fase 2)") {}.disabled(true)
        Divider()
        SettingsLink { Text("Ajustes…") }
        Button("Salir") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
