import Foundation

/// Un recordatorio de pendientes que el personaje puede decir: texto y a dónde lleva su botón.
struct PendingReminder: Equatable {
    enum Kind: String, CaseIterable {
        case project, overdue, dueToday, dueTomorrow, blocked, noOwner, stale, person, rest
    }

    enum Target: Equatable {
        case project(id: String)
        case item(id: String, projectId: String?)
        case person(id: String)
    }

    let kind: Kind
    /// Identifica el recordatorio para no repetirlo en el día (tipo + pendiente, proyecto o persona).
    let key: String
    let text: String
    let actionTitle: String?
    let target: Target?
}

/// Arma y elige los recordatorios a partir de los pendientes abiertos. Lógica pura, para poder probarla.
enum PendingReminders {
    /// Días sin cambios para que un pendiente en curso cuente como "sin movimiento".
    static let staleDays = 7
    /// Vencidos que tiene que acumular una persona para recordarla a ella (y no solo a sus pendientes).
    static let personOverdueMinimum = 2
    static let maxTaskLength = 70

    static func candidates(items: [TrackedItem], people: [TeamMember] = [], now: Date = .now,
                           calendar: Calendar = .current) -> [PendingReminder] {
        let open = items.filter { $0.status != .done }
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        let afterTomorrow = calendar.date(byAdding: .day, value: 2, to: today)!
        var out: [PendingReminder] = []

        // Por proyecto: cuántos pendientes abiertos tiene.
        let byProject = Dictionary(grouping: open.compactMap { item in item.projectId.map { ($0, item) } }, by: { $0.0.id })
        for (projectId, pairs) in byProject.sorted(by: { $0.key < $1.key }) {
            let name = pairs[0].0.name
            let count = pairs.count
            let noun = count == 1 ? "pendiente en curso" : "pendientes en curso"
            out.append(PendingReminder(kind: .project, key: "project:\(projectId)",
                                       text: "El equipo «\(name)» tiene \(count) \(noun). ¿Quieres revisarlos?",
                                       actionTitle: "Ver pendientes", target: .project(id: projectId)))
        }

        for item in open {
            let task = "«\(short(item.task))»"
            let target = PendingReminder.Target.item(id: item.id, projectId: item.projectId?.id)
            func add(_ kind: PendingReminder.Kind, _ text: String) {
                out.append(PendingReminder(kind: kind, key: "\(kind.rawValue):\(item.id)", text: text,
                                           actionTitle: "Revisar", target: target))
            }
            if let due = item.dueDate {
                if due < today {
                    add(.overdue, "El pendiente \(task) venció el \(dayAndMonth(due, calendar: calendar)). ¿Lo revisamos?")
                } else if due < tomorrow {
                    add(.dueToday, "\(task) vence hoy. ¿Lo revisamos?")
                } else if due < afterTomorrow {
                    add(.dueTomorrow, "Mañana vence \(task). ¿Le damos un vistazo?")
                }
            }
            if item.status == .blocked {
                add(.blocked, "\(task) está bloqueado. ¿Vemos cómo destrabarlo?")
            }
            if item.owner == nil {
                add(.noOwner, "\(task) no tiene responsable. ¿Se lo asignamos a alguien?")
            }
            if item.status == .inProgress {
                let last = item.history.compactMap(\.at).max() ?? item.createdAt
                let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: last), to: today).day ?? 0
                if days >= staleDays {
                    add(.stale, "\(task) lleva \(days) días sin movimiento. ¿Sigue en curso?")
                }
            }
        }

        // Personas con varios vencidos.
        let overdueByOwner = Dictionary(grouping: open.filter { $0.ownerId != nil && ($0.dueDate.map { $0 < today } ?? false) },
                                        by: { $0.ownerId! })
        for (ownerId, owned) in overdueByOwner.sorted(by: { $0.key < $1.key }) where owned.count >= personOverdueMinimum {
            let name = people.first { $0.id == ownerId }?.name ?? owned[0].owner ?? "Alguien"
            out.append(PendingReminder(kind: .person, key: "person:\(ownerId)",
                                       text: "\(name) tiene \(owned.count) pendientes vencidos. ¿Revisamos su ficha?",
                                       actionTitle: "Ver ficha", target: .person(id: ownerId)))
        }

        // Nada vence hoy ni está vencido: un respiro. Se puede decir una vez en la mañana y otra en la tarde.
        if !open.contains(where: { $0.dueDate.map { $0 < tomorrow } ?? false }) {
            let half = calendar.component(.hour, from: now) < 14 ? "am" : "pm"
            out.append(PendingReminder(kind: .rest, key: "rest:\(half)",
                                       text: "No tienes más pendientes para hoy. Tómate un momento para descansar.",
                                       actionTitle: nil, target: nil))
        }
        return out
    }

    /// Elige uno al azar: primero el tipo (así un proyecto con 40 pendientes no acapara los avisos)
    /// y luego uno de ese tipo, sin repetir los ya mostrados hoy.
    static func pick(from candidates: [PendingReminder], avoiding shown: Set<String>,
                     using random: (Int) -> Int = { Int.random(in: 0 ..< $0) }) -> PendingReminder? {
        let fresh = candidates.filter { !shown.contains($0.key) }
        let kinds = PendingReminder.Kind.allCases.filter { kind in fresh.contains { $0.kind == kind } }
        guard !kinds.isEmpty else { return nil }
        let kind = kinds[random(kinds.count)]
        let options = fresh.filter { $0.kind == kind }
        return options[random(options.count)]
    }

    /// Lunes a viernes, de 9:00 a 19:00.
    static func isWorkTime(_ date: Date, calendar: Calendar = .current) -> Bool {
        let weekday = calendar.component(.weekday, from: date) // 1 = domingo
        let hour = calendar.component(.hour, from: date)
        return (2 ... 6).contains(weekday) && (9 ..< 19).contains(hour)
    }

    /// Siguiente espera: la frecuencia elegida ± 40 %, para que no parezca un reloj.
    static func nextDelay(every: TimeInterval) -> TimeInterval {
        .random(in: every * 0.6 ... every * 1.4)
    }

    static func short(_ text: String) -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > maxTaskLength else { return clean }
        return clean.prefix(maxTaskLength - 1).trimmingCharacters(in: .whitespaces) + "…"
    }

    static func dayAndMonth(_ date: Date, calendar: Calendar = .current) -> String {
        let format = Date.FormatStyle(locale: Locale(identifier: "es_MX"), calendar: calendar, timeZone: calendar.timeZone)
            .day().month(.wide)
        return date.formatted(format)
    }
}
