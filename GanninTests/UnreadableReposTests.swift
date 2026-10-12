import Foundation
import Testing
@testable import Gannin

/// Outside repos that stop being readable: left out of searches, their
/// last items carried over stale on a full fetch (andrew-waters/gannin#174, R8).
struct UnreadableReposTests {
    private func pr(_ id: String, repo: String) -> PullRequest {
        PullRequest(
            id: id, number: 1, title: "T", url: URL(string: "https://github.com/\(repo)/pull/1")!, repo: repo,
            author: nil, isDraft: false, state: "OPEN", createdAt: .now, updatedAt: .now, mergedAt: nil, reviewDecision: nil,
            additions: 0, deletions: 0, changedFiles: 0, assignees: [], requestedReviewers: [], reviewRequestedAt: [:],
            reviewers: [], linkedIssues: [], checks: nil, reviewStates: [:], reviewedAt: [:], lastCommitAt: nil, authorRepliedAt: nil
        )
    }

    @Test func carriesOverAnUnreadableRepossPreviousItems() {
        let fresh = [pr("1", repo: "acme/api")]
        let previous = [pr("1", repo: "acme/api"), pr("2", repo: "client/app")]
        let result = GitHubAPI.carryingOverUnreadable(fresh, previous: previous, unreadable: ["client/app": "Not found"], repo: \.repo)
        #expect(Set(result.map(\.id)) == ["1", "2"])
    }

    @Test func leavesAReadableRepoToItsFreshResult() {
        let fresh = [pr("1", repo: "acme/api")]
        let previous = [pr("1", repo: "acme/api"), pr("2", repo: "acme/api")]
        // "2" went away (closed, merged elsewhere): acme/api isn't
        // unreadable, so nothing is carried over for it.
        let result = GitHubAPI.carryingOverUnreadable(fresh, previous: previous, unreadable: [:], repo: \.repo)
        #expect(result.map(\.id) == ["1"])
    }

    @Test func doesntDuplicateAnItemFreshAlreadyHas() {
        let fresh = [pr("2", repo: "client/app")]
        let previous = [pr("2", repo: "client/app")]
        let result = GitHubAPI.carryingOverUnreadable(fresh, previous: previous, unreadable: ["client/app": "Not found"], repo: \.repo)
        #expect(result.map(\.id) == ["2"])
    }

    @Test func noUnreadableReposCarriesOverNothing() {
        let fresh = [pr("1", repo: "acme/api")]
        let previous = [pr("1", repo: "acme/api"), pr("2", repo: "client/app")]
        let result = GitHubAPI.carryingOverUnreadable(fresh, previous: previous, unreadable: [:], repo: \.repo)
        #expect(result.map(\.id) == ["1"])
    }

    @Test func olderSnapshotsDecodeWithNoUnreadableRepos() throws {
        let json = """
            {"orgLogin":"acme","fetchedAt":"2026-01-01T00:00:00Z","lookbackDays":14,"members":[],"teams":[],
             "openPullRequests":[],"mergedPullRequests":[],"issues":[],"warnings":[]}
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(OrgSnapshot.self, from: Data(json.utf8))
        #expect(snapshot.unreadableRepos == nil)
    }
}
