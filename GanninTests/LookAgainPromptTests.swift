import Foundation
import Testing
@testable import Gannin

/// What a watched review is told when it's asked to look again.
struct LookAgainPromptTests {
    private let pr = PullRequestReference(
        org: "acme", id: "PR_1", number: 7, title: "Fix it", repo: "acme/app",
        url: URL(string: "https://github.com/acme/app/pull/7")!
    )

    @Test func postedReviewLeavesOutUnchangedFindings() {
        let prompt = SessionStore.lookAgainPrompt(pr, because: "new commits have been pushed", wasPosted: true, learned: "")
        #expect(prompt.contains("Since your last review of acme/app#7, new commits have been pushed."))
        #expect(prompt.contains("Leave out findings from your earlier review that still stand unchanged"))
    }

    @Test func unpostedReviewIsRedoneAsAFirstReview() {
        let prompt = SessionStore.lookAgainPrompt(pr, because: "new commits have been pushed", wasPosted: false, learned: "")
        #expect(prompt.contains("never posted"))
        #expect(prompt.contains("keep the findings that still stand"))
        #expect(!prompt.contains("Leave out findings"))
    }
}
