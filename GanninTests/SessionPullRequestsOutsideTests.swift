import Foundation
import Testing
@testable import Gannin

/// A session's branch search finding PRs on a repo the account doesn't
/// own (andrew-waters/gannin#176, R13).
struct SessionPullRequestsOutsideTests {
    @Test func qualifiesARepoTheAccountDoesntOwn() {
        #expect(GitHubAPI.outsideRepoQualifiers(["client/app"], org: "acme") == "repo:client/app")
    }

    @Test func leavesOutTheAccountsOwnRepoCaseAside() {
        #expect(GitHubAPI.outsideRepoQualifiers(["Acme/api"], org: "acme") == "")
    }

    @Test func combinesSeveralOutsideReposInOrder() {
        #expect(GitHubAPI.outsideRepoQualifiers(["client/app", "acme/api", "other/thing"], org: "acme") == "repo:client/app repo:other/thing")
    }

    @Test func emptyWithNoRepos() {
        #expect(GitHubAPI.outsideRepoQualifiers([], org: "acme") == "")
    }
}
