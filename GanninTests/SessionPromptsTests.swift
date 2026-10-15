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
        #expect(prompt.contains("`origin/main`"))
        #expect(prompt.contains("--force-with-lease"))
        #expect(prompt.contains("never to main"))
    }

    private func pullRequest(id: String = "PR_1", mergeable: String?, state: String = "OPEN") -> SessionPullRequest {
        SessionPullRequest(id: id, number: 7, title: "T", url: URL(string: "https://github.com/acme/app/pull/7")!, repo: "acme/app",
                           author: "me", state: state, isDraft: false, reviewDecision: nil, mergeable: mergeable, checks: [], feedback: [])
    }

    @Test func aNewConflictIsReportedOnceAndAClearedOneCanComeBack() {
        let conflicting = pullRequest(mergeable: "CONFLICTING")
        let first = SessionStore.conflictChanges(in: [conflicting], seen: [])
        #expect(first.new.map(\.id) == ["PR_1"])
        #expect(first.keys == ["conflicts:PR_1"])

        let again = SessionStore.conflictChanges(in: [conflicting], seen: first.keys)
        #expect(again.new.isEmpty)

        let resolved = SessionStore.conflictChanges(in: [pullRequest(mergeable: "MERGEABLE")], seen: first.keys)
        #expect(resolved.cleared == ["conflicts:PR_1"])
        let back = SessionStore.conflictChanges(in: [conflicting], seen: first.keys.subtracting(resolved.cleared))
        #expect(back.new.map(\.id) == ["PR_1"])
    }

    @Test func aPullRequestGitHubHasntCheckedYetChangesNothingUntilItConflicts() {
        let unknown = SessionStore.conflictChanges(in: [pullRequest(mergeable: "UNKNOWN")], seen: [])
        #expect(unknown.new.isEmpty && unknown.cleared.isEmpty)
        let seen = SessionStore.conflictChanges(in: [pullRequest(mergeable: "CONFLICTING")], seen: [])
        #expect(seen.new.count == 1)
        // Unknown again after a conflict was seen doesn't clear it.
        #expect(SessionStore.conflictChanges(in: [pullRequest(mergeable: "UNKNOWN")], seen: seen.keys).cleared.isEmpty)
    }

    @Test func closedPullRequestsAreIgnored() {
        let closed = SessionStore.conflictChanges(in: [pullRequest(mergeable: "CONFLICTING", state: "CLOSED")], seen: [])
        #expect(closed.new.isEmpty && closed.keys.isEmpty)
    }

    @Test func noReplyInstructionWithoutAThread() {
        let review = SessionPullRequest.Feedback(id: "R1", author: "rev", location: nil, verdict: nil, comments: [comment("overall")])
        let prompt = SessionPrompts.feedback([review], on: pullRequest([review]), in: session)
        #expect(!prompt.contains("/replies"))
    }
}
