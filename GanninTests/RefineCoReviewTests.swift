import Foundation
import Testing
@testable import Gannin

/// Claude as co-reviewer: its `refine.json`, read leniently, and which of
/// its suggestions are still the room's to decide.
struct RefineCoReviewTests {
    @Test func stateReadsLeniently() throws {
        let finding = UUID()
        let json = """
            {"scouting": [{"finding": "\(finding.uuidString.lowercased())", "files": ["acme/app:src/Signup.tsx#L10-L40", 3], "components": ["SignupForm"], "why": "The form's footer"},
                          {"files": ["no finding"]}],
             "suggestions": [{"id": "s1", "note": "Error text is low contrast", "source": "screenshot", "screenshot": "ABC", "why": "Grey on grey"},
                             {"id": "s2", "note": "Says 'sign in' and 'log in'", "source": "somewhere else"},
                             {"note": "no id"}],
             "extra": true}
            """
        let state = try #require(RefineState.read(Data(json.utf8)))
        #expect(state.scouting.count == 1)
        let scouting = try #require(state.scouting(for: finding))
        #expect(scouting.files == ["acme/app:src/Signup.tsx#L10-L40"])
        #expect(scouting.components == ["SignupForm"])
        #expect(state.suggestions.map(\.id) == ["s1", "s2"])
        #expect(state.suggestions[0].source == .screenshot)
        #expect(state.suggestions[1].source == nil)
        #expect(RefineState.read(Data("not json".utf8)) == nil)
        #expect(RefineState.read(Data("{}".utf8)) == RefineState())
    }

    @Test func keptAndDismissedSuggestionsAreDecided() {
        var info = RefineInfo(name: "Sign-up", slug: "2026-10-10-sign-up", url: "https://staging.acme.com/signup", repos: ["acme/app"], attendees: [])
        info.state = RefineState(suggestions: [.init(id: "s1", note: "a"), .init(id: "s2", note: "b"), .init(id: "s3", note: "c")])
        #expect(info.openSuggestions.map(\.id) == ["s1", "s2", "s3"])
        info.findings = [.init(note: "a", url: info.url, pageTitle: nil, at: .now, suggestion: "s1")]
        info.dismissed = ["s3"]
        #expect(info.openSuggestions.map(\.id) == ["s2"])
    }

    @Test func stateSurvivesSaving() throws {
        var info = RefineInfo(name: "Sign-up", slug: "2026-10-10-sign-up", url: "https://staging.acme.com/signup", repos: ["acme/app"], attendees: [])
        info.state = RefineState(scouting: [.init(finding: UUID().uuidString, files: ["a.swift"], components: ["A"], why: "b")],
                                 suggestions: [.init(id: "s1", note: "a", source: .transcript)])
        info.dismissed = ["s0"]
        let decoded = try JSONDecoder().decode(RefineInfo.self, from: JSONEncoder().encode(info))
        #expect(decoded == info)
    }
}
