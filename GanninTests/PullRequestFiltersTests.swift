import Foundation
import Testing
@testable import Gannin

/// Hide drafts on the Pull Requests page (andrew-waters/gannin#475).
struct PullRequestFiltersTests {
    private func pr(_ id: String, isDraft: Bool) -> PullRequest {
        PullRequest(
            id: id, number: 1, title: "T", url: URL(string: "https://github.com/acme/api/pull/1")!, repo: "acme/api",
            author: Person(login: "author", name: nil, avatarUrl: nil), isDraft: isDraft, state: "OPEN", createdAt: .now, updatedAt: .now,
            mergedAt: nil, reviewDecision: nil, additions: 0, deletions: 0, changedFiles: 0, assignees: [], requestedReviewers: [],
            reviewRequestedAt: [:], reviewers: [], linkedIssues: [], checks: nil, reviewStates: [:], reviewedAt: [:],
            lastCommitAt: nil, authorRepliedAt: nil
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
}
