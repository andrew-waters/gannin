import Foundation
import Testing
@testable import Gannin

/// A session can be finished once none of its pull requests can still change: each is merged or closed.
struct SessionFinishedTests {
    private func store() -> SessionStore {
        let folder = FileManager.default.temporaryDirectory.appending(path: "SessionFinishedTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        return SessionStore(harness: HarnessStore(auth: AuthStore()), directory: folder, saveDelay: .seconds(60), defaults: UserDefaults(suiteName: "SessionFinishedTests-\(UUID().uuidString)")!)
    }

    private func pullRequest(_ number: Int, state: String) -> SessionPullRequest {
        SessionPullRequest(
            id: "PR_\(number)", number: number, title: "PR \(number)", url: URL(string: "https://github.com/acme/app/pull/\(number)")!,
            repo: "acme/app", author: nil, state: state, isDraft: false, reviewDecision: nil, mergeable: nil, checks: [], feedback: []
        )
    }

    private func isFinished(_ states: [String]?) -> Bool {
        let store = store()
        let id = UUID()
        if let states { store.pullRequestInfo[id] = states.enumerated().map { pullRequest($0.offset + 1, state: $0.element) } }
        return store.isFinished(id)
    }

    @Test func everyPullRequestMergedIsFinished() {
        #expect(isFinished(["MERGED", "MERGED"]))
    }

    @Test func aMergedAndAClosedPullRequestIsFinished() {
        #expect(isFinished(["MERGED", "CLOSED"]))
    }

    @Test func everyPullRequestClosedIsFinished() {
        #expect(isFinished(["CLOSED", "CLOSED"]))
    }

    @Test func anOpenPullRequestIsNotFinished() {
        #expect(!isFinished(["MERGED", "CLOSED", "OPEN"]))
    }

    @Test func noPullRequestsIsNotFinished() {
        #expect(!isFinished([]))
        #expect(!isFinished(nil))
    }
}
