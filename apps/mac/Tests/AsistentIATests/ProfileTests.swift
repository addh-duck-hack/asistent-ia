import Foundation
import Testing
@testable import AsistentIA

private func day(_ s: String, _ calendar: Calendar = .current) -> Date {
    let p = s.split(separator: "-").compactMap { Int($0) }
    return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))!
}

@Test func decodesTheProfileFromTheBackend() throws {
    let json = """
    {"_id":"p1","name":"Octavio Ramírez","birthday":"1994-02-20T00:00:00.000Z","startDate":"2023-03-15T00:00:00.000Z",
     "level":"Senior","contractType":"Nómina","skills":["Swift"],"notes":"","nextSalaryReview":null,"vacationDaysOverride":null,
     "salary":{"current":{"_id":"s2","amount":48000,"currency":"MXN","period":"monthly","effectiveDate":"2025-03-15T00:00:00.000Z","note":"Aumento"},
               "history":[{"_id":"s2","amount":48000,"currency":"MXN","period":"monthly","effectiveDate":"2025-03-15T00:00:00.000Z","note":"Aumento"},
                          {"_id":"s1","amount":40000,"currency":"MXN","period":"monthly","effectiveDate":"2023-03-15T00:00:00.000Z"}],
               "daysSinceChange":606},
     "vacation":{"yearsOfService":3,"periodStart":"2026-03-15T00:00:00.000Z","periodEnd":"2027-03-15T00:00:00.000Z","total":16,"taken":5,"remaining":11,"nextTotal":18,"source":"law"},
     "vacations":[{"_id":"v1","startDate":"2026-04-06T00:00:00.000Z","endDate":"2026-04-10T00:00:00.000Z","days":5}],
     "overtime":{"entries":[{"_id":"o1","date":"2026-11-05T00:00:00.000Z","hours":2.5,"reason":"Release","status":"pending"}],"pendingHours":2.5,"monthHours":2.5,"yearHours":2.5},
     "moods":[{"_id":"m1","date":"2026-11-10T00:00:00.000Z","level":4,"note":"Contento"}],
     "moodSuggestions":[{"_id":"g1","sessionId":"x1","date":"2026-11-10T15:00:00.000Z","level":2,"evidence":"Se desveló","sessionTitle":"Daily","projectId":"pr1"}],
     "lastOneOnOneAt":null}
    """
    let profile = try APIClient.decoder.decode(PersonProfile.self, from: Data(json.utf8))
    #expect(profile.salary.current?.amount == 48_000)
    #expect(profile.salary.history.count == 2)
    #expect(profile.vacation?.remaining == 11)
    #expect(profile.overtime.entries.first?.status == .pending)
    #expect(profile.moodSuggestions.first?.sessionTitle == "Daily")
    #expect(profile.salary.history[0].change(from: profile.salary.history[1]) == "+20 %")
}

@Test func profilePatchSendsNullOnlyForClearedFields() throws {
    let patch = ProfilePatch(birthday: .some(nil), startDate: .some("2023-03-15"), level: "Senior", vacationDaysOverride: .some(nil))
    let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(patch)) as? [String: Any])
    #expect(json["birthday"] is NSNull)
    #expect(json["startDate"] as? String == "2023-03-15")
    #expect(json["vacationDaysOverride"] is NSNull)
    #expect(json["level"] as? String == "Senior")
    #expect(json["notes"] == nil) // sin asignar: no se envía
    #expect(json["nextSalaryReview"] == nil)
}

@Test func calendarDaysDoNotShiftWithTheTimeZone() throws {
    var mexico = Calendar(identifier: .gregorian)
    mexico.timeZone = try #require(TimeZone(identifier: "America/Mexico_City"))
    // El backend guarda el 20 de febrero a medianoche UTC: en México sigue siendo el 20.
    let stored = try #require(ISO8601DateFormatter().date(from: "1994-02-20T00:00:00Z"))
    #expect(CalendarDay.string(CalendarDay.local(stored, calendar: mexico), calendar: mexico) == "1994-02-20")
    // Una fecha con hora (la de una sesión) no se toca.
    let session = try #require(ISO8601DateFormatter().date(from: "2026-11-11T00:14:37Z"))
    #expect(CalendarDay.local(session, calendar: mexico) == session)
}

@Test func nextAnniversaryAndWeekdays() throws {
    let cal = Calendar.current
    let birthday = try #require(ISO8601DateFormatter().date(from: "1994-02-20T00:00:00Z"))
    let before = try #require(CalendarDay.nextAnniversary(of: birthday, now: day("2026-02-15"), calendar: cal))
    #expect(before.days == 5 && before.years == 32)
    let today = try #require(CalendarDay.nextAnniversary(of: birthday, now: day("2026-02-20"), calendar: cal))
    #expect(today.days == 0)
    let after = try #require(CalendarDay.nextAnniversary(of: birthday, now: day("2026-02-21"), calendar: cal))
    #expect(after.days == 364 && after.years == 33)
    // Lunes 6 a viernes 10 de abril de 2026 = 5; hasta el lunes 13 = 6.
    #expect(CalendarDay.weekdays(from: day("2026-04-06"), to: day("2026-04-10"), calendar: cal) == 5)
    #expect(CalendarDay.weekdays(from: day("2026-04-06"), to: day("2026-04-13"), calendar: cal) == 6)
    #expect(CalendarDay.countdown(0) == "hoy" && CalendarDay.countdown(3) == "en 3 días")
}

@Test func sidebarAnnouncesBirthdaysWithinAWeek() throws {
    let json = #"{"_id":"p1","name":"Ana","aliases":[],"birthday":"1990-11-14T00:00:00.000Z","startDate":"2024-06-01T00:00:00.000Z"}"#
    let ana = try APIClient.decoder.decode(TeamMember.self, from: Data(json.utf8))
    #expect(ana.upcomingDate(now: day("2026-11-11")) == "🎂 Cumpleaños en 3 días")
    #expect(ana.upcomingDate(now: day("2026-10-01")) == nil)
    #expect(ana.upcomingDate(now: day("2026-05-30")) == "🎉 Cumple 2 años en el equipo en 2 días")
}
