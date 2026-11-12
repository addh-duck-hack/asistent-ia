import AppKit
import SwiftUI

/// Abre ventanas y Ajustes desde fuera de una escena SwiftUI (el panel del personaje).
@MainActor
final class WindowRouter {
    static let shared = WindowRouter()

    /// Se captura con `.captureWindowRouter()` en una vista de una escena (o del panel; también funciona ahí).
    var openWindow: OpenWindowAction?

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
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}

extension View {
    /// Guarda `openWindow` para que el personaje pueda abrir ventanas de la app.
    func captureWindowRouter() -> some View { modifier(CaptureWindowRouter()) }
}

private struct CaptureWindowRouter: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear { WindowRouter.shared.openWindow = openWindow }
    }
}

/// Una acción del menú del asistente (barra superior o personaje).
struct AssistantAction: Identifiable {
    let id: String
    let title: String
    var enabled = true
    var separatorBefore = false
    var shortcut: Character?
    let perform: @MainActor () -> Void

    init(id: String, title: String, enabled: Bool = true, separatorBefore: Bool = false, shortcut: Character? = nil,
         perform: @escaping @MainActor () -> Void) {
        self.id = id
        self.title = title
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
        items.append(.init(id: "open", title: "Abrir Asistent IA") { router.open("main") })
        if !recorder.interrupted.isEmpty, !recorder.phase.isBusy {
            items.append(.init(id: "recover", title: "Recuperar grabación interrumpida…") { router.open("recorder") })
        }
        if recorder.isRecording {
            items.append(.init(id: "stop", title: "Detener y analizar") {
                router.open("recorder")
                Task { await recorder.stopAndProcess() }
            })
            // La confirmación está en la ventana de grabación.
            items.append(.init(id: "cancel", title: "Cancelar grabación…") { router.open("recorder") })
        } else {
            items.append(.init(id: "record", title: "Grabar reunión…", enabled: !recorder.phase.isBusy) { router.open("recorder") })
            items.append(.init(id: "audio-test", title: "Probar audio…", enabled: !recorder.phase.isBusy) { router.open("audio-test") })
        }
        items.append(.init(id: "ask", title: "Preguntar…", enabled: store.hasBackend) {
            if let ask {
                ask()
            } else {
                store.startConversation()
                router.open("main")
            }
        })
        items.append(.init(id: "settings", title: "Ajustes…", separatorBefore: true) { router.openSettings() })
        items.append(.init(id: "quit", title: "Salir", shortcut: "q") { NSApplication.shared.terminate(nil) })
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
        if let companion, !companion.isVisible {
            Divider()
            Button("Mostrar el personaje") { companion.show() }
        }
        EmptyView().captureWindowRouter()
    }
}

/// Menú de AppKit con las mismas acciones, para el clic en el personaje.
final class AssistantMenuItem: NSMenuItem {
    var perform: (@MainActor () -> Void)?

    @MainActor @objc func run(_ sender: Any?) { perform?() }
}

extension NSMenu {
    @MainActor
    static func assistant(_ actions: [AssistantAction]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for action in actions {
            if action.separatorBefore { menu.addItem(.separator()) }
            let item = AssistantMenuItem(title: action.title, action: #selector(AssistantMenuItem.run(_:)),
                                         keyEquivalent: action.shortcut.map(String.init) ?? "")
            item.target = item
            item.perform = action.perform
            item.isEnabled = action.enabled
            menu.addItem(item)
        }
        return menu
    }
}
