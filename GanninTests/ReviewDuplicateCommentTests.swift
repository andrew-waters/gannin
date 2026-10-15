import Foundation
import Testing
@testable import Gannin

/// Findings left out of a review because their line already has the same comment.
struct ReviewDuplicateCommentTests {
    private func pull(existing: [ReviewedPullRequest.ExistingComment]) -> ReviewedPullRequest {
        let lines = (1...20).map { DiffLine(id: $0, kind: .added, text: "x", newLine: $0) }
        return ReviewedPullRequest(
            title: "Fix it", body: "", author: "sam", headSHA: "abc", additions: 20, deletions: 0, state: "open",
            files: [.init(path: "A.swift", status: "modified", additions: 20, deletions: 0, lines: lines)],
            existingComments: existing
        )
    }

    private func existing(line: Int, isOld: Bool = false, body: String) -> ReviewedPullRequest.ExistingComment {
        .init(id: line, path: "A.swift", line: line, isOld: isOld, body: body, author: "alex", avatarURL: nil, createdAt: .now, url: nil)
    }

    private func review(line: Int, comment: String, suggestion: String? = nil) -> SessionTranscript.ReviewResult {
        .init(summary: "s", verdict: "comment", findings: [.init(path: "A.swift", line: line, comment: comment, suggestion: suggestion)])
    }

    @Test func sameCommentOnTheSameLineIsLeftOut() {
        let text = "This force unwrap crashes when the token is missing."
        let (inline, general, omitted) = pull(existing: [existing(line: 5, body: text)]).comments(for: review(line: 5, comment: text), draft: ReviewDraft())
        #expect(inline.isEmpty)
        #expect(general.isEmpty)
        #expect(omitted.count == 1)
        #expect(omitted.first?.existing.author == "alex")
    }

    @Test func rewordedCommentOnTheSameLineIsLeftOut() {
        let reworded = "this force-unwrap will crash if the token is missing"
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

    @Test func sameCommentOnAnotherLineIsKept() {
        let text = "This force unwrap crashes when the token is missing."
        let (inline, _, omitted) = pull(existing: [existing(line: 6, body: text)]).comments(for: review(line: 5, comment: text), draft: ReviewDraft())
        #expect(inline.count == 1)
        #expect(omitted.isEmpty)
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
        #expect(!ReviewedPullRequest.isSameComment("nit", "nit: rename this variable to something clearer"))
        #expect(ReviewedPullRequest.isSameComment("Rename this variable.", "rename this variable"))
    }
}
