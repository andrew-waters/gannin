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

    @Test func kindNameAndReferenceMatch() throws {
        let session = session()
        let kind = TabKind(session)
        #expect(SessionSearch.matches(session, words: SessionSearch.words(kind.name)))
        let reference = try #require(kind.reference)
        #expect(SessionSearch.matches(session, words: SessionSearch.words(reference)))
    }

    @Test func pullRequestsMatchByRepoNumberAndTitle() {
        let session = session()
        let pr = SessionPullRequest(
            id: "PR_1", number: 77, title: "Fix zebra crossing", url: URL(string: "https://github.com/acme/other/pull/77")!, repo: "acme/other",
            author: "me", state: "OPEN", isDraft: false, reviewDecision: nil, mergeable: nil, checks: [], feedback: []
        )
        #expect(SessionSearch.matches(session, words: ["acme/other#77"], pullRequests: [pr]))
        #expect(SessionSearch.matches(session, words: ["crossing"], pullRequests: [pr]))
        #expect(!SessionSearch.matches(session, words: ["crossing"]))
        #expect(!SessionSearch.matches(session, words: ["#78"], pullRequests: [pr]))
    }
}
