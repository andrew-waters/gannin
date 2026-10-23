import Foundation
import Testing
@testable import Gannin

/// The Pull Requests page's filters: Hide drafts (andrew-waters/gannin#475),
/// and Hide These, Hide reviewed and Checks (andrew-waters/gannin#484).
struct PullRequestFiltersTests {
    private func person(_ login: String) -> Person { Person(login: login, name: nil, avatarUrl: nil) }

    private func pr(
        _ id: String, isDraft: Bool = false, repo: String = "acme/api", author: String = "author",
        requested: [String] = [], reviewers: [String] = [], checks: ItemDetail.CheckState? = nil
    ) -> PullRequest {
        PullRequest(
            id: id, number: 1, title: "T", url: URL(string: "https://github.com/\(repo)/pull/1")!, repo: repo,
            author: person(author), isDraft: isDraft, state: "OPEN", createdAt: .now, updatedAt: .now,
            mergedAt: nil, reviewDecision: nil, additions: 0, deletions: 0, changedFiles: 0, assignees: [],
            requestedReviewers: requested.map(person), reviewRequestedAt: [:], reviewers: reviewers.map(person), linkedIssues: [],
            checks: checks, reviewStates: [:], reviewedAt: [:], lastCommitAt: nil, authorRepliedAt: nil
        )
    }

    @Test func showsDraftsUntilHidden() {
        let draft = pr("d", isDraft: true), ready = pr("r", isDraft: false)
        var filters = PullRequestFilters()
        #expect(filters.matches(draft) && filters.matches(ready))
        #expect(!filters.isNarrowed)

        filters.hideDrafts = true
        #expect(!filters.matches(draft))
        #expect(filters.matches(ready))
        #expect(filters.isNarrowed)
    }

    @Test func statusMenuCountsLeaveOutHiddenDrafts() {
        let filters = PullRequestFilters(hideDrafts: true)
        #expect(!filters.matches(pr("d", isDraft: true), except: .status))
    }

    @Test func hideTheseHidesThePickedValues() {
        let api = pr("a", repo: "acme/api"), web = pr("w", repo: "acme/web")
        var filters = PullRequestFilters(values: [.repository: ["acme/api"]])
        #expect(filters.matches(api) && !filters.matches(web))

        filters.excluding = [.repository]
        #expect(!filters.matches(api) && filters.matches(web))
    }

    @Test func hideTheseWithNothingPickedHidesNothing() {
        let filters = PullRequestFilters(excluding: [.author])
        #expect(filters.matches(pr("a")))
        #expect(!filters.isNarrowed)
    }

    @Test func excludedAuthorCombinesWithIncludedRepo() {
        let filters = PullRequestFilters(values: [.repository: ["acme/api"], .author: ["sam"]], excluding: [.author])
        #expect(filters.matches(pr("1", repo: "acme/api", author: "kim")))
        #expect(!filters.matches(pr("2", repo: "acme/api", author: "sam")))
        #expect(!filters.matches(pr("3", repo: "acme/web", author: "kim")))
    }

    @Test func hideReviewedUntilAskedAgain() {
        let filters = PullRequestFilters(hideReviewed: true)
        #expect(filters.isNarrowed)
        #expect(!filters.matches(pr("r", reviewers: ["me"]), viewerLogin: "me"))
        #expect(filters.matches(pr("again", requested: ["me"], reviewers: ["me"]), viewerLogin: "me"))
        #expect(filters.matches(pr("asked", requested: ["me"]), viewerLogin: "me"))
        #expect(filters.matches(pr("other", reviewers: ["sam"]), viewerLogin: "me"))
    }

    @Test func checksPreferTheFresherState() {
        let filters = PullRequestFilters(values: [.checks: [PullRequestFilters.Checks.failing.rawValue]])
        let running = pr("c", checks: .pending)
        #expect(!filters.matches(running))
        #expect(filters.matches(running, checks: { _ in .error }))
        #expect(PullRequestFilters.Checks(nil) == .noChecks)
    }
}
