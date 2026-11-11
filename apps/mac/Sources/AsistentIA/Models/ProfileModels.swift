import Foundation

// Perfil de RH de una persona (GET /api/people/:id/profile). Estos datos solo
// viven en el backend y en esta pantalla: nunca se le envían a Claude.

enum SalaryPeriod: String, Codable, CaseIterable, Identifiable {
    case monthly, biweekly, weekly, hourly, yearly
    var id: String { rawValue }
    var label: String {
        switch self {
        case .monthly: "mensual"
        case .biweekly: "quincenal"
        case .weekly: "semanal"
        case .hourly: "por hora"
        case .yearly: "anual"
        }
    }
}

enum OvertimeStatus: String, Codable, CaseIterable, Identifiable {
    case pending, paid, compensated
    var id: String { rawValue }
    var label: String {
        switch self {
        case .pending: "Pendiente"
        case .paid: "Pagadas"
        case .compensated: "Compensadas con descanso"
        }
    }
}

enum Mood {
    static let levels = 1...5
    static func emoji(_ level: Int) -> String { ["😞", "🙁", "😐", "🙂", "😄"][min(max(level, 1), 5) - 1] }
    static func label(_ level: Int) -> String { ["Muy bajo", "Bajo", "Neutral", "Bien", "Muy bien"][min(max(level, 1), 5) - 1] }
}

struct PersonProfile: Codable {
    struct Salary: Codable, Identifiable, Hashable {
        let id: String
        let amount: Double
        let currency: String
        let period: SalaryPeriod
        let effectiveDate: Date
        let note: String?
        enum CodingKeys: String, CodingKey { case id = "_id", amount, currency, period, effectiveDate, note }

        var formatted: String { "\(amount.formatted(.currency(code: currency).precision(.fractionLength(0...2)))) \(period.label)" }
    }

    struct SalaryInfo: Codable {
        let current: Salary?
        let history: [Salary]
        let daysSinceChange: Int?
    }

    struct VacationSummary: Codable {
        let yearsOfService: Int
        let periodStart: Date
        let periodEnd: Date
        let total: Double
        let taken: Double
        let remaining: Double
        let nextTotal: Double
        let source: String
        var isOverride: Bool { source == "override" }
    }

    struct Vacation: Codable, Identifiable, Hashable {
        let id: String
        let startDate: Date
        let endDate: Date
        let days: Double
        let note: String?
        enum CodingKeys: String, CodingKey { case id = "_id", startDate, endDate, days, note }
    }

    struct Overtime: Codable, Identifiable, Hashable {
        let id: String
        let date: Date
        let hours: Double
        let reason: String?
        let projectId: String?
        let status: OvertimeStatus
        enum CodingKeys: String, CodingKey { case id = "_id", date, hours, reason, projectId, status }
    }

    struct OvertimeInfo: Codable {
        let entries: [Overtime]
        let pendingHours: Double
        let monthHours: Double
        let yearHours: Double
    }

    struct MoodEntry: Codable, Identifiable, Hashable {
        let id: String
        let date: Date
        let level: Int
        let note: String?
        let sessionId: String?
        enum CodingKeys: String, CodingKey { case id = "_id", date, level, note, sessionId }
    }

    /// Lo que Claude notó en una sesión, pendiente de confirmar.
    struct MoodSuggestion: Codable, Identifiable, Hashable {
        let id: String
        let sessionId: String
        let date: Date
        let level: Int
        let evidence: String?
        let sessionTitle: String?
        let projectId: String?
        enum CodingKeys: String, CodingKey { case id = "_id", sessionId, date, level, evidence, sessionTitle, projectId }
    }

    let id: String
    let name: String
    let birthday: Date?
    let startDate: Date?
    let level: String
    let contractType: String
    let skills: [String]
    let notes: String
    let nextSalaryReview: Date?
    let vacationDaysOverride: Int?
    let salary: SalaryInfo
    let vacation: VacationSummary?
    let vacations: [Vacation]
    let overtime: OvertimeInfo
    let moods: [MoodEntry]
    let moodSuggestions: [MoodSuggestion]
    let lastOneOnOneAt: Date?

    enum CodingKeys: String, CodingKey {
        case id = "_id", name, birthday, startDate, level, contractType, skills, notes, nextSalaryReview
        case vacationDaysOverride, salary, vacation, vacations, overtime, moods, moodSuggestions, lastOneOnOneAt
    }
}

/// PATCH /profile: `.some(nil)` borra el dato (se manda null); un campo sin
/// asignar no se envía y el backend no lo toca.
struct ProfilePatch: Encodable {
    var birthday: String??
    var startDate: String??
    var level: String?
    var contractType: String?
    var skills: [String]?
    var notes: String?
    var nextSalaryReview: String??
    var vacationDaysOverride: Int??

    enum CodingKeys: String, CodingKey {
        case birthday, startDate, level, contractType, skills, notes, nextSalaryReview, vacationDaysOverride
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if let birthday { try c.encode(birthday, forKey: .birthday) }
        if let startDate { try c.encode(startDate, forKey: .startDate) }
        try c.encodeIfPresent(level, forKey: .level)
        try c.encodeIfPresent(contractType, forKey: .contractType)
        try c.encodeIfPresent(skills, forKey: .skills)
        try c.encodeIfPresent(notes, forKey: .notes)
        if let nextSalaryReview { try c.encode(nextSalaryReview, forKey: .nextSalaryReview) }
        if let vacationDaysOverride { try c.encode(vacationDaysOverride, forKey: .vacationDaysOverride) }
    }
}

struct SalaryRequest: Encodable {
    var amount: Double
    var currency: String
    var period: SalaryPeriod
    var effectiveDate: String
    var note: String?
}

struct VacationRequest: Encodable {
    var startDate: String
    var endDate: String
    var days: Double
    var note: String?
}

struct OvertimeRequest: Encodable {
    var date: String
    var hours: Double
    var reason: String?
    var projectId: String?
    var status: OvertimeStatus
}

struct MoodRequest: Encodable {
    var level: Int
    var note: String?
    var date: String?
    var suggestionId: String?
}

/// Fechas de calendario (cumpleaños, ingreso, vacaciones): el backend las
/// guarda a medianoche UTC para que el día no cambie con la zona horaria.
enum CalendarDay {
    static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .gmt
        return c
    }()

    /// "2026-11-11" a partir de una fecha elegida en esta Mac.
    static func string(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// El mismo día de calendario en la zona de esta Mac (para mostrar y para DatePicker).
    /// Una fecha con hora (la de una sesión) se deja como está.
    static func local(_ date: Date, calendar: Calendar = .current) -> Date {
        let c = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard c.hour == 0, c.minute == 0, c.second == 0 else { return date }
        return calendar.date(from: DateComponents(year: c.year, month: c.month, day: c.day)) ?? date
    }

    static func format(_ date: Date) -> String {
        local(date).formatted(date: .abbreviated, time: .omitted)
    }

    /// Días que faltan para el próximo aniversario de la fecha (0 = hoy) y cuántos años cumple.
    static func nextAnniversary(of date: Date, now: Date = .now, calendar: Calendar = .current) -> (days: Int, years: Int)? {
        let origin = utc.dateComponents([.year, .month, .day], from: date)
        let today = calendar.startOfDay(for: now)
        guard let originYear = origin.year, let thisYear = calendar.dateComponents([.year], from: today).year else { return nil }
        for year in [thisYear, thisYear + 1] {
            // 29 de febrero en año no bisiesto: Calendar lo pasa al 1 de marzo.
            guard let next = calendar.date(from: DateComponents(year: year, month: origin.month, day: origin.day)), next >= today else { continue }
            let days = calendar.dateComponents([.day], from: today, to: next).day ?? 0
            return (days, year - originYear)
        }
        return nil
    }

    /// Días hábiles (lunes a viernes) entre dos fechas, ambas incluidas.
    static func weekdays(from start: Date, to end: Date, calendar: Calendar = .current) -> Int {
        var day = calendar.startOfDay(for: start)
        let last = calendar.startOfDay(for: end)
        var count = 0
        while day <= last {
            if !calendar.isDateInWeekend(day) { count += 1 }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return count
    }

    static func countdown(_ days: Int) -> String {
        switch days {
        case 0: "hoy"
        case 1: "mañana"
        default: "en \(days) días"
        }
    }
}
