import SwiftUI

// Perfil de RH de una persona: datos, sueldo, vacaciones, horas extra y ánimo.
// La columna central lista las secciones con su resumen; la de detalle muestra
// la sección elegida con sus formularios.

private func number(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(0...2)))
}

private let hiddenAmount = "••••••"

// MARK: - Columna central

struct ProfileSectionList: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        if let profile = store.profile {
            List(selection: $store.profileSection) {
                ForEach(AppStore.ProfileSection.allCases) { section in
                    HStack {
                        Label(section.rawValue, systemImage: section.icon)
                        Spacer()
                        Text(summary(section, profile)).font(.caption).foregroundStyle(.secondary)
                        if section == .mood, !profile.moodSuggestions.isEmpty {
                            Text("\(profile.moodSuggestions.count)").font(.caption2.bold())
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.orange.opacity(0.25), in: Capsule())
                                .help("Sugerencias de Claude por confirmar")
                        }
                    }
                    .tag(section)
                }
            }
        } else {
            ProgressView().frame(maxHeight: .infinity)
        }
    }

    private func summary(_ section: AppStore.ProfileSection, _ p: PersonProfile) -> String {
        switch section {
        case .info:
            return [p.level, p.vacation.map { "\($0.yearsOfService) \($0.yearsOfService == 1 ? "año" : "años")" }]
                .compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
        case .salary:
            guard let current = p.salary.current else { return "Sin registrar" }
            return store.revealSalary ? current.formatted : hiddenAmount
        case .vacations:
            guard let v = p.vacation else { return "Falta fecha de ingreso" }
            return "\(number(v.remaining)) de \(number(v.total)) días"
        case .overtime:
            return p.overtime.pendingHours > 0 ? "\(number(p.overtime.pendingHours)) h pendientes" : "Sin pendientes"
        case .mood:
            return p.moods.first.map { "\(Mood.emoji($0.level)) \(Mood.label($0.level))" } ?? "Sin registrar"
        }
    }
}

// MARK: - Columna de detalle

struct ProfileDetailView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        if let profile = store.profile, let section = store.profileSection {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("\(section.rawValue) · \(profile.name)").font(.title2.bold())
                    switch section {
                    case .info: ProfileInfoSection(profile: profile)
                    case .salary: ProfileSalarySection(profile: profile)
                    case .vacations: ProfileVacationSection(profile: profile)
                    case .overtime: ProfileOvertimeSection(profile: profile)
                    case .mood: ProfileMoodSection(profile: profile)
                    }
                }
                .padding(24)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Los formularios guardan su estado: se reinician al cambiar de persona o sección.
            .id("\(profile.id)|\(section.rawValue)")
        } else {
            ContentUnavailableView("Perfil", systemImage: "person.text.rectangle",
                                   description: Text("Elige una sección."))
        }
    }
}

// MARK: - Piezas comunes

private struct ProfileStat: View {
    let value: String
    let label: String
    var color: Color = .primary

    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.title2.bold()).foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Fecha opcional: casilla para decir si se conoce y selector de día.
private struct OptionalDayPicker: View {
    let title: String
    @Binding var date: Date?

    var body: some View {
        HStack {
            Toggle(title, isOn: Binding(get: { date != nil }, set: { date = $0 ? (date ?? .now) : nil }))
                .toggleStyle(.checkbox)
            if date != nil {
                DatePicker("", selection: Binding(get: { date ?? .now }, set: { date = $0 }), displayedComponents: .date)
                    .labelsHidden()
            }
        }
    }
}

/// Fila de un registro con su menú para borrarlo (y otras acciones).
private struct RecordRow<Actions: View>: View {
    let title: String
    let detail: String?
    let trailing: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Spacer()
            Text(trailing).monospacedDigit()
            Menu { actions } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
        }
        .padding(.vertical, 3)
    }
}

private func card<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
    GroupBox {
        VStack(alignment: .leading, spacing: 10) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
    } label: {
        Text(title).font(.headline)
    }
}

private func trimmedOrNil(_ text: String) -> String? {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.isEmpty ? nil : t
}

// MARK: - Datos

private struct ProfileInfoSection: View {
    @Environment(AppStore.self) private var store
    let profile: PersonProfile

    @State private var birthday: Date?
    @State private var startDate: Date?
    @State private var level = ""
    @State private var contractType = ""
    @State private var skills: [String] = []
    @State private var newSkill = ""
    @State private var notes = ""
    @State private var saved = false

    static let levels = ["Trainee", "Junior", "Mid", "Senior", "Lead"]
    static let contracts = ["Nómina", "Honorarios", "Externo / proveedor", "Prácticas"]

    var body: some View {
        card("Fechas") {
            OptionalDayPicker(title: "Cumpleaños", date: $birthday)
            if let birthday = profile.birthday, let next = CalendarDay.nextAnniversary(of: birthday) {
                Text("Cumple \(next.years) años \(CalendarDay.countdown(next.days)).").font(.caption).foregroundStyle(.secondary)
            }
            OptionalDayPicker(title: "Fecha de ingreso", date: $startDate)
            if let start = profile.startDate, let v = profile.vacation, let next = CalendarDay.nextAnniversary(of: start) {
                Text("\(v.yearsOfService) \(v.yearsOfService == 1 ? "año" : "años") en el equipo · próximo aniversario \(CalendarDay.countdown(next.days)).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(profile.lastOneOnOneAt.map { "Último 1:1 preparado: \($0.formatted(date: .abbreviated, time: .omitted))." } ?? "Aún no se ha preparado un 1:1.")
                .font(.caption).foregroundStyle(.secondary)
        }
        card("Puesto") {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Nivel")
                    suggestionField($level, prompt: "Senior", options: Self.levels)
                }
                GridRow {
                    Text("Contrato")
                    suggestionField($contractType, prompt: "Nómina", options: Self.contracts)
                }
            }
            Text("Habilidades y tecnologías").font(.caption).foregroundStyle(.secondary)
            if !skills.isEmpty {
                FlowChips(items: skills) { skill in skills.removeAll { $0 == skill } }
            }
            TextField("Agregar y Enter", text: $newSkill, prompt: Text("Swift, Kotlin, CI/CD…"))
                .textFieldStyle(.roundedBorder)
                .onSubmit(addSkill)
        }
        card("Notas privadas") {
            TextEditor(text: $notes)
                .font(.body)
                .frame(minHeight: 110)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            Text("Solo tú las ves: metas, acuerdos, cosas a recordar. No se le envían a Claude.")
                .font(.caption).foregroundStyle(.secondary)
        }
        HStack {
            Button("Guardar datos") { save() }.buttonStyle(.borderedProminent)
            if saved { Label("Guardado", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout) }
        }
        .onAppear(perform: load)
    }

    private func suggestionField(_ text: Binding<String>, prompt: String, options: [String]) -> some View {
        HStack {
            TextField("", text: text, prompt: Text(prompt)).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
            Menu {
                ForEach(options, id: \.self) { option in Button(option) { text.wrappedValue = option } }
            } label: {
                Image(systemName: "chevron.down.circle")
            }
            .menuStyle(.borderlessButton).fixedSize()
        }
    }

    private func load() {
        birthday = profile.birthday.map { CalendarDay.local($0) }
        startDate = profile.startDate.map { CalendarDay.local($0) }
        level = profile.level
        contractType = profile.contractType
        skills = profile.skills
        notes = profile.notes
    }

    private func addSkill() {
        let skill = newSkill.trimmingCharacters(in: .whitespaces)
        newSkill = ""
        guard !skill.isEmpty, !skills.contains(where: { $0.caseInsensitiveCompare(skill) == .orderedSame }) else { return }
        skills.append(skill)
    }

    private func save() {
        addSkill()
        let patch = ProfilePatch(
            birthday: .some(birthday.map { CalendarDay.string($0) }),
            startDate: .some(startDate.map { CalendarDay.string($0) }),
            level: level, contractType: contractType, skills: skills, notes: notes
        )
        Task { saved = await store.saveProfile(patch) }
    }
}

// MARK: - Sueldo

private struct ProfileSalarySection: View {
    @Environment(AppStore.self) private var store
    let profile: PersonProfile

    @State private var amount: Double?
    @State private var currency = "MXN"
    @State private var period: SalaryPeriod = .monthly
    @State private var effectiveDate = Date.now
    @State private var note = ""
    @State private var review: Date?

    private var history: [PersonProfile.Salary] { profile.salary.history }

    var body: some View {
        @Bindable var store = store
        card("Sueldo actual") {
            HStack(alignment: .firstTextBaseline) {
                Text(profile.salary.current.map { store.revealSalary ? $0.formatted : hiddenAmount } ?? "Sin registrar")
                    .font(.title.bold()).monospacedDigit()
                Spacer()
                Toggle(isOn: $store.revealSalary) {
                    Label(store.revealSalary ? "Ocultar" : "Mostrar", systemImage: store.revealSalary ? "eye.slash" : "eye")
                }
                .toggleStyle(.button)
                .help("Los montos se muestran ocultos por si estás compartiendo pantalla")
            }
            if let current = profile.salary.current, let days = profile.salary.daysSinceChange {
                Text("Vigente desde \(CalendarDay.format(current.effectiveDate)) (\(Self.elapsed(days))).")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                OptionalDayPicker(title: "Próxima revisión de sueldo", date: $review)
                if review.map({ CalendarDay.string($0) }) != profile.nextSalaryReview.map({ CalendarDay.string(CalendarDay.local($0)) }) {
                    Button("Guardar fecha") {
                        let patch = ProfilePatch(nextSalaryReview: .some(review.map { CalendarDay.string($0) }))
                        Task { _ = await store.saveProfile(patch) }
                    }
                }
            }
            Text("El sueldo y su histórico se guardan en tu servidor y nunca se le envían a Claude.")
                .font(.caption).foregroundStyle(.secondary)
        }
        card("Registrar sueldo o aumento") {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Monto")
                    HStack {
                        TextField("", value: $amount, format: .number, prompt: Text("45000"))
                            .textFieldStyle(.roundedBorder).frame(width: 140)
                        Picker("", selection: $currency) {
                            Text("MXN").tag("MXN"); Text("USD").tag("USD")
                        }
                        .labelsHidden().fixedSize()
                        Picker("", selection: $period) {
                            ForEach(SalaryPeriod.allCases) { Text($0.label).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                }
                GridRow {
                    Text("Vigente desde")
                    DatePicker("", selection: $effectiveDate, displayedComponents: .date).labelsHidden()
                }
                GridRow {
                    Text("Nota")
                    TextField("", text: $note, prompt: Text("Aumento anual, promoción a Senior…")).textFieldStyle(.roundedBorder)
                }
            }
            Button("Registrar") { add() }
                .disabled((amount ?? 0) <= 0)
        }
        card("Histórico (\(history.count))") {
            if history.isEmpty {
                Text("Sin registros todavía.").foregroundStyle(.secondary)
            }
            ForEach(Array(history.enumerated()), id: \.element.id) { index, entry in
                let previous = index + 1 < history.count ? history[index + 1] : nil
                RecordRow(
                    title: CalendarDay.format(entry.effectiveDate) + (entry.id == profile.salary.current?.id ? " · vigente" : ""),
                    detail: [store.revealSalary ? entry.change(from: previous) : nil, entry.note].compactMap { $0 }.joined(separator: " · "),
                    trailing: store.revealSalary ? entry.formatted : hiddenAmount
                ) {
                    Button("Eliminar registro", role: .destructive) {
                        Task { await store.updateProfile { api, id in try await api.profileDelete(personId: id, "salary/\(entry.id)") } }
                    }
                }
                if index + 1 < history.count { Divider() }
            }
        }
        .onAppear { review = profile.nextSalaryReview.map { CalendarDay.local($0) } }
    }

    private func add() {
        guard let amount, amount > 0 else { return }
        let body = SalaryRequest(amount: amount, currency: currency, period: period,
                                 effectiveDate: CalendarDay.string(effectiveDate), note: trimmedOrNil(note))
        Task {
            if await store.updateProfile({ api, id in try await api.profile(personId: id, "POST", "salary", body: body) }) {
                self.amount = nil
                note = ""
            }
        }
    }

    static func elapsed(_ days: Int) -> String {
        if days < 0 { return "aún no entra en vigor" }
        if days < 31 { return "hace \(days) \(days == 1 ? "día" : "días")" }
        let months = days / 30
        if months < 12 { return "hace \(months) \(months == 1 ? "mes" : "meses")" }
        let years = months / 12, rest = months % 12
        return "hace \(years) \(years == 1 ? "año" : "años")" + (rest > 0 ? " y \(rest) \(rest == 1 ? "mes" : "meses")" : "")
    }

}

extension PersonProfile.Salary {
    /// "+20 %" respecto al registro anterior, si son comparables.
    func change(from previous: PersonProfile.Salary?) -> String? {
        guard let previous, previous.amount > 0, previous.currency == currency, previous.period == period else { return nil }
        let pct = (amount - previous.amount) / previous.amount * 100
        guard abs(pct) >= 0.05 else { return nil }
        return "\(pct > 0 ? "+" : "")\(pct.formatted(.number.precision(.fractionLength(0...1)))) %"
    }
}

// MARK: - Vacaciones

private struct ProfileVacationSection: View {
    @Environment(AppStore.self) private var store
    let profile: PersonProfile

    @State private var start = Date.now
    @State private var end = Date.now
    @State private var days: Double = 1
    @State private var note = ""
    @State private var useOverride = false
    @State private var overrideDays = 12

    var body: some View {
        if let v = profile.vacation {
            HStack(spacing: 10) {
                ProfileStat(value: number(v.total), label: "Totales")
                ProfileStat(value: number(v.taken), label: "Disfrutados", color: .blue)
                ProfileStat(value: number(v.remaining), label: "Restantes", color: v.remaining < 0 ? .red : .green)
            }
            Text("Periodo vigente: \(CalendarDay.format(v.periodStart)) – \(CalendarDay.format(v.periodEnd)) · \(v.yearsOfService) \(v.yearsOfService == 1 ? "año cumplido" : "años cumplidos") · \(v.isOverride ? "días fijados a mano" : "según la Ley Federal del Trabajo"). Al cumplir el siguiente año: \(number(v.nextTotal)) días.")
                .font(.callout).foregroundStyle(.secondary)
            if v.yearsOfService == 0, !v.isOverride {
                Text("Por ley los primeros 12 días se ganan al cumplir el primer año. Si en tu empresa se pueden tomar antes, fija los días a mano.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Label("Captura la fecha de ingreso en «Datos» para calcular los días de vacaciones.", systemImage: "info.circle")
                .foregroundStyle(.secondary)
        }
        card("Días por año") {
            Toggle("Fijar a mano (si la empresa da días distintos a los de la ley)", isOn: $useOverride)
            HStack {
                if useOverride {
                    Stepper("\(overrideDays) días por año", value: $overrideDays, in: 0...60)
                }
                if (useOverride ? overrideDays : nil) != profile.vacationDaysOverride {
                    Button("Guardar") {
                        let patch = ProfilePatch(vacationDaysOverride: .some(useOverride ? overrideDays : nil))
                        Task { _ = await store.saveProfile(patch) }
                    }
                }
            }
        }
        card("Registrar vacaciones") {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Del")
                    HStack {
                        DatePicker("", selection: $start, displayedComponents: .date).labelsHidden()
                        Text("al")
                        DatePicker("", selection: $end, in: start..., displayedComponents: .date).labelsHidden()
                    }
                }
                GridRow {
                    Text("Días")
                    HStack {
                        TextField("", value: $days, format: .number).textFieldStyle(.roundedBorder).frame(width: 70)
                        Text("hábiles (se calcula de lunes a viernes; ajústalo si hubo festivos o medios días)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Text("Nota")
                    TextField("", text: $note, prompt: Text("Semana Santa, viaje…")).textFieldStyle(.roundedBorder)
                }
            }
            Button("Registrar") { add() }.disabled(days <= 0)
        }
        .onChange(of: start) { if end < start { end = start }; recount() }
        .onChange(of: end) { recount() }
        card("Vacaciones tomadas (\(profile.vacations.count))") {
            if profile.vacations.isEmpty {
                Text("Sin registros todavía.").foregroundStyle(.secondary)
            }
            ForEach(profile.vacations) { entry in
                RecordRow(
                    title: entry.startDate == entry.endDate ? CalendarDay.format(entry.startDate)
                        : "\(CalendarDay.format(entry.startDate)) – \(CalendarDay.format(entry.endDate))",
                    detail: entry.note,
                    trailing: "\(number(entry.days)) \(entry.days == 1 ? "día" : "días")"
                ) {
                    Button("Eliminar registro", role: .destructive) {
                        Task { await store.updateProfile { api, id in try await api.profileDelete(personId: id, "vacations/\(entry.id)") } }
                    }
                }
            }
        }
        .onAppear {
            useOverride = profile.vacationDaysOverride != nil
            overrideDays = profile.vacationDaysOverride ?? Int(profile.vacation?.total ?? 12)
            recount()
        }
    }

    private func recount() {
        days = Double(max(1, CalendarDay.weekdays(from: start, to: end)))
    }

    private func add() {
        let body = VacationRequest(startDate: CalendarDay.string(start), endDate: CalendarDay.string(end), days: days, note: trimmedOrNil(note))
        Task {
            if await store.updateProfile({ api, id in try await api.profile(personId: id, "POST", "vacations", body: body) }) { note = "" }
        }
    }
}

// MARK: - Horas extra

private struct ProfileOvertimeSection: View {
    @Environment(AppStore.self) private var store
    let profile: PersonProfile

    @State private var date = Date.now
    @State private var hours: Double = 1
    @State private var reason = ""
    @State private var projectId: String?
    @State private var status: OvertimeStatus = .pending

    var body: some View {
        let o = profile.overtime
        HStack(spacing: 10) {
            ProfileStat(value: "\(number(o.pendingHours)) h", label: "Por pagar o compensar", color: o.pendingHours > 0 ? .orange : .primary)
            ProfileStat(value: "\(number(o.monthHours)) h", label: "Este mes")
            ProfileStat(value: "\(number(o.yearHours)) h", label: "Este año")
        }
        card("Registrar horas extra") {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Fecha")
                    HStack {
                        DatePicker("", selection: $date, displayedComponents: .date).labelsHidden()
                        TextField("", value: $hours, format: .number).textFieldStyle(.roundedBorder).frame(width: 60)
                        Text("horas")
                    }
                }
                GridRow {
                    Text("Motivo")
                    TextField("", text: $reason, prompt: Text("Release de fin de mes, soporte a producción…")).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Proyecto")
                    Picker("", selection: $projectId) {
                        Text("Sin proyecto").tag(String?.none)
                        ForEach(store.projects) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .labelsHidden().fixedSize()
                }
                GridRow {
                    Text("Estado")
                    Picker("", selection: $status) {
                        ForEach(OvertimeStatus.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
            }
            Button("Registrar") { add() }.disabled(hours <= 0)
        }
        card("Registro (\(o.entries.count))") {
            if o.entries.isEmpty {
                Text("Sin registros todavía.").foregroundStyle(.secondary)
            }
            ForEach(o.entries) { entry in
                RecordRow(
                    title: "\(CalendarDay.format(entry.date)) · \(entry.status.label)",
                    detail: [store.projects.first { $0.id == entry.projectId }?.name, entry.reason].compactMap { $0 }.joined(separator: " · "),
                    trailing: "\(number(entry.hours)) h"
                ) {
                    ForEach(OvertimeStatus.allCases.filter { $0 != entry.status }) { next in
                        Button("Marcar: \(next.label)") {
                            Task { await store.updateProfile { api, id in
                                try await api.profile(personId: id, "PATCH", "overtime/\(entry.id)", body: ["status": next.rawValue])
                            } }
                        }
                    }
                    Divider()
                    Button("Eliminar registro", role: .destructive) {
                        Task { await store.updateProfile { api, id in try await api.profileDelete(personId: id, "overtime/\(entry.id)") } }
                    }
                }
            }
        }
    }

    private func add() {
        let body = OvertimeRequest(date: CalendarDay.string(date), hours: hours, reason: trimmedOrNil(reason), projectId: projectId, status: status)
        Task {
            if await store.updateProfile({ api, id in try await api.profile(personId: id, "POST", "overtime", body: body) }) { reason = "" }
        }
    }
}

// MARK: - Ánimo

private struct ProfileMoodSection: View {
    @Environment(AppStore.self) private var store
    let profile: PersonProfile

    @State private var level = 3
    @State private var note = ""
    @State private var date = Date.now

    var body: some View {
        if let latest = profile.moods.first {
            HStack(spacing: 12) {
                Text(Mood.emoji(latest.level)).font(.system(size: 44))
                VStack(alignment: .leading, spacing: 2) {
                    Text(Mood.label(latest.level)).font(.title3.bold())
                    Text("Registrado el \(CalendarDay.format(latest.date))").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                // Tendencia: los últimos registros, del más antiguo al más reciente.
                VStack(alignment: .trailing, spacing: 2) {
                    Text(profile.moods.prefix(10).reversed().map { Mood.emoji($0.level) }.joined(separator: " "))
                    Text("Tendencia").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        if !profile.moodSuggestions.isEmpty {
            card("Sugerencias de Claude (\(profile.moodSuggestions.count))") {
                Text("Lo que Claude notó al analizar sus sesiones. Solo cuenta lo que confirmes.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(profile.moodSuggestions) { suggestion in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("\(Mood.emoji(suggestion.level)) \(Mood.label(suggestion.level))").font(.headline)
                            Spacer()
                            Button(suggestion.sessionTitle ?? "Sesión") {
                                Task { await store.show(sessionId: suggestion.sessionId, projectId: suggestion.projectId) }
                            }
                            .buttonStyle(.link)
                            Text(suggestion.date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
                        }
                        if let evidence = suggestion.evidence { Text(evidence).font(.callout).textSelection(.enabled) }
                        HStack {
                            Button("Confirmar") { confirm(suggestion, level: suggestion.level) }
                            Menu("Corregir nivel") {
                                ForEach(Mood.levels.filter { $0 != suggestion.level }, id: \.self) { l in
                                    Button("\(Mood.emoji(l)) \(Mood.label(l))") { confirm(suggestion, level: l) }
                                }
                            }
                            .fixedSize()
                            Button("Descartar", role: .destructive) {
                                Task { await store.updateProfile { api, id in try await api.profileDelete(personId: id, "mood-suggestions/\(suggestion.id)") } }
                            }
                        }
                    }
                    .padding(10)
                    .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        card("Registrar estado de ánimo") {
            Picker("", selection: $level) {
                ForEach(Mood.levels, id: \.self) { l in Text("\(Mood.emoji(l)) \(Mood.label(l))").tag(l) }
            }
            .pickerStyle(.segmented).labelsHidden()
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Fecha")
                    DatePicker("", selection: $date, in: ...Date.now, displayedComponents: .date).labelsHidden()
                }
                GridRow {
                    Text("Nota")
                    TextField("", text: $note, prompt: Text("Qué notaste o qué te dijo en el 1:1"), axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(1...4)
                }
            }
            Button("Registrar") { add() }
        }
        card("Historial (\(profile.moods.count))") {
            if profile.moods.isEmpty {
                Text("Sin registros todavía.").foregroundStyle(.secondary)
            }
            ForEach(profile.moods) { entry in
                RecordRow(
                    title: "\(Mood.emoji(entry.level)) \(Mood.label(entry.level))",
                    detail: [entry.sessionId != nil ? "Sugerido por Claude" : nil, entry.note].compactMap { $0 }.joined(separator: " · "),
                    trailing: CalendarDay.format(entry.date)
                ) {
                    Button("Eliminar registro", role: .destructive) {
                        Task { await store.updateProfile { api, id in try await api.profileDelete(personId: id, "moods/\(entry.id)") } }
                    }
                }
            }
        }
    }

    private func confirm(_ suggestion: PersonProfile.MoodSuggestion, level: Int) {
        let body = MoodRequest(level: level, suggestionId: suggestion.id)
        Task { await store.updateProfile { api, id in try await api.profile(personId: id, "POST", "moods", body: body) } }
    }

    private func add() {
        let body = MoodRequest(level: level, note: trimmedOrNil(note), date: CalendarDay.string(date))
        Task {
            if await store.updateProfile({ api, id in try await api.profile(personId: id, "POST", "moods", body: body) }) { note = "" }
        }
    }
}
