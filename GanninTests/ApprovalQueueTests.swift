import Foundation
import Testing
@testable import Gannin

/// Automatic reviews Claude would approve are held for the user, findings and all, while they're ready.
struct ApprovalQueueTests {
    private let findings: [SessionTranscript.Finding] = [
        .init(path: "A.swift", line: 3, comment: "Off by one"),
        .init(path: "B.swift", line: nil, comment: "Missing test"),
    ]

    private func review(_ verdict: String?, findings: [SessionTranscript.Finding] = []) -> SessionTranscript.ReviewResult {
        .init(summary: "s", verdict: verdict, findings: findings)
    }

    @Test func approvalWithNothingToSayIsHeldReadyOrNot() {
        #expect(SessionStore.holdsForApproval(review("approve"), draft: ReviewDraft(), isReady: true))
        #expect(SessionStore.holdsForApproval(review("approve"), draft: ReviewDraft(), isReady: false))
    }

    @Test func approvalWithFindingsIsHeldWhenReady() {
        #expect(SessionStore.holdsForApproval(review("approve", findings: findings), draft: ReviewDraft(), isReady: true))
    }

    /// Failing checks or conflicts keep it out of the queue, so its findings
    /// are posted rather than held where nobody sees them.
    @Test func approvalWithFindingsIsPostedWhenNotReady() {
        #expect(!SessionStore.holdsForApproval(review("approve", findings: findings), draft: ReviewDraft(), isReady: false))
        var draft = ReviewDraft()
        for finding in findings { draft.decisions[finding.key] = .dismissed }
        #expect(SessionStore.holdsForApproval(review("approve", findings: findings), draft: draft, isReady: false))
    }

    @Test func commentsAndChangeRequestsAreNotHeld() {
        #expect(!SessionStore.holdsForApproval(review("comment", findings: findings), draft: ReviewDraft(), isReady: true))
        #expect(!SessionStore.holdsForApproval(review("request_changes", findings: findings), draft: ReviewDraft(), isReady: true))
        #expect(!SessionStore.holdsForApproval(review(nil, findings: findings), draft: ReviewDraft(), isReady: true))
    }

    private func record(_ verdict: String?, draft: ReviewDraft = ReviewDraft(), posting: Bool = false) -> ReviewRecord? {
        let pr = PullRequestReference(
            org: "acme", id: "PR_1", number: 7, title: "Plan", repo: "acme/harness",
            url: URL(string: "https://github.com/acme/harness/pull/7")!
        )
        var session = CodeSession(
            id: UUID(), issue: IssueReference(org: "acme", id: "I_1", number: 7, title: "Plan", repo: "acme/harness", url: pr.url),
            repo: "acme/harness", branch: "review", createdAt: .now
        )
        session.reviewOf = pr
        return ReviewRecord.updated(nil, session: session, review: review(verdict), draft: draft, reviewer: "andrew", posting: posting, automatically: posting, outcome: nil)
    }

    @Test func recordMarksAnApprovalNotGivenAsHeld() {
        #expect(record("approve")?.approvalHeld == true)
        // Posted as a comment: the verdict is approve, but what reached GitHub isn't.
        var commented = ReviewDraft()
        commented.postedEvent = "COMMENT"
        #expect(record("approve", draft: commented, posting: true)?.approvalHeld == true)
        #expect(record("approve", draft: commented, posting: true)?.event == "COMMENT")
    }

    @Test func recordDoesNotHoldAnApprovalOnceGivenOrDismissed() {
        var approved = ReviewDraft()
        approved.postedEvent = "APPROVE"
        #expect(record("approve", draft: approved, posting: true)?.approvalHeld == nil)
        var dismissed = ReviewDraft()
        dismissed.approvalDismissedAt = .now
        #expect(record("approve", draft: dismissed)?.approvalHeld == nil)
    }

    @Test func recordHoldsNothingForOtherVerdicts() {
        #expect(record("comment")?.approvalHeld == nil)
        #expect(record("request_changes")?.approvalHeld == nil)
    }

    @Test func dismissalLapsesWithANewResult() {
        var draft = ReviewDraft()
        draft.resultAt = Date(timeIntervalSince1970: 100)
        draft.approvalDismissedAt = Date(timeIntervalSince1970: 200)
        #expect(draft.approvalDismissed)
        draft.resultAt = Date(timeIntervalSince1970: 300)
        #expect(!draft.approvalDismissed)
    }

    @Test func approvalHeldNoteIsAddedToTheBodyOnlyWhenHeld() {
        #expect(!ReviewedPullRequest.body(summary: "Looks good.", general: []).contains(ReviewedPullRequest.approvalHeldNote))
        let held = ReviewedPullRequest.body(summary: "Looks good.", general: [], approvalHeld: true)
        #expect(held.hasPrefix("Looks good."))
        #expect(held.contains(ReviewedPullRequest.approvalHeldNote))
    }

    @Test func dismissedFindingsAreNotHeld() {
        var draft = ReviewDraft()
        #expect(SessionStore.heldFindings(review("approve", findings: findings), draft: draft) == 2)
        draft.decisions[findings[0].key] = .dismissed
        draft.decisions[findings[1].key] = .edited("Add a test for the empty token")
        #expect(SessionStore.heldFindings(review("approve", findings: findings), draft: draft) == 1)
    }
}
