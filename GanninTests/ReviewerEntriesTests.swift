import Foundation
import Testing
@testable import Gannin

/// Who's been asked to review a PR and who has (andrew-waters/gannin#468).
struct ReviewerEntriesTests {
    private func person(_ login: String) -> Person { Person(login: login, name: nil, avatarUrl: nil) }

    private func pr(requested: [String] = [], reviewed: [String: String] = [:], teams: [String]? = nil) -> PullRequest {
        PullRequest(
            id: "pr", number: 1, title: "T", url: URL(string: "https://github.com/acme/api/pull/1")!, repo: "acme/api",
            author: nil, isDraft: false, state: "OPEN", createdAt: .now, updatedAt: .now, mergedAt: nil, reviewDecision: nil,
            additions: 0, deletions: 0, changedFiles: 0, assignees: [], requestedReviewers: requested.map(person), reviewRequestedAt: [:],
            reviewers: reviewed.keys.sorted().map(person), linkedIssues: [], checks: nil, reviewStates: reviewed, reviewedAt: [:],
            lastCommitAt: nil, authorRepliedAt: nil, requestedTeams: teams
        )
    }

    @Test func thoseAskedComeFirstThenEachLatestReview() {
        let entries = pr(requested: ["cat"], reviewed: ["ann": "APPROVED", "bob": "CHANGES_REQUESTED", "dee": "DISMISSED"]).reviewerEntries
        #expect(entries.map(\.person.login) == ["cat", "ann", "bob", "dee"])
        #expect(entries.map(\.standing) == [.waiting, .approved, .changesRequested, .reviewed])
    }

    @Test func someoneAskedAgainAfterReviewingIsWaiting() {
        let entries = pr(requested: ["ann"], reviewed: ["ann": "COMMENTED"]).reviewerEntries
        #expect(entries.map(\.person.login) == ["ann"])
        #expect(entries.first?.standing == .waiting)
    }

    @Test func noOneAskedOrReviewedHasNoEntries() {
        #expect(pr().reviewerEntries.isEmpty)
    }

    @Test func aTeamAskedIsAReviewerForTheFilters() {
        #expect(PullRequestFilters.reviewers(pr(teams: ["acme/backend"])) == ["acme/backend"])
        #expect(PullRequestFilters.reviewers(pr(teams: nil)).isEmpty)
    }

    @Test func aPullRequestOnlyATeamIsAskedOnIsWaitingOnTheTeam() {
        #expect(Inbox.standing(pr(teams: ["acme/backend"])).text == "Waiting on @acme/backend")
        #expect(Inbox.standing(pr(requested: ["ann"], teams: ["acme/backend"])).text == "Waiting on ann, @acme/backend")
        #expect(Inbox.standing(pr()).text == "No reviewer")
    }
}
