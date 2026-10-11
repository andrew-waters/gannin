import Foundation
import Testing
@testable import Gannin

/// `IssueStore.sync` extended to a project's outside repos, the issue
/// history's version of what `GitHubAPI.snapshot` already does for the
/// workload (andrew-waters/gannin#205, R14).
struct IssueHistoryOutsideRepoTests {
    private let now = Date(timeIntervalSince1970: 1_760_000_000) // 2025-10-09
    private let start = Date(timeIntervalSince1970: 1_759_000_000)

    private func history(coveredFrom: Date, syncedAt: Date, openFetchedAt: Date) -> IssueHistory {
        IssueHistory(orgLogin: "acme", coveredFrom: coveredFrom, syncedAt: syncedAt, openFetchedAt: openFetchedAt, issues: [:])
    }

    private func issue(id: String, repo: String, closedAt: Date? = nil) -> IssueRecord {
        IssueRecord(
            id: id, number: 1, title: "An issue", url: URL(string: "https://github.com/\(repo)/issues/1")!, repo: repo,
            author: "alex", assignees: [], labels: [], issueType: nil, milestone: nil, parentID: nil,
            createdAt: .now, closedAt: closedAt, stateReason: closedAt.map { _ in "COMPLETED" }, statusChanges: [], assignedAt: [], reopenedAt: [],
            subIssuesAddedAt: [], linkedPullRequests: [], mentionedInPullRequests: nil, projectFields: []
        )
    }

    // MARK: outsideRepoPlan

    @Test func unknownReadabilitySkipsOutsideRepsEntirely() {
        // The workload snapshot hasn't loaded yet (unreadable: nil):
        // guessing "all readable" could search, and so prune, a repo
        // that's actually unreadable.
        let (searchable, newBatches, knownBatches) = IssueStore.outsideRepoPlan(
            ["client/app"], priorFetched: ["client/app"], unreadable: nil
        )
        #expect(newBatches.isEmpty)
        #expect(knownBatches.isEmpty)
        // Its existing baseline is left exactly as it was, not cleared.
        #expect(searchable == ["client/app"])
    }

    @Test func knownReadabilitySplitsIntoCohortsAsUsual() {
        let (searchable, newBatches, knownBatches) = IssueStore.outsideRepoPlan(
            ["client/app", "other/thing"], priorFetched: ["client/app"], unreadable: [:]
        )
        #expect(searchable == ["client/app", "other/thing"])
        #expect(newBatches == [["other/thing"]])
        #expect(knownBatches == [["client/app"]])
    }

    @Test func aRepoTheSnapshotFoundUnreadableIsLeftOutOfBothCohorts() {
        let (searchable, newBatches, knownBatches) = IssueStore.outsideRepoPlan(
            ["client/app"], priorFetched: ["client/app"], unreadable: ["client/app": "Not found"]
        )
        #expect(searchable.isEmpty)
        #expect(newBatches.isEmpty)
        #expect(knownBatches.isEmpty)
    }

    // MARK: plannedSearches

    @Test func noOutsideReposSendsExactlyTodaysSearchesWithNoHistory() {
        let searches = IssueStore.plannedSearches(
            accountScope: "org:acme archived:false is:issue", start: start, now: now, history: nil,
            changedSince: nil, openDue: true, newBatches: [], knownBatches: []
        )
        #expect(searches.allSatisfy { $0.repos == nil })
        #expect(searches.filter { $0.kind == .open }.count == 1)
        #expect(searches.contains { $0.kind == .open && $0.query == "org:acme archived:false is:issue is:open" })
        #expect(searches.contains { $0.kind == .closed })
        #expect(!searches.contains { $0.kind == .changed })
    }

    @Test func noOutsideReposSendsExactlyTodaysSearchesWithHistory() {
        let existing = history(coveredFrom: start, syncedAt: now, openFetchedAt: now)
        let searches = IssueStore.plannedSearches(
            accountScope: "org:acme archived:false is:issue", start: start, now: now, history: existing,
            changedSince: now.addingTimeInterval(-300), openDue: false, newBatches: [], knownBatches: []
        )
        #expect(searches.count == 1)
        #expect(searches[0].kind == .changed)
        #expect(searches[0].repos == nil)
    }

    @Test func aNewOutsideRepoGetsAFullBackfillRegardlessOfWhatsDue() {
        let existing = history(coveredFrom: start, syncedAt: now, openFetchedAt: now)
        let searches = IssueStore.plannedSearches(
            accountScope: "org:acme archived:false is:issue", start: start, now: now, history: existing,
            changedSince: nil, openDue: false, newBatches: [["client/app"]], knownBatches: []
        )
        let open = searches.filter { $0.kind == .open }
        #expect(open.count == 1)
        #expect(open[0].repos == ["client/app"])
        #expect(open[0].query == "repo:client/app archived:false is:issue is:open")
        #expect(searches.contains { $0.kind == .closed && $0.repos == ["client/app"] })
    }

    @Test func aNewOutsideRepoBackfillsAsFarAsTheHistorysRealCoverage() {
        // The window's own start is more recent than the history's
        // coveredFrom (a longer window, or All time, asked for it since);
        // a newly named repo has to match that depth, not just the
        // window, or its coverage would be narrower than the history claims.
        let deeperCoveredFrom = start.addingTimeInterval(-14 * 24 * 60 * 60)
        let existing = history(coveredFrom: deeperCoveredFrom, syncedAt: now, openFetchedAt: now)
        let searches = IssueStore.plannedSearches(
            accountScope: "org:acme archived:false is:issue", start: start, now: now, history: existing,
            changedSince: nil, openDue: false, newBatches: [["client/app"]], knownBatches: []
        )
        let closed = searches.filter { $0.kind == .closed && $0.repos == ["client/app"] }
        // Backfilling from the window's start alone would need fewer weeks
        // than backfilling from the history's deeper coverage.
        #expect(closed.count == ParallelSearches.weeks(from: deeperCoveredFrom, to: now).count)
        #expect(closed.count > ParallelSearches.weeks(from: start, to: now).count)
    }

    @Test func aKnownOutsideRepoOnlyGetsAChangesSearchWhenOneIsDue() {
        let existing = history(coveredFrom: start, syncedAt: now, openFetchedAt: now)
        let searches = IssueStore.plannedSearches(
            accountScope: "org:acme archived:false is:issue", start: start, now: now, history: existing,
            changedSince: nil, openDue: false, newBatches: [], knownBatches: [["client/app"]]
        )
        #expect(searches.isEmpty)
    }

    @Test func aKnownOutsideRepoGetsAChangesAndOpenSearchWhenDue() {
        let existing = history(coveredFrom: start, syncedAt: now, openFetchedAt: now)
        let since = now.addingTimeInterval(-300)
        let searches = IssueStore.plannedSearches(
            accountScope: "org:acme archived:false is:issue", start: start, now: now, history: existing,
            changedSince: since, openDue: true, newBatches: [], knownBatches: [["client/app"]]
        )
        #expect(searches.contains { $0.kind == .changed && $0.repos == ["client/app"] })
        #expect(searches.contains { $0.kind == .open && $0.repos == ["client/app"] })
        // And the account's own two searches alongside.
        #expect(searches.contains { $0.kind == .changed && $0.repos == nil })
        #expect(searches.contains { $0.kind == .open && $0.repos == nil })
        #expect(searches.count == 4)
    }

    @Test func aKnownOutsideRepoGetsTheSameClosedBackfillGapAsTheAccountsOwn() {
        let coveredFrom = start.addingTimeInterval(7 * 24 * 60 * 60)
        let existing = history(coveredFrom: coveredFrom, syncedAt: now, openFetchedAt: now)
        let searches = IssueStore.plannedSearches(
            accountScope: "org:acme archived:false is:issue", start: start, now: now, history: existing,
            changedSince: nil, openDue: false, newBatches: [], knownBatches: [["client/app"]]
        )
        #expect(searches.contains { $0.kind == .closed && $0.repos == nil })
        #expect(searches.contains { $0.kind == .closed && $0.repos == ["client/app"] })
    }

    // MARK: isCapped

    @Test func aPrecisePreflightCountDecidesCapping() {
        #expect(IssueStore.isCapped(count: 1500, repoScoped: false, totalRecords: 10, cap: 1000))
        #expect(!IssueStore.isCapped(count: 500, repoScoped: false, totalRecords: 10, cap: 1000))
        #expect(!IssueStore.isCapped(count: 500, repoScoped: true, totalRecords: 10, cap: 1000))
    }

    @Test func anOutsideBatchWithNoCountIsTreatedAsCappedSoNothingIsWronglyDropped() {
        #expect(IssueStore.isCapped(count: nil, repoScoped: true, totalRecords: 5, cap: 1000))
    }

    @Test func theAccountsOwnSearchFallsBackToTheRoundsTotalRecordCount() {
        #expect(!IssueStore.isCapped(count: nil, repoScoped: false, totalRecords: 5, cap: 1000))
        #expect(IssueStore.isCapped(count: nil, repoScoped: false, totalRecords: 1000, cap: 1000))
    }

    // MARK: pruneStaleOpenIssues

    @Test func anOpenIssueMissingFromAnUncappedRefetchIsDropped() {
        let issues = [
            "I_1": issue(id: "I_1", repo: "acme/api"),
            "I_2": issue(id: "I_2", repo: "acme/api")
        ]
        let pruned = IssueStore.pruneStaleOpenIssues(issues, fetchedIDs: ["I_1"], scope: nil, outside: [])
        #expect(Set(pruned.keys) == ["I_1"])
    }

    @Test func aClosedIssueIsNeverDropped() {
        let issues = ["I_1": issue(id: "I_1", repo: "acme/api", closedAt: .now)]
        let pruned = IssueStore.pruneStaleOpenIssues(issues, fetchedIDs: [], scope: nil, outside: [])
        #expect(pruned.keys.contains("I_1"))
    }

    @Test func anOutsideReposIssueSurvivesTheAccountsOwnRefetch() {
        // The account's own full open refetch (scope: nil) didn't mention
        // "client/app" at all; its issue, tracked separately, must stay.
        let issues = [
            "I_1": issue(id: "I_1", repo: "acme/api"),
            "I_2": issue(id: "I_2", repo: "client/app")
        ]
        let pruned = IssueStore.pruneStaleOpenIssues(issues, fetchedIDs: [], scope: nil, outside: ["client/app"])
        #expect(Set(pruned.keys) == ["I_2"])
    }

    @Test func aBatchsRefetchOnlyPrunesItsOwnRepos() {
        let issues = [
            "I_1": issue(id: "I_1", repo: "client/app"),
            "I_2": issue(id: "I_2", repo: "other/thing")
        ]
        // Only "client/app" is this round's batch; "other/thing" (another
        // outside repo, not due this round) is left exactly as it was.
        let pruned = IssueStore.pruneStaleOpenIssues(issues, fetchedIDs: [], scope: ["client/app"], outside: ["client/app", "other/thing"])
        #expect(Set(pruned.keys) == ["I_2"])
    }
}
