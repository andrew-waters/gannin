import Foundation
import Testing
@testable import Gannin

/// The "approved by Sam" note on a Needs your review row (andrew-waters/gannin#276).
struct InboxOtherReviewsTests {
    private func pr(_ states: [String: String], author: String = "author") -> PullRequest {
        PullRequest(
            id: "1", number: 1, title: "T", url: URL(string: "https://github.com/acme/api/pull/1")!, repo: "acme/api",
            author: Person(login: author, name: nil, avatarUrl: nil), isDraft: false, state: "OPEN", createdAt: .now, updatedAt: .now,
            mergedAt: nil, reviewDecision: nil, additions: 0, deletions: 0, changedFiles: 0, assignees: [], requestedReviewers: [],
            reviewRequestedAt: [:], reviewers: states.keys.sorted().map { Person(login: $0, name: nil, avatarUrl: nil) },
            linkedIssues: [], checks: nil, reviewStates: states, reviewedAt: [:], lastCommitAt: nil, authorRepliedAt: nil
        )
    }

    @Test func listsEachStateWithItsReviewers() {
        let text = Inbox.otherReviews(pr(["sam": "APPROVED", "ana": "COMMENTED", "bo": "APPROVED"]), excluding: "me")
        #expect(text == "approved by bo and sam, commented by ana")
    }

    @Test func leavesOutYouTheAuthorAndBotsCaseAside() {
        let text = Inbox.otherReviews(pr(["Me": "APPROVED", "Author": "COMMENTED", "ci-bot": "APPROVED", "dependabot[bot]": "COMMENTED", "sam": "CHANGES_REQUESTED"]), excluding: "me")
        #expect(text == "changes requested by sam")
    }

    @Test func isEmptyWhenNobodyElseReviewed() {
        #expect(Inbox.otherReviews(pr([:]), excluding: "me").isEmpty)
        #expect(Inbox.otherReviews(pr(["me": "APPROVED"]), excluding: "me").isEmpty)
    }
}
