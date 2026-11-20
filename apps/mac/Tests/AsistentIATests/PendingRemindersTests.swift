import Foundation
import Testing
@testable import AsistentIA

@MainActor
struct PendingRemindersTests {
    var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Mexico_City")!
        return c
    }()

    func date(_ day: Int, _ hour: Int = 10, month: Int = 11) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    func item(_ id: String, _ task: String, due: Date? = nil, status: ItemStatus = .open, owner: String? = "Octavio",
              ownerId: String? = "p1", project: String = "Equipo de desarrollo", updated: Date? = nil) -> TrackedItem {
        TrackedItem(id: id, task: task, owner: owner, dueDate: due, priority: "medium", status: status,
                    projectId: .init(id: "proj-\(project.count)", name: project), sessionId: nil,
                    history: updated.map { [.init(status: nil, note: nil, at: $0, sessionId: nil)] } ?? [],
                    createdAt: date(1), source: nil, ownerId: owner == nil ? nil : ownerId)
    }

    @Test func overdueAndProjectMessagesUseAdriansWording() {
        let now = date(20) // viernes 20 de noviembre
        let items = [item("a", "Revisar el logo de Panda", due: date(19)), item("b", "Continuar con el Figma")]
        let all = PendingReminders.candidates(items: items, now: now, calendar: calendar)
        #expect(all.contains { $0.text == "El pendiente «Revisar el logo de Panda» venció el 19 de noviembre. ¿Lo revisamos?" && $0.target == .item(id: "a", projectId: "proj-20") })
        #expect(all.contains { $0.text == "El equipo «Equipo de desarrollo» tiene 2 pendientes en curso. ¿Quieres revisarlos?" && $0.target == .project(id: "proj-20") })
        // Hay uno vencido: no toca sugerir descanso.
        #expect(!all.contains { $0.kind == .rest })
    }

    @Test func everyKindOfReminder() {
        let now = date(20)
        let items = [
            item("hoy", "Entregar PPT", due: date(20, 18)),
            item("manana", "Revisar QA", due: date(21, 9)),
            item("bloq", "Deploy de Toks", status: .blocked),
            item("solo", "Definir alcance", owner: nil),
            item("quieto", "Flujos de autenticación", status: .inProgress, updated: date(11)),
            item("v1", "Uno", due: date(18)), item("v2", "Dos", due: date(17)),
        ]
        let byKind = Dictionary(grouping: PendingReminders.candidates(items: items, now: now, calendar: calendar), by: \.kind)
        #expect(byKind[.dueToday]?.first?.text == "«Entregar PPT» vence hoy. ¿Lo revisamos?")
        #expect(byKind[.dueTomorrow]?.first?.text == "Mañana vence «Revisar QA». ¿Le damos un vistazo?")
        #expect(byKind[.blocked]?.first?.text == "«Deploy de Toks» está bloqueado. ¿Vemos cómo destrabarlo?")
        #expect(byKind[.noOwner]?.first?.text == "«Definir alcance» no tiene responsable. ¿Se lo asignamos a alguien?")
        #expect(byKind[.stale]?.first?.text == "«Flujos de autenticación» lleva 9 días sin movimiento. ¿Sigue en curso?")
        #expect(byKind[.person]?.first?.text == "Octavio tiene 2 pendientes vencidos. ¿Revisamos su ficha?")
        #expect(byKind[.person]?.first?.target == .person(id: "p1"))
    }

    @Test func restWhenNothingIsDueToday() {
        let items = [item("x", "Algo para la otra semana", due: date(27))]
        let morning = PendingReminders.candidates(items: items, now: date(20, 10), calendar: calendar)
        let rest = morning.first { $0.kind == .rest }
        #expect(rest?.text == "No tienes más pendientes para hoy. Tómate un momento para descansar.")
        #expect(rest?.target == nil && rest?.key == "rest:am")
        #expect(PendingReminders.candidates(items: items, now: date(20, 16), calendar: calendar).contains { $0.key == "rest:pm" })
        // Sin pendientes abiertos también.
        #expect(PendingReminders.candidates(items: [], now: date(20), calendar: calendar).map(\.kind) == [.rest])
    }

    @Test func pickSkipsWhatWasAlreadySaidToday() {
        let items = [item("a", "A", due: date(19)), item("b", "B", due: date(18))]
        let all = PendingReminders.candidates(items: items, now: date(20), calendar: calendar)
        let shown = Set(all.map(\.key)).subtracting(["overdue:b"])
        #expect(PendingReminders.pick(from: all, avoiding: shown)?.key == "overdue:b")
        #expect(PendingReminders.pick(from: all, avoiding: Set(all.map(\.key))) == nil)
        // Primero el tipo: con el índice 0 sale el primer tipo disponible (proyecto), no un pendiente.
        #expect(PendingReminders.pick(from: all, avoiding: [], using: { _ in 0 })?.kind == .project)
    }

    @Test func longTasksAreShortened() {
        let long = String(repeating: "palabra ", count: 20)
        let short = PendingReminders.short(long)
        #expect(short.count <= PendingReminders.maxTaskLength && short.hasSuffix("…"))
        #expect(PendingReminders.short("  Corto ") == "Corto")
    }

    @Test func workHoursAreWeekdaysFromNineToSeven() {
        #expect(PendingReminders.isWorkTime(date(20, 9), calendar: calendar))   // viernes
        #expect(PendingReminders.isWorkTime(date(20, 18), calendar: calendar))
        #expect(!PendingReminders.isWorkTime(date(20, 19), calendar: calendar))
        #expect(!PendingReminders.isWorkTime(date(20, 8), calendar: calendar))
        #expect(!PendingReminders.isWorkTime(date(21, 12), calendar: calendar)) // sábado
    }

    @Test func modelAsksForAReminderOnlyWhenFree() {
        var now = date(20)
        let model = CompanionModel(now: { now })
        var due = 0
        model.onReminderDue = { due += 1 }
        model.reminderEvery = 100
        now += 141 // más que el máximo (100 × 1.4)
        model.say("Otro aviso", dismissAfter: nil)
        #expect(due == 0) // ocupado: espera un minuto
        model.dismissCurrent()
        now += 30
        model.tick()
        #expect(due == 0)
        now += 31
        model.tick()
        #expect(due == 1)
        model.reminderEvery = nil
        now += 1000
        model.tick()
        #expect(due == 1)
    }

    @Test func remindShowsABubbleWithoutChangingTheMood() {
        let model = CompanionModel()
        model.remind("«X» vence hoy. ¿Lo revisamos?", action: .init(title: "Revisar") {})
        #expect(model.current?.text == "«X» vence hoy. ¿Lo revisamos?")
        #expect(model.current?.action?.title == "Revisar")
        #expect(model.current?.dismissAfter == 45)
        #expect(model.mood == .idle)
    }
}
