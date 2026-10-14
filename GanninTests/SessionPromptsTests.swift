import Foundation
import Testing
@testable import Gannin

/// What Claude is told when review feedback is sent to it.
@MainActor
struct SessionPromptsTests {
    private let session: CodeSession = {
        let issue = IssueReference(org: "acme", id: "I_1", number: 1, title: "Issue", repo: "acme/app",
                                   url: URL(string: "https://github.com/acme/app/issues/1")!)
        return CodeSession(id: UUID(), issue: issue, repo: "acme/app", branch: "b", createdAt: .now)
    }()

    private func pullRequest(_ feedback: [SessionPullRequest.Feedback]) -> SessionPullRequest {
        SessionPullRequest(id: "PR_1", number: 7, title: "T", url: URL(string: "https://github.com/acme/app/pull/7")!, repo: "acme/app",
                           author: "me", state: "OPEN", isDraft: false, reviewDecision: nil, mergeable: nil, checks: [], feedback: feedback)
    }

    private func comment(_ body: String) -> SessionPullRequest.Comment {
        .init(author: "rev", body: body, url: URL(string: "https://github.com/acme/app/pull/7#discussion_r1")!)
    }

    @Test func repliesAreAskedForOnlyOnLineThreads() {
        let thread = SessionPullRequest.Feedback(id: "T1", author: "rev", location: "a.swift:3", verdict: nil, comments: [comment("rename")], replyID: 99)
        let review = SessionPullRequest.Feedback(id: "R1", author: "rev", location: nil, verdict: "changes requested", comments: [comment("overall")])
        let prompt = SessionPrompts.feedback([thread, review], on: pullRequest([thread, review]), in: session, asksForReplies: true)
        #expect(prompt.contains("repos/acme/app/pulls/7/comments/<reply ID>/replies"))
        #expect(prompt.contains("@rev on `a.swift:3` (reply ID 99):"))
        #expect(prompt.components(separatedBy: "(reply ID ").count == 2)
    }

    @Test func noReplyInstructionWhenTurnedOff() {
        let thread = SessionPullRequest.Feedback(id: "T1", author: "rev", location: "a.swift:3", verdict: nil, comments: [comment("rename")], replyID: 99)
        let prompt = SessionPrompts.feedback([thread], on: pullRequest([thread]), in: session, asksForReplies: false)
        #expect(!prompt.contains("reply ID"))
    }

    @Test func noReplyInstructionWithoutAThread() {
        let review = SessionPullRequest.Feedback(id: "R1", author: "rev", location: nil, verdict: nil, comments: [comment("overall")])
        let prompt = SessionPrompts.feedback([review], on: pullRequest([review]), in: session)
        #expect(!prompt.contains("/replies"))
    }
}
