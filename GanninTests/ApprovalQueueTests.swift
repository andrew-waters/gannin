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

    @Test func dismissedFindingsAreNotHeld() {
        var draft = ReviewDraft()
        #expect(SessionStore.heldFindings(review("approve", findings: findings), draft: draft) == 2)
        draft.decisions[findings[0].key] = .dismissed
        draft.decisions[findings[1].key] = .edited("Add a test for the empty token")
        #expect(SessionStore.heldFindings(review("approve", findings: findings), draft: draft) == 1)
    }
}
