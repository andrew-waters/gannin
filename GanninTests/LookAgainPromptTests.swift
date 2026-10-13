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
        #expect(!prompt.contains("Since your last review"))
        #expect(prompt.contains("keep the findings that still stand"))
        #expect(!prompt.contains("Leave out findings"))
    }
}

/// Whether the author has seen the latest review result.
struct ReviewDraftPostedLatestTests {
    private func draft(posted: Date?, resultAt: Date?) -> ReviewDraft {
        var draft = ReviewDraft()
        if let posted {
            draft.posted = URL(string: "https://github.com/acme/app/pull/7#pullrequestreview-1")
            draft.postedAt = posted
        }
        draft.resultAt = resultAt
        return draft
    }

    @Test func neverPostedIsNotPosted() {
        #expect(!draft(posted: nil, resultAt: .now).postedLatest)
    }

    @Test func postedAfterTheResultIsPosted() {
        let result = Date.now
        #expect(draft(posted: result.addingTimeInterval(1), resultAt: result).postedLatest)
    }

    @Test func postedThenANewUnpostedRoundIsNotPosted() {
        let posted = Date.now
        #expect(!draft(posted: posted, resultAt: posted.addingTimeInterval(60)).postedLatest)
    }

    @Test func postedBeforeResultsWereTimedIsPosted() {
        #expect(draft(posted: .now, resultAt: nil).postedLatest)
    }
}
