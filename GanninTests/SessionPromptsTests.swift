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

    @Test func aThreadsFirstCommentIDDecodesIntoItsFeedback() throws {
        let json = #"""
        {"id": "PR_1", "number": 7, "title": "T", "url": "https://github.com/acme/app/pull/7", "state": "OPEN",
         "repository": {"nameWithOwner": "acme/app"},
         "reviewThreads": {"nodes": [
           {"id": "T1", "isResolved": false, "isOutdated": false, "path": "a.swift", "line": 3, "originalLine": 3,
            "root": {"nodes": [{"databaseId": 99}]},
            "comments": {"nodes": [{"author": {"login": "rev"}, "body": "rename", "url": "https://github.com/acme/app/pull/7#discussion_r99"}]}},
           {"id": "T2", "isResolved": false, "isOutdated": false, "path": "b.swift", "line": 4, "originalLine": 4,
            "comments": {"nodes": [{"author": {"login": "rev"}, "body": "nit", "url": "https://github.com/acme/app/pull/7#discussion_r5"}]}}
         ]}}
        """#
        let raw = try JSONDecoder().decode(SessionRawPullRequest.self, from: Data(json.utf8))
        #expect(raw.model?.feedback.map(\.replyID) == [99, nil])
    }

    @Test func noReplyInstructionWhenTurnedOff() {
        let thread = SessionPullRequest.Feedback(id: "T1", author: "rev", location: "a.swift:3", verdict: nil, comments: [comment("rename")], replyID: 99)
        let prompt = SessionPrompts.feedback([thread], on: pullRequest([thread]), in: session, asksForReplies: false)
        #expect(!prompt.contains("reply ID"))
    }

    @Test func conflictsPromptNamesThePullRequestAndAsksForAPush() {
        let prompt = SessionPrompts.conflicts(pullRequest([]), in: session)
        #expect(prompt.contains("acme/app#7"))
        #expect(prompt.contains("https://github.com/acme/app/pull/7"))
        #expect(prompt.contains("push"))
    }

    @Test func conflictsPromptNamesTheBaseAndLimitsForcePushing() {
        var pr = pullRequest([])
        pr.baseRef = "main"
        let prompt = SessionPrompts.conflicts(pr, in: session)
        #expect(prompt.contains("remote that points at acme/app"))
        #expect(prompt.contains("its `main`"))
        #expect(prompt.contains("--force-with-lease"))
        #expect(prompt.contains("never to main"))
    }

    @Test func noReplyInstructionWithoutAThread() {
        let review = SessionPullRequest.Feedback(id: "R1", author: "rev", location: nil, verdict: nil, comments: [comment("overall")])
        let prompt = SessionPrompts.feedback([review], on: pullRequest([review]), in: session)
        #expect(!prompt.contains("/replies"))
    }
}
