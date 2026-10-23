import Foundation
import Testing
@testable import AsistentIA

@Test func decodesTeamMemberWithCountsAndAliases() throws {
    let json = """
    [{"_id": "p1", "name": "Octavio Ramírez", "role": "iOS", "aliases": ["Tavo"], "active": true,
      "projects": [{"_id": "pr1", "name": "Equipo de desarrollo"}],
      "counts": {"open": 3, "blocked": 1, "overdue": 1, "doneWeek": 2}}]
    """
    let person = try #require(try APIClient.decoder.decode([TeamMember].self, from: Data(json.utf8)).first)
    #expect(person.aliasLine == "también: Tavo")
    #expect(person.counts?.overdue == 1)
    #expect(person.projects?.first?.name == "Equipo de desarrollo")
}

@Test func decodesManualItemWithoutSessionAndProgress() throws {
    let item = """
    {"_id": "i1", "task": "Documentar", "owner": "Ana López", "ownerId": "p2", "priority": "high", "status": "open",
     "projectId": {"_id": "pr1", "name": "TOKS"}, "history": [], "createdAt": "2026-10-23T15:00:00.000Z", "source": "manual"}
    """
    let progress = """
    {"days": 7, "completed": [\(item)], "assigned": [\(item)], "stalled": [], "blocked": [], "overdue": []}
    """
    let p = try APIClient.decoder.decode(PersonProgress.self, from: Data(progress.utf8))
    let first = try #require(p.completed.first)
    #expect(first.sessionId == nil)
    #expect(first.source == "manual")
    #expect(first.ownerId == "p2")
}

@Test func decodesMentionsAndOneOnOne() throws {
    let mentions = """
    [{"session": {"_id": "s1", "title": "Daily", "date": "2026-10-23T15:00:00.000Z", "type": "meeting",
                  "project": {"_id": "pr1", "name": "Equipo"}},
      "snippet": "…Tavo, buenos días…", "summary": null}]
    """
    let m = try #require(try APIClient.decoder.decode([Mention].self, from: Data(mentions.utf8)).first)
    #expect(m.id == "s1")
    #expect(m.snippet?.contains("Tavo") == true)

    let prep = """
    {"_id": "o1", "periodStart": "2026-10-09T00:00:00.000Z", "periodEnd": "2026-10-23T00:00:00.000Z",
     "result": {"summary": "Bien", "wins": ["A"], "blockers": [], "workload_signals": null,
                "topics": ["T"], "questions": ["Q"]},
     "model": "claude-sonnet-5-5", "usage": {"inputTokens": 2000, "outputTokens": 500, "costUsd": 0.009},
     "createdAt": "2026-10-23T16:00:00.000Z"}
    """
    let o = try APIClient.decoder.decode(OneOnOnePrep.self, from: Data(prep.utf8))
    #expect(o.result.workloadSignals == nil)
    #expect(o.result.questions == ["Q"])
}

@Test func encodesAssignmentAsNullWhenClearingOwner() throws {
    let clear = try #require(try JSONSerialization.jsonObject(
        with: APIClient.encoder.encode(ActionItemPatch(ownerId: .some(nil)))) as? [String: Any])
    #expect(clear["ownerId"] is NSNull)
    let assign = try #require(try JSONSerialization.jsonObject(
        with: APIClient.encoder.encode(ActionItemPatch(ownerId: .some("p1")))) as? [String: Any])
    #expect(assign["ownerId"] as? String == "p1")
}

@Test func groupsPeopleByRoleIgnoringCaseWithNoRoleLast() throws {
    let json = """
    [{"_id": "1", "name": "Ana", "role": "iOS Developer", "aliases": []},
     {"_id": "2", "name": "Beto", "role": "", "aliases": []},
     {"_id": "3", "name": "Carla", "role": "Android Developer", "aliases": []},
     {"_id": "4", "name": "Dani", "role": " ios developer ", "aliases": []},
     {"_id": "5", "name": "Eva", "aliases": []}]
    """
    let people = try APIClient.decoder.decode([TeamMember].self, from: Data(json.utf8))
    let groups = TeamGroup.byRole(people)
    #expect(groups.map(\.role) == ["Android Developer", "iOS Developer", "Sin rol"])
    #expect(groups[1].people.map(\.name) == ["Ana", "Dani"])
    #expect(groups[2].people.map(\.name) == ["Beto", "Eva"])
    #expect(TeamGroup.roles(people) == ["Android Developer", "iOS Developer"])
}
