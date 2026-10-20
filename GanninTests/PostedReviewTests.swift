import Foundation
import Testing
@testable import Gannin

/// Telling a review of yours already on GitHub from one about to be posted.
struct PostedReviewTests {
    private func review(_ body: String, event: String = "COMMENT", commit: String = "abc", at seconds: TimeInterval = 0) -> PostedReview {
        PostedReview(event: event, body: body, commit: commit, url: nil, submittedAt: Date(timeIntervalSince1970: seconds))
    }

    @Test func latestMatchesTheSummaryAtTheStartOfTheBody() {
        let reviews = [review("Looks fine.", at: 1), review("Needs work.\n\n- `A.swift:3`: leak", at: 2), review("Needs work.", at: 3)]
        #expect(PostedReview.latest(in: reviews, summary: "Needs work.")?.submittedAt == Date(timeIntervalSince1970: 3))
        #expect(PostedReview.latest(in: reviews, summary: "Something else") == nil)
    }

    @Test func anEmptySummaryMatchesNothing() {
        #expect(PostedReview.latest(in: [review("")], summary: " \n") == nil)
    }

    @Test func repeatedNeedsTheSameKindCommitAndBody() {
        let reviews = [review("Needs work.")]
        #expect(PostedReview.repeated(in: reviews, event: "COMMENT", commit: "abc", body: "Needs work.\n") != nil)
        #expect(PostedReview.repeated(in: reviews, event: "APPROVE", commit: "abc", body: "Needs work.") == nil)
        #expect(PostedReview.repeated(in: reviews, event: "COMMENT", commit: "def", body: "Needs work.") == nil)
        #expect(PostedReview.repeated(in: reviews, event: "COMMENT", commit: "abc", body: "Needs more work.") == nil)
    }
}
