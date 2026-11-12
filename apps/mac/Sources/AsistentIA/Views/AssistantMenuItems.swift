import AppKit
import SwiftUI

/// Abre ventanas y Ajustes desde fuera de una escena SwiftUI (el panel del personaje).
@MainActor
final class WindowRouter {
    static let shared = WindowRouter()

    /// Se captura con `.captureWindowRouter()` en una vista de una escena (o del panel; también funciona ahí).
    var openWindow: OpenWindowAction?
    /// Abre Ajustes (macOS 14+ ya no acepta el selector showSettingsWindow:).
    var openSettingsAction: OpenSettingsAction?

    func open(_ id: String) {
        if let openWindow {
            openWindow(id: id)
        } else if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == id }) {
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate()
    }

    func openSettings() {
        NSApp.activate()
        if let openSettingsAction {
            openSettingsAction()
        } else if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "com_apple_SwiftUI_Settings_window" }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    }
}

extension View {
    /// Guarda `openWindow` para que el personaje pueda abrir ventanas de la app.
    func captureWindowRouter() -> some View { modifier(CaptureWindowRouter()) }
}

private struct CaptureWindowRouter: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    func body(content: Content) -> some View {
        content.onAppear {
            WindowRouter.shared.openWindow = openWindow
            WindowRouter.shared.openSettingsAction = openSettings
        }
    }
}

/// Una acción del menú del asistente (barra superior o personaje).
struct AssistantAction: Identifiable {
    let id: String
    let title: String
    var systemImage: String?
    var enabled = true
    var separatorBefore = false
    var shortcut: Character?
    let perform: @MainActor () -> Void

    init(id: String, title: String, systemImage: String? = nil, enabled: Bool = true, separatorBefore: Bool = false,
         shortcut: Character? = nil, perform: @escaping @MainActor () -> Void) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.enabled = enabled
        self.separatorBefore = separatorBefore
        self.shortcut = shortcut
        self.perform = perform
    }
}

/// Las mismas acciones para la barra superior y para el personaje.
enum AssistantActions {
    /// `ask`: qué hacer con "Preguntar…" (el personaje abre su globo; la barra abre la app).
    @MainActor
    static func items(store: AppStore, recorder: RecordingService, ask: (@MainActor () -> Void)? = nil) -> [AssistantAction] {
        let router = WindowRouter.shared
        var items: [AssistantAction] = []
        items.append(.init(id: "open", title: "Abrir Asistent IA", systemImage: "macwindow") { router.open("main") })
        if !recorder.interrupted.isEmpty, !recorder.phase.isBusy {
            items.append(.init(id: "recover", title: "Recuperar grabación interrumpida…", systemImage: "arrow.counterclockwise") { router.open("recorder") })
        }
        if recorder.isRecording {
            items.append(.init(id: "stop", title: "Detener y analizar", systemImage: "stop.circle") {
                router.open("recorder")
                Task { await recorder.stopAndProcess() }
            })
            // La confirmación está en la ventana de grabación.
            items.append(.init(id: "cancel", title: "Cancelar grabación…", systemImage: "xmark.circle") { router.open("recorder") })
        } else {
            items.append(.init(id: "record", title: "Grabar reunión…", systemImage: "record.circle", enabled: !recorder.phase.isBusy) { router.open("recorder") })
            items.append(.init(id: "audio-test", title: "Probar audio…", systemImage: "waveform", enabled: !recorder.phase.isBusy) { router.open("audio-test") })
        }
        items.append(.init(id: "ask", title: "Preguntar…", systemImage: "bubble.left.and.text.bubble.right", enabled: store.hasBackend) {
            if let ask {
                ask()
            } else {
                store.startConversation()
                router.open("main")
            }
        })
        items.append(.init(id: "settings", title: "Ajustes…", systemImage: "gearshape", separatorBefore: true) { router.openSettings() })
        items.append(.init(id: "quit", title: "Salir", systemImage: "power", shortcut: "q") { NSApplication.shared.terminate(nil) })
        return items
    }
}

extension AppStore {
    /// Hay URL y token configurados (no garantiza que respondan).
    var hasBackend: Bool { !(Keychain.read(AppSettings.tokenAccount) ?? "").isEmpty }
}

/// Contenido del `MenuBarExtra`.
struct AssistantMenuItems: View {
    @Environment(AppStore.self) private var store
    @Environment(RecordingService.self) private var recorder

    var body: some View {
        let companion = CompanionController.shared
        if let companion, companion.isHiddenByUser {
            Button("Mostrar el personaje") { companion.show() }
            Text(companion.hiddenUntilDate.map { "Oculto hasta las \($0.formatted(date: .omitted, time: .shortened))" }
                 ?? "Oculto hasta reiniciar la app")
            Divider()
        }
        ForEach(AssistantActions.items(store: store, recorder: recorder)) { action in
            if action.separatorBefore { Divider() }
            if let key = action.shortcut {
                Button(action.title) { action.perform() }
                    .disabled(!action.enabled)
                    .keyboardShortcut(KeyEquivalent(key))
            } else {
                Button(action.title) { action.perform() }
                    .disabled(!action.enabled)
            }
        }
        EmptyView().captureWindowRouter()
    }
}
