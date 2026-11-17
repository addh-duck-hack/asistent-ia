import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension CompanionMood {
    var systemImage: String {
        switch self {
        case .idle: "leaf"
        case .listening: "ear"
        case .thinking: "brain"
        case .talking: "bubble.left"
        case .happy: "party.popper"
        case .sad: "cloud.rain"
        case .alert: "exclamationmark.bubble"
        case .sleeping: "moon.zzz"
        }
    }

    /// Cuándo se ve este estado.
    var detail: String {
        switch self {
        case .idle: "Reposo: lo que hace mientras no pasa nada. Con varias animaciones, va cambiando entre ellas."
        case .listening: "Mientras grabas una reunión o tienes abierto su chat."
        case .thinking: "Mientras se transcribe y analiza la reunión, o mientras busca una respuesta."
        case .talking: "Cuando te muestra un aviso."
        case .happy: "Cuando se crea la sesión y cuando el análisis está listo."
        case .sad: "Cuando algo falla."
        case .alert: "Cuando hay un problema con el micrófono o una grabación interrumpida."
        case .sleeping: CompanionController.sleepDescription(minutes: CompanionController.sleepMinutes) + " Se cambia aquí abajo o en Ajustes → Personaje."
        }
    }
}

extension AnimationSlot {
    var systemImage: String {
        switch self {
        case let .mood(mood): mood.systemImage
        case let .reaction(reaction): reaction.systemImage
        }
    }

    var detail: String {
        switch self {
        case let .mood(mood): mood.detail
        case let .reaction(reaction): reaction.detail
        }
    }

    /// Los estados y arrastrar se repiten; el resto se reproduce una vez.
    var loops: Bool {
        switch self {
        case .mood: true
        case let .reaction(reaction): reaction.loops
        }
    }
}

/// Ventana "Animaciones del personaje": qué animación hace en cada estado, al hacer clic
/// en cada zona y por su cuenta; biblioteca de archivos y opciones del personaje.
struct CharacterAnimationsView: View {
    enum Pane: Hashable, RawRepresentable {
        case slot(AnimationSlot)
        case library
        case options

        /// Texto para recordar el último apartado abierto ("mood:idle", "reaction:head", "library", "options").
        var rawValue: String {
            switch self {
            case let .slot(.mood(mood)): "mood:\(mood.rawValue)"
            case let .slot(.reaction(reaction)): "reaction:\(reaction.rawValue)"
            case .library: "library"
            case .options: "options"
            }
        }

        init?(rawValue: String) {
            let parts = rawValue.split(separator: ":", maxSplits: 1).map(String.init)
            switch (parts.first, parts.count > 1 ? parts[1] : "") {
            case ("library", _): self = .library
            case ("options", _): self = .options
            case let ("mood", name):
                guard let mood = CompanionMood(rawValue: name) else { return nil }
                self = .slot(.mood(mood))
            case let ("reaction", name):
                guard let reaction = CompanionReaction(rawValue: name) else { return nil }
                self = .slot(.reaction(reaction))
            default: return nil
            }
        }
    }

    @AppStorage(CharacterLibrary.selectedKey) private var characterId = CharacterPack.builtInId
    @AppStorage("animationsPane") private var savedPane = Pane.library.rawValue
    @State private var pane: Pane?
    @State private var characters = CharacterLibrary.installed()
    @State private var files: [String] = []
    @State private var status: String?

    var body: some View {
        if let controller = CompanionController.shared {
            NavigationSplitView {
                sidebar(controller)
                    .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
            } detail: {
                VStack(spacing: 0) {
                    if !controller.character.isEditable {
                        ReadOnlyBanner(isBuiltIn: controller.character.isBuiltIn)
                    }
                    detail(controller)
                    if let status {
                        Divider()
                        Text(status).font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16).padding(.vertical, 6)
                    }
                }
            }
            .navigationTitle("Animaciones")
            .toolbar {
                ToolbarItem {
                    Button("Detener", systemImage: "stop.fill") { controller.stopPreview() }
                        .disabled(controller.model.gesture == nil && controller.model.previewMood == nil)
                        .help("Detener la animación que se está probando")
                }
            }
            .task(id: controller.character.id) {
                characters = CharacterLibrary.installed()
                status = nil
                refreshFiles(controller)
            }
            .onAppear {
                if pane == nil { pane = Pane(rawValue: savedPane) ?? .library }
                controller.showsZones = pane == .options
            }
            .onChange(of: pane) {
                controller.showsZones = pane == .options
                if let pane { savedPane = pane.rawValue }
            }
            .onDisappear {
                controller.showsZones = false
                controller.stopPreview()
            }
            .frame(minWidth: 760, minHeight: 500)
        } else {
            ContentUnavailableView("El personaje todavía no está listo", systemImage: "hourglass")
                .frame(minWidth: 760, minHeight: 500)
        }
    }

    private func sidebar(_ controller: CompanionController) -> some View {
        let pack = controller.character.pack
        return VStack(spacing: 0) {
            characterMenu(controller)
            list(pack)
        }
    }

    /// Personaje que se muestra y se edita (elegir otro lo cambia también en el escritorio).
    private func characterMenu(_ controller: CompanionController) -> some View {
        Menu {
            ForEach(characters) { character in
                Button {
                    characterId = character.id
                } label: {
                    if character.id == controller.character.id {
                        Label(character.name, systemImage: "checkmark")
                    } else {
                        Text(character.name)
                    }
                }
            }
        } label: {
            Label(controller.character.name, systemImage: "person.crop.square")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .help("Personaje que se muestra y se edita")
    }

    private func list(_ pack: CharacterPack) -> some View {
        List(selection: $pane) {
            Section("Personaje") {
                Label("Biblioteca", systemImage: "square.stack.3d.up")
                    .badge(files.count)
                    .tag(Pane.library)
                Label("Opciones", systemImage: "slider.horizontal.3")
                    .tag(Pane.options)
            }
            Section("Estados") {
                ForEach(CompanionMood.allCases, id: \.self) { row(.mood($0), pack: pack) }
            }
            Section("Al hacer clic") {
                ForEach(CompanionReaction.clicks, id: \.self) { row(.reaction($0), pack: pack) }
            }
            Section("Por su cuenta") {
                ForEach(CompanionReaction.automatic, id: \.self) { row(.reaction($0), pack: pack) }
            }
        }
    }

    private func row(_ slot: AnimationSlot, pack: CharacterPack) -> some View {
        Label(slot.label, systemImage: slot.systemImage)
            .badge(pack.clips(in: slot).count)
            .tag(Pane.slot(slot))
    }

    @ViewBuilder
    private func detail(_ controller: CompanionController) -> some View {
        switch pane {
        case let .slot(slot):
            SlotPane(controller: controller, slot: slot, files: files) { importFiles(into: slot, controller: controller) }
                .id(slot)
        case .library:
            LibraryPane(controller: controller, files: files,
                        importFiles: { importFiles(into: nil, controller: controller) },
                        delete: { delete($0, controller: controller) })
        case .options:
            OptionsPane(controller: controller, characterId: controller.character.id)
                .id(controller.character.id)
        case nil:
            ContentUnavailableView("Elige un apartado", systemImage: "sidebar.left")
        }
    }

    // MARK: Archivos

    private func refreshFiles(_ controller: CompanionController) {
        if let folder = controller.character.folder {
            files = (try? CharacterImporter.modelFiles(in: folder)) ?? []
        } else {
            files = controller.character.pack.files.sorted()
        }
    }

    /// Copia archivos elegidos a la carpeta del personaje y, si se pidió desde un apartado, los asigna a él.
    private func importFiles(into slot: AnimationSlot?, controller: CompanionController) {
        guard controller.character.isEditable, let folder = controller.character.folder else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = CharacterImporter.modelExtensions.sorted().compactMap { UTType(filenameExtension: $0) }
        panel.prompt = "Agregar"
        panel.message = "Elige los .usdz de las animaciones (con el mismo esqueleto que el personaje)"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        do {
            let replaced = panel.urls.contains { files.contains($0.lastPathComponent) }
            let added = try CharacterLibrary.addAnimations(panel.urls, to: folder)
            if let slot {
                controller.updatePack { pack in
                    var list = pack.clips(in: slot)
                    for file in added where !list.contains(where: { $0.file == file }) { list.append(ClipSource(file: file)) }
                    pack.setClips(list, in: slot)
                }
            }
            // Si se reemplazó un archivo que ya estaba cargado, hay que volver a leerlo de disco.
            if replaced { controller.reloadCharacter() }
            refreshFiles(controller)
            let count = added.count == 1 ? "1 animación" : "\(added.count) animaciones"
            status = slot.map { "✅ \(count) en «\($0.label)»." } ?? "✅ \(count) en la biblioteca. Asígnalas a un estado o a una reacción para usarlas."
        } catch {
            status = "❌ \(error.localizedDescription)"
        }
    }

    /// Manda el archivo a la Papelera y lo quita de todos los apartados.
    private func delete(_ file: String, controller: CompanionController) {
        guard controller.character.isEditable, let folder = controller.character.folder else { return }
        controller.updatePack { $0.removeFile(file) }
        do {
            try FileManager.default.trashItem(at: folder.appending(path: file), resultingItemURL: nil)
            status = "«\(file)» se movió a la Papelera."
        } catch {
            status = "❌ \(error.localizedDescription)"
        }
        refreshFiles(controller)
    }
}

private struct ReadOnlyBanner: View {
    let isBuiltIn: Bool

    var body: some View {
        Label(isBuiltIn
            ? "El pato integrado trae sus animaciones fijas: puedes probarlas, pero no cambiarlas. Importa un personaje propio en Ajustes → Personaje para agregarle animaciones."
            : "Este personaje viene con la app y no se puede modificar; puedes probar sus animaciones.",
            systemImage: "lock")
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.yellow.opacity(0.15))
    }
}

private struct PaneHeader: View {
    let title: String
    let systemImage: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: systemImage).font(.title2.bold())
            Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Un estado o una reacción

private struct SlotPane: View {
    let controller: CompanionController
    let slot: AnimationSlot
    let files: [String]
    let importFiles: () -> Void

    var body: some View {
        let pack = controller.character.pack
        let clips = pack.clips(in: slot)
        let editable = controller.character.isEditable
        Form {
            Section {
                PaneHeader(title: slot.label, systemImage: slot.systemImage, detail: slot.detail)
            }
            Section("Animaciones") {
                if clips.isEmpty {
                    emptyText(pack)
                }
                ForEach(Array(clips.enumerated()), id: \.offset) { index, clip in
                    ClipRow(controller: controller, clip: clip, loops: slot.loops, editable: editable,
                            update: { new in replace(at: index, with: new) },
                            remove: { replace(at: index, with: nil) })
                }
                if editable {
                    addMenu(clips)
                }
                if clips.count > 1 {
                    Text(slot.loops ? "Con varias animaciones va alternando entre ellas." : "Con varias animaciones elige una al azar cada vez, sin repetir la anterior.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            extras(pack, editable: editable)
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func emptyText(_ pack: CharacterPack) -> some View {
        switch slot {
        case let .mood(mood):
            if let resolved = pack.resolvedMood(for: mood) {
                Label("Sin animación propia: usa la de «\(resolved.label)».", systemImage: "arrow.turn.down.right")
                    .foregroundStyle(.orange)
            } else {
                Label("Sin animación.", systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
        case .reaction(.head), .reaction(.body), .reaction(.feet):
            Text("Sin animación: el clic en esta zona solo abre el menú.").foregroundStyle(.secondary)
        case .reaction:
            Text("Sin animación: no hace nada en este momento.").foregroundStyle(.secondary)
        }
    }

    private func addMenu(_ clips: [ClipSource]) -> some View {
        let unused = files.filter { file in !clips.contains { $0.file == file } }
        return Menu {
            ForEach(unused, id: \.self) { file in
                Button((file as NSString).deletingPathExtension) {
                    controller.updatePack { $0.setClips($0.clips(in: slot) + [ClipSource(file: file)], in: slot) }
                }
            }
            if !unused.isEmpty { Divider() }
            Button("Importar archivos .usdz…", action: importFiles)
        } label: {
            Label("Agregar animación", systemImage: "plus")
        }
        .fixedSize()
    }

    @ViewBuilder
    private func extras(_ pack: CharacterPack, editable: Bool) -> some View {
        switch slot {
        case let .mood(mood):
            Section {
                if mood != .idle {
                    Picker("Si no tiene animación, usa la de", selection: fallback(for: mood)) {
                        Text("Tranquilo").tag(CompanionMood.idle)
                        ForEach(CompanionMood.allCases.filter { $0 != mood && $0 != .idle }, id: \.self) { Text($0.label).tag($0) }
                    }
                    .disabled(!editable)
                }
                if mood == .sleeping { SleepAfterPicker() }
                Button("Probar el estado «\(mood.label)»", systemImage: "play.circle") { controller.preview(mood) }
            }
        case .reaction(.random):
            Section("Cada cuánto") {
                Toggle("Hacer gestos al azar", isOn: randomEnabled)
                Stepper("Como mínimo cada \(Int(pack.behavior.randomMin)) segundos", value: randomMin, in: 5 ... 3600, step: 5)
                Stepper("Como máximo cada \(Int(pack.behavior.randomMax)) segundos", value: randomMax, in: 5 ... 3600, step: 5)
                Text("Solo mientras está tranquilo: nunca durante una grabación, con un aviso a la vista o dormido.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!editable)
        case .reaction(.head), .reaction(.body), .reaction(.feet):
            Section {
                Text("El tamaño de las zonas de cabeza y pies, y si el clic además abre el menú, se ajustan en **Opciones**.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .reaction:
            EmptyView()
        }
    }

    private func replace(at index: Int, with clip: ClipSource?) {
        controller.updatePack { pack in
            var list = pack.clips(in: slot)
            guard list.indices.contains(index) else { return }
            if let clip { list[index] = clip } else { list.remove(at: index) }
            pack.setClips(list, in: slot)
        }
    }

    private func fallback(for mood: CompanionMood) -> Binding<CompanionMood> {
        let controller = controller
        return Binding(
            get: { controller.character.pack.fallbacks[mood] ?? .idle },
            set: { new in controller.updatePack { $0.fallbacks[mood] = new } }
        )
    }

    private var randomEnabled: Binding<Bool> {
        let controller = controller
        return Binding(get: { controller.character.pack.behavior.randomEnabled },
                       set: { new in controller.updatePack { $0.behavior.randomEnabled = new } })
    }

    private var randomMin: Binding<Double> {
        let controller = controller
        return Binding(get: { controller.character.pack.behavior.randomMin },
                       set: { new in
                           controller.updatePack {
                               $0.behavior.randomMin = new
                               $0.behavior.randomMax = max($0.behavior.randomMax, new)
                           }
                       })
    }

    private var randomMax: Binding<Double> {
        let controller = controller
        return Binding(get: { controller.character.pack.behavior.randomMax },
                       set: { new in
                           controller.updatePack {
                               $0.behavior.randomMax = new
                               $0.behavior.randomMin = min($0.behavior.randomMin, new)
                           }
                       })
    }
}

/// Una animación asignada: probar, velocidad, recorte y quitar.
private struct ClipRow: View {
    static let speeds: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    let controller: CompanionController
    let clip: ClipSource
    let loops: Bool
    let editable: Bool
    let update: (ClipSource) -> Void
    let remove: () -> Void

    @State private var trimming = false
    @State private var start: Double?
    @State private var end: Double?

    var body: some View {
        HStack(spacing: 10) {
            Button {
                controller.preview(clip, loopingFor: loops ? 6 : nil)
            } label: {
                Image(systemName: controller.model.gesture?.clip == clip ? "play.circle.fill" : "play.circle").font(.title3)
            }
            .buttonStyle(.borderless)
            .help("Probar en el personaje")
            VStack(alignment: .leading, spacing: 1) {
                Text(clip.name).lineLimit(1).truncationMode(.middle)
                if let start = clip.start, let end = clip.end {
                    Text("Recorte: de \(start.formatted()) s a \(end.formatted()) s").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if editable {
                Picker("Velocidad", selection: speed) {
                    ForEach(speedOptions, id: \.self) { Text("\($0.formatted()) ×").tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .help("Velocidad de la animación")
                Button {
                    start = clip.start
                    end = clip.end
                    trimming = true
                } label: {
                    Image(systemName: "scissors")
                }
                .buttonStyle(.borderless)
                .help("Usar solo una parte de la animación")
                .popover(isPresented: $trimming, arrowEdge: .bottom) { trimEditor }
                Button(action: remove) {
                    Image(systemName: "minus.circle").foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .help("Quitar de este apartado (el archivo se queda en la biblioteca)")
            }
        }
    }

    /// Las velocidades de la lista y, si el archivo trae otra, también esa.
    private var speedOptions: [Double] {
        Self.speeds.contains(clip.playbackSpeed) ? Self.speeds : (Self.speeds + [clip.playbackSpeed]).sorted()
    }

    private var speed: Binding<Double> {
        Binding(get: { clip.playbackSpeed },
                set: { new in
                    var changed = clip
                    changed.speed = new == 1 ? nil : new
                    update(changed)
                })
    }

    private var trimEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recortar «\(clip.name)»").font(.headline)
            Text("Usa solo un tramo de la animación, en segundos. Sirve para quitar el principio o el final de un clip largo.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("Inicio", value: $start, format: .number).frame(width: 70)
                Text("a")
                TextField("Fin", value: $end, format: .number).frame(width: 70)
                Text("segundos")
            }
            HStack {
                Button("Quitar recorte") {
                    var changed = clip
                    changed.start = nil
                    changed.end = nil
                    update(changed)
                    trimming = false
                }
                .disabled(clip.start == nil && clip.end == nil)
                Spacer()
                Button("Aplicar") {
                    var changed = clip
                    changed.start = max(start ?? 0, 0)
                    changed.end = end
                    update(changed)
                    trimming = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!((end ?? 0) > max(start ?? 0, 0)))
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}

// MARK: Biblioteca

private struct LibraryPane: View {
    let controller: CompanionController
    let files: [String]
    let importFiles: () -> Void
    let delete: (String) -> Void

    @State private var pendingDelete: String?

    var body: some View {
        let character = controller.character
        let pack = character.pack
        let editable = character.isEditable
        Form {
            Section {
                PaneHeader(title: "Biblioteca", systemImage: "square.stack.3d.up",
                           detail: "Todos los archivos de animación del personaje. Agrega aquí los que exportes y asígnalos a un estado o a una reacción; un mismo archivo puede usarse en varios.")
                if editable {
                    HStack {
                        Button("Importar animaciones…", systemImage: "plus", action: importFiles)
                        Button("Mostrar en Finder", systemImage: "folder") {
                            if let folder = character.folder { NSWorkspace.shared.open(folder) }
                        }
                    }
                }
            }
            Section(files.isEmpty ? "Sin archivos" : "\(files.count) archivos") {
                ForEach(files, id: \.self) { file in
                    row(file, pack: pack, editable: editable)
                }
            }
            Section {
                Text("Cada animación es un `.usdz` con el **mismo esqueleto** que el personaje (en Mixamo: el mismo personaje, una descarga por animación, convertida con Blender). Si importas un archivo con un nombre que ya existe, lo reemplaza.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("¿Eliminar «\(pendingDelete ?? "")»?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Mover a la Papelera", role: .destructive) {
                if let file = pendingDelete { delete(file) }
                pendingDelete = nil
            }
        } message: {
            Text("Se quita de todos los apartados donde se usa y el archivo va a la Papelera.")
        }
    }

    private func row(_ file: String, pack: CharacterPack, editable: Bool) -> some View {
        let clip = ClipSource(file: file)
        let used = pack.slots(using: file)
        let isBase = pack.baseFile == file
        return HStack(spacing: 10) {
            Button {
                controller.preview(clip, loopingFor: 6)
            } label: {
                Image(systemName: controller.model.gesture?.clip == clip ? "play.circle.fill" : "play.circle").font(.title3)
            }
            .buttonStyle(.borderless)
            .help("Probar en el personaje")
            VStack(alignment: .leading, spacing: 1) {
                Text(clip.name).lineLimit(1).truncationMode(.middle)
                if used.isEmpty {
                    Text(isBase ? "Modelo base · sin asignar" : "Sin asignar").font(.caption).foregroundStyle(.orange)
                } else {
                    Text((isBase ? "Modelo base · " : "") + used.map(\.label).joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            if editable {
                Menu("Asignar") {
                    Section("Estados") {
                        ForEach(CompanionMood.allCases, id: \.self) { toggle(file, in: .mood($0), used: used) }
                    }
                    Section("Al hacer clic") {
                        ForEach(CompanionReaction.clicks, id: \.self) { toggle(file, in: .reaction($0), used: used) }
                    }
                    Section("Por su cuenta") {
                        ForEach(CompanionReaction.automatic, id: \.self) { toggle(file, in: .reaction($0), used: used) }
                    }
                }
                .fixedSize()
                Button {
                    pendingDelete = file
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(isBase)
                .help(isBase ? "Es el modelo base del personaje: no se puede eliminar" : "Eliminar el archivo")
            }
        }
    }

    /// Entrada del menú "Asignar": marca o desmarca el archivo en un apartado.
    private func toggle(_ file: String, in slot: AnimationSlot, used: [AnimationSlot]) -> some View {
        let isOn = used.contains(slot)
        return Button {
            controller.updatePack { pack in
                var list = pack.clips(in: slot)
                if isOn { list.removeAll { $0.file == file } } else { list.append(ClipSource(file: file)) }
                pack.setClips(list, in: slot)
            }
        } label: {
            if isOn { Label(slot.label, systemImage: "checkmark") } else { Text(slot.label) }
        }
    }
}

// MARK: Opciones

/// Cuánto tiempo sin actividad espera el personaje para dormirse. Vale para todos los personajes.
struct SleepAfterPicker: View {
    @AppStorage(CompanionController.sleepMinutesKey) private var minutes = 10

    var body: some View {
        Picker("Se duerme después de", selection: $minutes) {
            ForEach(CompanionController.sleepMinuteOptions, id: \.self) { Text(CompanionController.sleepLabel(minutes: $0)).tag($0) }
            if !CompanionController.sleepMinuteOptions.contains(minutes) {
                Text(CompanionController.sleepLabel(minutes: minutes)).tag(minutes)
            }
        }
        .help("Sin actividad: sin grabar, sin avisos a la vista, sin chat abierto y sin pasar el cursor ni hacerle clic.")
    }
}

/// Proporción del cuadro del personaje en pantalla (ancho respecto al alto). Se guarda en su `character.json`.
struct CharacterProportionControl: View {
    let controller: CompanionController

    var body: some View {
        let controller = controller
        let aspect = controller.character.pack.frameAspect
        LabeledContent("Proporción") {
            HStack {
                Image(systemName: "rectangle.portrait").foregroundStyle(.secondary)
                Slider(value: Binding(get: { controller.character.pack.frameAspect },
                                      set: { value in controller.updatePack { $0.aspect = (value * 100).rounded() / 100 } }),
                       in: CharacterPack.aspectRange, step: 0.05)
                Image(systemName: "square").foregroundStyle(.secondary)
                Text("\(Int((aspect * 100).rounded())) %").monospacedDigit().frame(width: 48, alignment: .trailing)
            }
        }
        .disabled(!controller.character.isEditable)
        .help("Ancho del cuadro respecto a su alto: bajo para un humanoide de pie, alto para un personaje ancho.")
    }
}

private struct OptionsPane: View {
    let controller: CompanionController
    /// Personaje que se abrió en este panel: lo que se escriba aquí nunca se guarda en otro.
    let characterId: String
    @AppStorage(CompanionController.clickActionKey) private var clickAction = CompanionController.ClickAction.menu.rawValue
    @State private var name = ""

    var body: some View {
        let pack = controller.character.pack
        let editable = controller.character.isEditable
        Form {
            Section {
                PaneHeader(title: "Opciones", systemImage: "slider.horizontal.3",
                           detail: "Nombre y encuadre del personaje, qué pasa al hacerle clic y dónde están sus zonas.")
            }
            Section("Personaje") {
                TextField("Nombre", text: $name)
                    .onSubmit(saveName)
                LabeledContent("Zoom") {
                    HStack {
                        Slider(value: zoomBinding, in: 0.5 ... 2, step: 0.05)
                        Text("\(Int((pack.scale * 100).rounded())) %").monospacedDigit().frame(width: 48, alignment: .trailing)
                    }
                }
                CharacterProportionControl(controller: controller)
                Text("La app encuadra sola al personaje para que quepa entero: con el zoom en 100 % no se corta. La proporción cambia la forma del cuadro y el zoom acerca o aleja al personaje dentro de él (por encima de 100 % se recorta). El tamaño en pantalla se cambia en Ajustes → Personaje.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Restablecer encuadre") {
                    controller.updatePack { $0.scale = 1; $0.aspect = nil; $0.camera = nil }
                }
                .disabled(pack.scale == 1 && pack.aspect == nil && pack.camera == nil)
                .help("Zoom al 100 % y proporción de humanoide (55 %).")
            }
            .disabled(!editable)
            Section("Al hacer clic") {
                Picker("Un clic", selection: $clickAction) {
                    ForEach(CompanionController.ClickAction.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Text(clickAction == CompanionController.ClickAction.react.rawValue
                     ? "Si la zona no tiene animación, usa la de otra zona de clic; solo si el personaje no tiene ninguna, el clic abre el menú. El clic derecho (o ⌃clic) siempre abre el menú y el doble clic, la ventana principal."
                     : "Si la zona no tiene animación, solo abre el menú. El clic derecho (o ⌃clic) siempre abre el menú y el doble clic, la ventana principal.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Zonas de clic") {
                LabeledContent("Cabeza") {
                    zoneSlider(headZone, value: pack.behavior.headZone, edge: "superior")
                }
                LabeledContent("Pies") {
                    zoneSlider(feetZone, value: pack.behavior.feetZone, edge: "inferior")
                }
                Text("Mientras esta sección está abierta, el personaje muestra las tres zonas. El cuerpo es lo que queda en medio.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!editable)
            Section("Probar") {
                HStack {
                    Button(controller.previewingAll ? "Recorriendo…" : "Recorrer todos los estados") { controller.previewAll() }
                        .disabled(controller.previewingAll)
                    Button("Detener") { controller.stopPreview() }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            name = pack.name
        }
        .onDisappear(perform: saveName)
    }

    private func zoneSlider(_ binding: Binding<Double>, value: Double, edge: String) -> some View {
        HStack {
            Slider(value: binding, in: CharacterPack.Behavior.zoneRange, step: 0.01)
            Text("\(Int((value * 100).rounded())) % \(edge)").monospacedDigit().frame(width: 110, alignment: .trailing)
        }
    }

    private func saveName() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Al cambiar de personaje este panel se cierra después de que el nuevo ya está activo.
        guard controller.character.id == characterId, !trimmed.isEmpty, trimmed != controller.character.pack.name else { return }
        controller.updatePack { $0.name = trimmed }
    }

    private var zoomBinding: Binding<Double> {
        let controller = controller
        return Binding(get: { controller.character.pack.scale },
                       set: { value in controller.updatePack { $0.scale = (value * 100).rounded() / 100 } })
    }

    private var headZone: Binding<Double> {
        let controller = controller
        return Binding(get: { controller.character.pack.behavior.headZone },
                       set: { new in controller.updatePack { $0.behavior.headZone = new } })
    }

    private var feetZone: Binding<Double> {
        let controller = controller
        return Binding(get: { controller.character.pack.behavior.feetZone },
                       set: { new in controller.updatePack { $0.behavior.feetZone = new } })
    }
}
