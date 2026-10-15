import Foundation
import Testing
@testable import Gannin

/// Noticing a session's PR conflicting, resolving and conflicting again.
@MainActor
struct SessionConflictTests {
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

    @Test func aConflictThatClearsWhileQueuedIsNotSentButOtherFeedbackIs() {
        let folder = FileManager.default.temporaryDirectory.appending(path: "SessionConflictTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SessionStore(harness: HarnessStore(auth: AuthStore()), directory: folder, saveDelay: .seconds(60), defaults: UserDefaults(suiteName: "SessionConflictTests-\(UUID().uuidString)")!)
        let id = UUID()
        store.pendingFeedback[id] = [("checks prompt", ["checks:PR_1:a"]), ("conflict prompt", ["conflicts:PR_1"])]
        store.markSent(["conflicts:PR_1"], for: id)

        store.forgetSent(["conflicts:PR_1"], for: id)
        #expect(store.pendingFeedback[id]?.map(\.prompt) == ["checks prompt"])
        #expect(store.sent[id]?.contains("conflicts:PR_1") == false)

        store.forgetSent(["checks:PR_1:a"], for: id)
        #expect(store.pendingFeedback[id] == nil)
    }
}
