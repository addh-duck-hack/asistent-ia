import Foundation
import Testing
@testable import AsistentIA

@Suite struct ProjectSettingsTests {
    private func project(_ json: String) throws -> Project {
        try JSONDecoder().decode(Project.self, from: Data(json.utf8))
    }

    @Test func weeklyDigestDefaultsToOnForOlderServers() throws {
        #expect(try project(#"{"_id":"p","name":"A"}"#).weeklyDigestEnabled)
        #expect(try project(#"{"_id":"p","name":"A","weeklyDigest":false}"#).weeklyDigestEnabled == false)
    }

    @Test func draftTracksChangesAndSendsThePendingTerm() throws {
        let saved = try project(#"{"_id":"p","name":"Portal","vocabulary":["Toks"],"weeklyDigest":false}"#)
        var draft = ProjectDraft(saved)
        #expect(draft.matches(saved))
        #expect(draft.weeklyDigest == false)

        draft.newTerm = "Landing" // escrito pero sin Enter: no es un cambio guardable todavía
        #expect(draft.matches(saved))
        let body = draft.request
        #expect(body.vocabulary == ["Toks", "Landing"])
        #expect(body.weeklyDigest == false)

        draft.newTerm = "toks" // repetido sin importar mayúsculas
        #expect(draft.request.vocabulary == ["Toks"])

        draft.name = "  "
        #expect(!draft.isValid)
        draft.name = " Portal v2 "
        #expect(!draft.matches(saved))
        #expect(draft.request.name == "Portal v2")
    }
}
