import Foundation
import Testing
@testable import Gannin

/// The one-sentence readiness line at the top of a review's Overview.
@MainActor
struct ReviewReadinessTests {
    private func status(decision: String?, isDraft: Bool = false, pending: Bool = false) -> SessionPullRequest {
        let checks = pending ? [SessionPullRequest.Check(name: "build", state: .pending, url: nil, runID: nil)] : []
        return SessionPullRequest(id: "PR_1", number: 7, title: "T", url: URL(string: "https://github.com/acme/app/pull/7")!, repo: "acme/app",
                                  author: "me", state: "OPEN", isDraft: isDraft, reviewDecision: decision, mergeable: "MERGEABLE", checks: checks, feedback: [])
    }

    private func sentence(_ status: SessionPullRequest, isStale: Bool = false) -> String {
        ReviewReadiness(status: status, pullRequest: nil, review: nil, draft: ReviewDraft(), isReviewing: false, isStale: isStale).sentence
    }

    @Test func anApprovedPRThatCanMergeSaysSo() {
        #expect(sentence(status(decision: "APPROVED")) == "Approved, ready to merge")
        #expect(sentence(status(decision: nil)) == "Ready to merge")
    }

    @Test func anApprovedPRStillWaitingOnAChecksSaysSo() {
        #expect(sentence(status(decision: "APPROVED", pending: true)) == "Approved. Ready once its check passes")
        #expect(sentence(status(decision: nil, pending: true)) == "Ready once its check passes")
    }

    @Test func anApprovedPRThatIsBlockedSaysSo() {
        #expect(sentence(status(decision: "APPROVED", isDraft: true)) == "Approved, but can't merge: it's still a draft")
        #expect(sentence(status(decision: nil, isDraft: true)) == "Can't merge: it's still a draft")
    }

    @Test func anApprovalIsNotClaimedForCommitsPushedSinceTheReview() {
        #expect(sentence(status(decision: "APPROVED"), isStale: true) == "Ready once the reviewer has looked at the new commits")
    }
}
