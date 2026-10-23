import Foundation
import Testing
@testable import Gannin

/// Findings left out of a review because a comment near their line, or an
/// earlier review, already says the same.
struct ReviewDuplicateCommentTests {
    private func pull(existing: [ReviewedPullRequest.ExistingComment] = [], reviews: [PostedReview] = []) -> ReviewedPullRequest {
        let lines = (1...20).map { DiffLine(id: $0, kind: .added, text: "x", newLine: $0) }
        return ReviewedPullRequest(
            title: "Fix it", body: "", author: "sam", headSHA: "abc", additions: 20, deletions: 0, state: "open",
            files: [.init(path: "A.swift", status: "modified", additions: 20, deletions: 0, lines: lines)],
            existingComments: existing, earlierReviews: reviews, viewer: "me"
        )
    }

    private func existing(line: Int, isOld: Bool = false, body: String, author: String = "alex") -> ReviewedPullRequest.ExistingComment {
        .init(id: line, path: "A.swift", line: line, isOld: isOld, body: body, author: author, avatarURL: nil, createdAt: .now, url: nil)
    }

    private func review(line: Int?, comment: String, suggestion: String? = nil, path: String = "A.swift") -> SessionTranscript.ReviewResult {
        .init(summary: "s", verdict: "comment", findings: [.init(path: path, line: line, comment: comment, suggestion: suggestion)])
    }

    private func earlier(_ body: String, author: String = "me") -> PostedReview {
        PostedReview(event: "COMMENT", body: body, commit: "old", url: nil, submittedAt: .now, author: author)
    }

    @Test func sameCommentOnTheSameLineIsLeftOut() {
        let text = "This force unwrap crashes when the token is missing."
        let (inline, general, omitted) = pull(existing: [existing(line: 5, body: text)]).comments(for: review(line: 5, comment: text), draft: ReviewDraft())
        #expect(inline.isEmpty)
        #expect(general.isEmpty)
        #expect(omitted.count == 1)
        #expect(omitted.first?.author == "alex")
    }

    @Test func rewordedCommentOnTheSameLineIsLeftOut() {
        let reworded = "this force-unwrap crashes when the token is MISSING!"
        let (inline, _, omitted) = pull(existing: [existing(line: 5, body: reworded)])
            .comments(for: review(line: 5, comment: "This force unwrap crashes when the token is missing."), draft: ReviewDraft())
        #expect(inline.isEmpty)
        #expect(omitted.count == 1)
    }

    @Test func differentPointOnTheSameLineIsKept() {
        let (inline, _, omitted) = pull(existing: [existing(line: 5, body: "Rename this to match the other handlers.")])
            .comments(for: review(line: 5, comment: "This force unwrap crashes when the token is missing."), draft: ReviewDraft())
        #expect(inline.count == 1)
        #expect(omitted.isEmpty)
    }

    @Test func differentPointSharingMostWordsIsKept() {
        let (inline, _, omitted) = pull(existing: [existing(line: 5, body: "This force unwrap leaks memory when the token is missing.")])
            .comments(for: review(line: 5, comment: "This force unwrap crashes when the token is missing."), draft: ReviewDraft())
        #expect(inline.count == 1)
        #expect(omitted.isEmpty)
    }

    @Test func sameCommentOnALineFarAwayIsKept() {
        let text = "This force unwrap crashes when the token is missing."
        let (inline, _, omitted) = pull(existing: [existing(line: 15, body: text)]).comments(for: review(line: 5, comment: text), draft: ReviewDraft())
        #expect(inline.count == 1)
        #expect(omitted.isEmpty)
    }

    @Test func sameCommentAFewLinesAwayIsLeftOut() {
        let text = "This force unwrap crashes when the token is missing."
        let (inline, _, omitted) = pull(existing: [existing(line: 7, body: text)]).comments(for: review(line: 5, comment: text), draft: ReviewDraft())
        #expect(inline.isEmpty)
        #expect(omitted.first?.line == 5)
    }

    @Test func sameCommentOnTheRemovedSideIsKept() {
        let text = "This force unwrap crashes when the token is missing."
        let (inline, _, omitted) = pull(existing: [existing(line: 5, isOld: true, body: text)]).comments(for: review(line: 5, comment: text), draft: ReviewDraft())
        #expect(inline.count == 1)
        #expect(omitted.isEmpty)
    }

    @Test func suggestionBlocksAreIgnoredWhenComparing() {
        let text = "Use a guard so a missing token doesn't crash here."
        let body = text + "\n\n```suggestion\nguard let token else { return }\n```"
        let (inline, _, omitted) = pull(existing: [existing(line: 5, body: body)])
            .comments(for: review(line: 5, comment: text, suggestion: "different code"), draft: ReviewDraft())
        #expect(inline.isEmpty)
        #expect(omitted.count == 1)
    }

    @Test func yourOwnCommentsAreNeverLeftOut() {
        var draft = ReviewDraft()
        draft.comments = [.init(path: "A.swift", line: 5, isOld: false, body: "Same thing again, on purpose.")]
        let (inline, _, omitted) = pull(existing: [existing(line: 5, body: "Same thing again, on purpose.")]).comments(for: .init(summary: "s", verdict: nil, findings: []), draft: draft)
        #expect(inline.count == 1)
        #expect(omitted.isEmpty)
    }

    @Test func shortCommentsOnlyMatchWhenTheyShareMostWords() {
        #expect(!ReviewedPullRequest.isSameComment(existing: "nit", finding: "nit: rename this variable to something clearer"))
        #expect(ReviewedPullRequest.isSameComment(existing: "Rename this variable.", finding: "rename this variable"))
    }

    @Test func aFindingThatAddsToTheCommentIsKept() {
        let comment = "This force unwrap crashes"
        let finding = "This force unwrap crashes when the token is missing, and the retry below never stops"
        #expect(!ReviewedPullRequest.isSameComment(existing: comment, finding: finding))
        #expect(ReviewedPullRequest.isSameComment(existing: finding, finding: comment))
    }

    @Test func containmentMatchesWholeWordsOnly() {
        #expect(!ReviewedPullRequest.isSameComment(existing: "this force unwrapped crashes now", finding: "this force unwrap crashes"))
    }

    @Test func someoneElsesOutdatedCommentDoesNotCount() {
        let text = "This force unwrap crashes when the token is missing."
        var old = existing(line: 5, body: text)
        old.isOutdated = true
        let (inline, _, omitted) = pull(existing: [old]).comments(for: review(line: 5, comment: text), draft: ReviewDraft())
        #expect(inline.count == 1)
        #expect(omitted.isEmpty)
    }

    @Test func anOmittedFindingKeepsItsOwnText() {
        let text = "This force unwrap crashes when the token is missing."
        let (_, _, omitted) = pull(existing: [existing(line: 5, body: text)]).comments(for: review(line: 5, comment: text), draft: ReviewDraft())
        #expect(omitted.first?.comment == text)
    }

    @Test func yourOwnOutdatedCommentCountsWhereverItWas() {
        let text = "This force unwrap crashes when the token is missing."
        var old = existing(line: 18, body: text, author: "me")
        old.isOutdated = true
        let (inline, _, omitted) = pull(existing: [old]).comments(for: review(line: 5, comment: text), draft: ReviewDraft())
        #expect(inline.isEmpty)
        #expect(omitted.first?.author == "me")
    }

    @Test func aBodyFindingInAnEarlierReviewIsLeftOut() {
        let text = "The retry here never stops when the server keeps failing."
        let body = "Looks good apart from one thing.\n\n- `B.swift:40`: \(text)"
        let (_, general, omitted) = pull(reviews: [earlier(body)]).comments(for: review(line: 40, comment: text, path: "B.swift"), draft: ReviewDraft())
        #expect(general.isEmpty)
        #expect(omitted.first?.path == "B.swift")
        #expect(omitted.first?.said.contains("retry") == true)
    }

    @Test func aBodyFindingWithNoLineInAnEarlierReviewIsLeftOut() {
        let text = "Nothing tests the new parser yet; add a test for an empty file."
        let body = "Summary.\n\n- `C.swift`: nothing tests the new parser yet. Add a test for an empty file!"
        let (_, general, omitted) = pull(reviews: [earlier(body, author: "alex")]).comments(for: review(line: nil, comment: text, path: "C.swift"), draft: ReviewDraft())
        #expect(general.isEmpty)
        #expect(omitted.first?.line == nil)
        #expect(omitted.first?.author == "alex")
    }

    @Test func aNewBodyFindingIsPosted() {
        let body = "Summary.\n\n- `B.swift:40`: The retry here never stops when the server keeps failing."
        let (_, general, omitted) = pull(reviews: [earlier(body)])
            .comments(for: review(line: 40, comment: "This log line prints the user's token in full.", path: "B.swift"), draft: ReviewDraft())
        #expect(general.count == 1)
        #expect(omitted.isEmpty)
    }

    @Test func theSamePointAboutAnotherFileIsPosted() {
        let text = "The retry here never stops when the server keeps failing."
        let body = "Summary.\n\n- `B.swift:40`: \(text)"
        let (_, general, omitted) = pull(reviews: [earlier(body)]).comments(for: review(line: 40, comment: text, path: "D.swift"), draft: ReviewDraft())
        #expect(general.count == 1)
        #expect(omitted.isEmpty)
    }

    @Test func anInlineFindingAnEarlierReviewPutInItsBodyIsLeftOut() {
        let text = "This force unwrap crashes when the token is missing."
        let (inline, _, omitted) = pull(reviews: [earlier("Summary.\n\n- `A.swift:90`: \(text)")]).comments(for: review(line: 5, comment: text), draft: ReviewDraft())
        #expect(inline.isEmpty)
        #expect(omitted.count == 1)
    }

    @Test func aBodyFindingAlreadyCommentedInlineIsLeftOut() {
        let text = "This force unwrap crashes when the token is missing."
        let (_, general, omitted) = pull(existing: [existing(line: 12, body: text)]).comments(for: review(line: nil, comment: text), draft: ReviewDraft())
        #expect(general.isEmpty)
        #expect(omitted.count == 1)
    }

    @Test func aNewInlineFindingIsPostedAlongsideLeftOutOnes() {
        let text = "This force unwrap crashes when the token is missing."
        let result = SessionTranscript.ReviewResult(summary: "s", verdict: "comment", findings: [
            .init(path: "A.swift", line: 5, comment: text, suggestion: nil),
            .init(path: "A.swift", line: 6, comment: "Rename this to match the other handlers.", suggestion: nil),
        ])
        let (inline, _, omitted) = pull(existing: [existing(line: 5, body: text)]).comments(for: result, draft: ReviewDraft())
        #expect(inline.count == 1)
        #expect(omitted.count == 1)
    }
}
