import Foundation
import Testing
@testable import Gannin

/// Automatic reviews Claude would approve are held for the user, comments and all.
struct ApprovalQueueTests {
    private let findings: [SessionTranscript.Finding] = [
        .init(path: "A.swift", line: 3, comment: "Off by one"),
        .init(path: "B.swift", line: nil, comment: "Missing test"),
    ]

    private func review(_ verdict: String?, findings: [SessionTranscript.Finding] = []) -> SessionTranscript.ReviewResult {
        .init(summary: "s", verdict: verdict, findings: findings)
    }

    @Test func approvalWithNothingToSayIsHeld() {
        #expect(SessionStore.holdsForApproval(review("approve")))
    }

    @Test func approvalWithCommentsIsHeld() {
        #expect(SessionStore.holdsForApproval(review("approve", findings: findings)))
    }

    @Test func commentsAndChangeRequestsAreNotHeld() {
        #expect(!SessionStore.holdsForApproval(review("comment", findings: findings)))
        #expect(!SessionStore.holdsForApproval(review("request_changes", findings: findings)))
        #expect(!SessionStore.holdsForApproval(review(nil, findings: findings)))
    }

    @Test func dismissedFindingsAreNotHeld() {
        var draft = ReviewDraft()
        #expect(SessionStore.heldFindings(review("approve", findings: findings), draft: draft) == 2)
        draft.decisions[findings[0].key] = .dismissed
        draft.decisions[findings[1].key] = .edited("Add a test for the empty token")
        #expect(SessionStore.heldFindings(review("approve", findings: findings), draft: draft) == 1)
    }
}
