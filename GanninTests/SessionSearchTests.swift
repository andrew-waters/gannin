import Foundation
import Testing
@testable import Gannin

struct SessionSearchTests {
    private func session(title: String = "Nudge the Save button up", repo: String = "acme/app", branch: String = "12-nudge-save") -> CodeSession {
        let reference = IssueReference(
            org: "acme", id: "I_12", number: 12, title: title, repo: repo,
            url: URL(string: "https://github.com/\(repo)/issues/12")!
        )
        return CodeSession(id: UUID(), issue: reference, repo: repo, branch: branch, createdAt: .now)
    }

    @Test func noWordsMatchEverything() {
        #expect(SessionSearch.words("  ").isEmpty)
        #expect(SessionSearch.matches(session(), words: []))
    }

    @Test func everyWordMustMatchAnyField() {
        let session = session()
        #expect(SessionSearch.matches(session, words: SessionSearch.words("SAVE acme")))
        #expect(SessionSearch.matches(session, words: SessionSearch.words("nudge 12-nudge")))
        #expect(!SessionSearch.matches(session, words: SessionSearch.words("save billing")))
    }

    @Test func branchMatches() {
        #expect(SessionSearch.matches(session(branch: "feature/zebra"), words: ["zebra"]))
    }
}
