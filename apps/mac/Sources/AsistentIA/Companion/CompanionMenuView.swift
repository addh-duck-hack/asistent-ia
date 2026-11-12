import SwiftUI

/// Menú propio del personaje: encabezado, acciones con icono y control de tamaño.
struct CompanionMenuView: View {
    let controller: CompanionController
    let actions: [AssistantAction]
    @AppStorage(CompanionController.scaleKey) private var scale = 1.0

    /// Acciones antes del primer separador (las principales) y el resto (ocultar, ajustes, salir).
    private var groups: (main: [AssistantAction], rest: [AssistantAction]) {
        let split = actions.firstIndex { $0.separatorBefore } ?? actions.endIndex
        return (Array(actions[..<split]), Array(actions[split...]))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            header
            Divider().padding(.vertical, 4)
            ForEach(groups.main) { MenuRow(action: $0) { controller.perform($0) } }
            Divider().padding(.vertical, 4)
            sizeControl
            ForEach(groups.rest) { action in
                if action.separatorBefore { Divider().padding(.vertical, 4) }
                MenuRow(action: action) { controller.perform($0) }
            }
        }
        .padding(6)
        .frame(width: 250)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        .padding(14) // espacio para la sombra dentro del panel transparente
        .fixedSize()
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(.yellow)
            Text(controller.character.name).font(.headline)
            Spacer()
            Text(controller.model.mood.label).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }

    private var sizeControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("Tamaño", systemImage: "arrow.up.left.and.arrow.down.right")
                Spacer()
                Text("\(Int((scale * 100).rounded())) %").monospacedDigit().foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                stepButton("minus", delta: -0.1)
                Slider(value: $scale, in: CompanionGeometry.minScale ... CompanionGeometry.maxScale)
                    .controlSize(.small)
                stepButton("plus", delta: 0.1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private func stepButton(_ symbol: String, delta: Double) -> some View {
        Button { scale = CompanionGeometry.clampScale(scale + delta) } label: {
            Image(systemName: symbol).frame(width: 18, height: 18)
        }
        .buttonStyle(.borderless)
        .disabled(delta < 0 ? scale <= CompanionGeometry.minScale : scale >= CompanionGeometry.maxScale)
    }
}

/// Fila del menú: un botón (los gestos de toque de SwiftUI ignoran el primer clic en un panel
/// que no activa la app; los botones sí lo reciben) con icono, título y atajo; se resalta al pasar el cursor.
private struct MenuRow: View {
    let action: AssistantAction
    let perform: (AssistantAction) -> Void

    var body: some View {
        Button { perform(action) } label: {
            HStack(spacing: 8) {
                Image(systemName: action.systemImage ?? "circle")
                    .frame(width: 18)
                    .opacity(action.systemImage == nil ? 0 : 1)
                Text(action.title)
                Spacer()
                if let key = action.shortcut {
                    Text("⌘\(String(key).uppercased())")
                }
            }
        }
        .buttonStyle(MenuRowStyle())
        .disabled(!action.enabled)
    }
}

private struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MenuRowBody(configuration: configuration)
    }
}

private struct MenuRowBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    var body: some View {
        let highlighted = enabled && (hovering || configuration.isPressed)
        configuration.label
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(highlighted ? .white : .primary)
            .background(highlighted ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6))
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}
