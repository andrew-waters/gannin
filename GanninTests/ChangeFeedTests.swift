import Foundation
import Testing
@testable import Gannin

/// The change feed one search per org keeps, and what each store takes from
/// it instead of running its own "updated since" search (andrew-waters/gannin#231).
struct ChangeFeedTests {
    private let base = Date(timeIntervalSince1970: 1_760_000_000)

    private func at(_ minutes: Double) -> Date { base.addingTimeInterval(minutes * 60) }

    private func entry(_ id: String, _ minutes: Double, kind: ChangeEntry.Kind = .pullRequest, state: String = "OPEN", repo: String = "acme/api", outside: Bool = false) -> ChangeEntry {
        ChangeEntry(id: id, kind: kind, state: state, repo: repo, updatedAt: at(minutes), isOutside: outside)
    }

    private func feed(_ entries: [ChangeEntry], from minutes: Double = 0, outside: Set<String> = []) -> ChangeFeed {
        ChangeFeed(entries: Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) }), coveredFrom: at(minutes), lastRunAt: at(60), outsideRepos: outside)
    }

    private func ids(_ plan: ChangeFeed.Plan) -> [String]? {
        if case .fetch(let entries) = plan { return entries.map(\.id) }
        return nil
    }

    // MARK: plan

    @Test func fetchesWhatChangedSinceTheStoresCursorNewestFirst() {
        let feed = feed([entry("old", 5), entry("a", 20), entry("b", 30)])
        let plan = ChangeFeed.plan(feed: feed, cursor: at(10), stored: { _ in nil })
        #expect(ids(plan) == ["b", "a"])
    }

    @Test func skipsWhatTheStoreAlreadyHoldsAtThatTime() {
        let feed = feed([entry("held", 20), entry("stale", 30), entry("new", 40)])
        let held = ["held": at(20), "stale": at(25)]
        let plan = ChangeFeed.plan(feed: feed, cursor: at(10), stored: { held[$0] })
        #expect(ids(plan) == ["new", "stale"])
    }

    @Test func leavesOutWhatTheStoreDoesntInclude() {
        let feed = feed([entry("pr", 20), entry("issue", 21, kind: .issue), entry("elsewhere", 22, repo: "client/app", outside: true)])
        let plan = ChangeFeed.plan(feed: feed, cursor: at(10), include: { $0.kind == .issue && !$0.isOutside }, stored: { _ in nil })
        #expect(ids(plan) == ["issue"])
    }

    @Test func fallsBackWithNoFeed() {
        #expect(ChangeFeed.plan(feed: nil, cursor: at(10), stored: { _ in nil }) == .fallback)
    }

    @Test func fallsBackWhenTheFeedStartsAfterTheStoresCursor() {
        let feed = feed([entry("a", 50)], from: 40)
        #expect(ChangeFeed.plan(feed: feed, cursor: at(30), stored: { _ in nil }) == .fallback)
        #expect(ids(ChangeFeed.plan(feed: feed, cursor: at(40), stored: { _ in nil })) == ["a"])
    }

    @Test func aQuietFeedSaysNothingChanged() {
        #expect(ids(ChangeFeed.plan(feed: feed([]), cursor: at(10), stored: { _ in nil })) == [])
    }

    // MARK: updated

    @Test func theFirstRunStartsTheFeedAtItsSearch() {
        let result = ChangeFeed.updated(nil, found: [entry("a", 20)], capped: false, outsideRepos: [], since: at(10), now: at(30))
        #expect(result.coveredFrom == at(10))
        #expect(result.lastRunAt == at(30))
        #expect(Set(result.entries.keys) == ["a"])
    }

    @Test func laterRunsAddToWhatIsKeptAndTheNewestUpdateWins() {
        let first = ChangeFeed.updated(nil, found: [entry("a", 20), entry("b", 21)], capped: false, outsideRepos: [], since: at(10), now: at(30))
        let second = ChangeFeed.updated(first, found: [entry("a", 35), entry("c", 36)], capped: false, outsideRepos: [], since: at(25), now: at(40))
        #expect(Set(second.entries.keys) == ["a", "b", "c"])
        #expect(second.entries["a"]?.updatedAt == at(35))
        #expect(second.coveredFrom == at(10))
    }

    @Test func anUpdateOlderThanTheRetentionIsForgottenAndCoverageMovesUp() {
        let first = ChangeFeed.updated(nil, found: [entry("a", 0)], capped: false, outsideRepos: [], since: at(0), now: at(1))
        let later = ChangeFeed.updated(first, found: [], capped: false, outsideRepos: [], since: at(7 * 60), now: at(8 * 60))
        #expect(later.entries.isEmpty)
        #expect(later.coveredFrom == at(8 * 60).addingTimeInterval(-ChangeFeed.retention))
    }

    @Test func aCappedRunDropsEverythingSoOlderStoresFallBack() {
        let first = ChangeFeed.updated(nil, found: [entry("a", 20)], capped: false, outsideRepos: [], since: at(10), now: at(30))
        let capped = ChangeFeed.updated(first, found: [entry("b", 35)], capped: true, outsideRepos: [], since: at(25), now: at(40))
        #expect(capped.entries.isEmpty)
        #expect(capped.coveredFrom == at(40))
        #expect(ChangeFeed.plan(feed: capped, cursor: at(30), stored: { _ in nil }) == .fallback)
    }

    @Test func changingTheOutsideReposStartsTheFeedAgain() {
        let first = ChangeFeed.updated(nil, found: [entry("a", 20)], capped: false, outsideRepos: [], since: at(10), now: at(30))
        let added = ChangeFeed.updated(first, found: [entry("b", 35)], capped: false, outsideRepos: ["client/app"], since: at(28), now: at(40))
        #expect(Set(added.entries.keys) == ["b"])
        #expect(added.coveredFrom == at(28))
        #expect(added.outsideRepos == ["client/app"])
    }

    // MARK: outside repos

    @Test func fallsBackWhenTheFeedDoesntCoverAnOutsideRepoTheStoreNeeds() {
        let feed = feed([entry("a", 30)], outside: ["client/app"])
        #expect(ChangeFeed.plan(feed: feed, cursor: at(10), needing: ["client/app", "other/thing"], stored: { _ in nil }) == .fallback)
        #expect(ids(ChangeFeed.plan(feed: feed, cursor: at(10), needing: ["client/app"], stored: { _ in nil })) == ["a"])
        #expect(ids(ChangeFeed.plan(feed: feed, cursor: at(10), needing: [], stored: { _ in nil })) == ["a"])
    }

    // MARK: the issue history and work log

    private func record(_ id: String, updated: Double?) -> IssueRecord {
        IssueRecord(
            id: id, number: 1, title: "I", url: URL(string: "https://github.com/acme/api/issues/1")!, repo: "acme/api", author: nil,
            assignees: [], labels: [], issueType: nil, milestone: nil, parentID: nil, createdAt: at(0), closedAt: nil, stateReason: nil,
            statusChanges: [], assignedAt: [], reopenedAt: [], subIssuesAddedAt: [], linkedPullRequests: [], mentionedInPullRequests: nil,
            projectFields: [], updatedAt: updated.map(at)
        )
    }

    private func logged(_ id: String, updated: Double?) -> WorkLogPullRequest {
        WorkLogPullRequest(
            id: id, number: 1, title: "P", url: URL(string: "https://github.com/acme/api/pull/1")!, repo: "acme/api", author: nil,
            createdAt: at(0), mergedAt: nil, closedAt: nil, mergedBy: nil, commits: [], reviews: [], updatedAt: updated.map(at)
        )
    }

    @Test func theIssueHistoryTakesIssuesOnlyAndSkipsOnesItHolds() {
        let history = IssueHistory(orgLogin: "acme", coveredFrom: at(0), syncedAt: at(30), openFetchedAt: at(30), issues: [
            "held": record("held", updated: 20), "older": record("older", updated: 15), "unknown": record("unknown", updated: nil),
        ])
        let feed = feed([
            entry("held", 20, kind: .issue), entry("older", 25, kind: .issue), entry("unknown", 26, kind: .issue),
            entry("fresh", 27, kind: .issue), entry("pr", 28),
        ])
        guard case .fetch(let entries) = IssueStore.feedPlan(feed, cursor: at(10), history: history, knownOutside: []) else {
            Testing.Issue.record("expected a plan")
            return
        }
        #expect(Set(entries.map(\.id)) == ["older", "unknown", "fresh"])
    }

    @Test func theIssueHistorySearchesItselfWithoutAUsableFeedOrOneMissingARepo() {
        let history = IssueHistory(orgLogin: "acme", coveredFrom: at(0), syncedAt: at(30), openFetchedAt: at(30), issues: [:])
        #expect(IssueStore.feedPlan(nil, cursor: at(10), history: history, knownOutside: []) == .fallback)
        #expect(IssueStore.feedPlan(feed([], from: 20), cursor: at(10), history: history, knownOutside: []) == .fallback)
        #expect(IssueStore.feedPlan(feed([]), cursor: at(10), history: history, knownOutside: ["client/app"]) == .fallback)
    }

    @Test func anEmptyFeedMeansNothingChangedNotAFallback() {
        let history = IssueHistory(orgLogin: "acme", coveredFrom: at(0), syncedAt: at(30), openFetchedAt: at(30), issues: [:])
        #expect(IssueStore.feedPlan(feed([]), cursor: at(10), history: history, knownOutside: []) == .fetch([]))
    }

    @Test func theWorkLogTakesTheAccountsOwnPRsOnly() {
        let history = WorkLogHistory(orgLogin: "acme", coveredFrom: at(0), fetchedAt: at(30), pullRequests: [
            "held": logged("held", updated: 20), "unknown": logged("unknown", updated: nil),
        ])
        let feed = feed([
            entry("held", 20), entry("unknown", 21), entry("fresh", 22), entry("issue", 23, kind: .issue),
            entry("elsewhere", 24, repo: "client/app", outside: true),
        ], outside: ["client/app"])
        guard case .fetch(let entries) = WorkLogStore.feedPlan(feed, cursor: at(10), history: history) else {
            Testing.Issue.record("expected a plan")
            return
        }
        #expect(Set(entries.map(\.id)) == ["unknown", "fresh"])
        #expect(WorkLogStore.feedPlan(nil, cursor: at(10), history: history) == .fallback)
    }

    // MARK: the workload snapshot

    private func pr(_ id: String, state: String = "OPEN", updated: Double, merged: Double? = nil, repo: String = "acme/api") -> PullRequest {
        PullRequest(
            id: id, number: 1, title: "T", url: URL(string: "https://github.com/\(repo)/pull/1")!, repo: repo,
            author: nil, isDraft: false, state: state, createdAt: at(0), updatedAt: at(updated), mergedAt: merged.map(at), reviewDecision: nil,
            additions: 0, deletions: 0, changedFiles: 0, assignees: [], requestedReviewers: [], reviewRequestedAt: [:],
            reviewers: [], linkedIssues: [], checks: nil, reviewStates: [:], reviewedAt: [:], lastCommitAt: nil, authorRepliedAt: nil
        )
    }

    private func issue(_ id: String, state: String = "OPEN", updated: Double, repo: String = "acme/api") -> Gannin.Issue {
        Gannin.Issue(
            id: id, number: 1, title: "I", url: URL(string: "https://github.com/\(repo)/issues/1")!, repo: repo, author: nil,
            state: state, createdAt: at(0), updatedAt: at(updated), closedAt: nil, assignees: [], labels: [], linkedPullRequests: []
        )
    }

    private func snapshot(open: [PullRequest], merged: [PullRequest], issues: [Gannin.Issue]) -> OrgSnapshot {
        OrgSnapshot(
            orgLogin: "acme", fetchedAt: at(30), peopleFetchedAt: nil, fullFetchedAt: at(0), lookbackDays: 14, members: [], teams: [],
            openPullRequests: open, mergedPullRequests: merged, issues: issues, unreadableRepos: nil, outsideReposFetched: nil, warnings: []
        )
    }

    @Test func theSnapshotTakesFromTheFeedWhatItsOwnSearchWouldHaveFetched() {
        let previous = snapshot(
            open: [pr("open-same", updated: 20), pr("closing", updated: 20), pr("merging", updated: 20)],
            merged: [pr("merged-same", state: "MERGED", updated: 20, merged: 20)],
            issues: [issue("issue-same", updated: 20), issue("issue-closing", updated: 20)]
        )
        let feed = feed([
            entry("open-same", 35), entry("closing", 36, state: "CLOSED"), entry("merging", 37, state: "MERGED"),
            entry("merged-same", 20, state: "MERGED"), entry("new-pr", 38),
            entry("issue-same", 20, kind: .issue), entry("issue-closing", 39, kind: .issue, state: "CLOSED"), entry("new-issue", 40, kind: .issue),
        ])
        let changes = GitHubAPI.feedChanges(feed, since: at(25), previous: previous, knownOutside: [])
        // An open PR is fetched when updated since the cursor even when its
        // `updatedAt` is held, as its checks change without it moving; a
        // merged PR or issue already held at that time isn't.
        #expect(changes.map { Set($0.pullRequestIDs) } == ["open-same", "merging", "new-pr"])
        #expect(changes.map { Set($0.issueIDs) } == ["new-issue"])
        #expect(changes?.removedIDs == ["closing", "issue-closing"])
    }

    @Test func removedItemsLeaveTheOpenListsWithoutBeingFetched() {
        let previous = snapshot(open: [pr("keep", updated: 20), pr("closing", updated: 20)], merged: [], issues: [issue("gone", updated: 20), issue("kept", updated: 20)])
        let changes = SnapshotChanges(pullRequests: [], issues: [], truncated: false, removedIDs: ["closing", "gone"])
        let (open, merged, issues) = previous.merging(changes, mergedSince: at(-1000))
        #expect(open.map(\.id) == ["keep"])
        #expect(merged.isEmpty)
        #expect(issues.map(\.id) == ["kept"])
    }

    @Test func outsideReposOnlyJoinOnceTheyHaveABaseline() {
        let previous = snapshot(open: [], merged: [], issues: [])
        let feed = feed([
            entry("own", 30), entry("known", 31, repo: "client/app", outside: true), entry("new", 32, repo: "other/thing", outside: true),
        ], outside: ["client/app", "other/thing"])
        let changes = GitHubAPI.feedChanges(feed, since: at(25), previous: previous, knownOutside: ["client/app"])
        #expect(changes.map { Set($0.pullRequestIDs) } == ["own", "known"])
    }

    @Test func theSnapshotSearchesItselfWithoutAUsableFeed() {
        let previous = snapshot(open: [], merged: [], issues: [])
        #expect(GitHubAPI.feedChanges(nil, since: at(25), previous: previous, knownOutside: []) == nil)
        #expect(GitHubAPI.feedChanges(feed([], from: 40), since: at(25), previous: previous, knownOutside: []) == nil)
    }

    // MARK: sharing a run

    /// Holds a search until the test opens it.
    private final class Gate {
        private var waiter: CheckedContinuation<Void, Never>?
        private var isOpen = false
        var isWaiting: Bool { waiter != nil }

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiter = $0 }
        }

        func open() {
            isOpen = true
            waiter?.resume()
            waiter = nil
        }
    }

    private final class Searches {
        var batches: [[[String]]] = []
        var count: Int { batches.count }
    }

    private let api = GitHubAPI(token: "t")

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<1000 where !condition() { await Task.yield() }
    }

    @Test func callersWhileARunIsUnderWayShareItsSearch() async {
        let gate = Gate()
        let searches = Searches()
        let feeds = ChangeFeeds(search: { _, _, batches, _ in
            searches.batches.append(batches)
            await gate.wait()
            return ([self.entry("a", 20)], false)
        })
        let first = Task { await feeds.current(org: "acme", api: api, cursor: at(0)) }
        await waitUntil { gate.isWaiting }
        let second = Task { await feeds.current(org: "acme", api: api, cursor: at(0)) }
        await Task.yield()
        gate.open()
        #expect(await first.value?.entries.keys.sorted() == ["a"])
        #expect(await second.value?.entries.keys.sorted() == ["a"])
        #expect(searches.count == 1)
    }

    @Test func aFailedRunIsNotSearchedAgainByItsWaiters() async {
        let gate = Gate()
        let searches = Searches()
        struct Failure: Error {}
        let feeds = ChangeFeeds(search: { _, _, batches, _ in
            searches.batches.append(batches)
            await gate.wait()
            throw Failure()
        })
        let first = Task { await feeds.current(org: "acme", api: api, cursor: at(0)) }
        await waitUntil { gate.isWaiting }
        let second = Task { await feeds.current(org: "acme", api: api, cursor: at(0)) }
        await Task.yield()
        gate.open()
        #expect(await first.value == nil)
        #expect(await second.value == nil)
        #expect(searches.count == 1)
    }

    @Test func aCallerNeedingMoreOutsideReposExtendsTheFeed() async {
        let searches = Searches()
        let feeds = ChangeFeeds(search: { _, _, batches, _ in
            searches.batches.append(batches)
            return ([], false)
        })
        let own = await feeds.current(org: "acme", api: api, cursor: at(0))
        #expect(own?.outsideRepos == [])
        let wider = await feeds.current(org: "acme", api: api, outside: ["client/app"], cursor: at(0))
        #expect(wider?.outsideRepos == ["client/app"])
        #expect(searches.count == 2)
        #expect(searches.batches[1].flatMap { $0 } == ["client/app"])
        // The wider feed serves the narrower caller without another search.
        _ = await feeds.current(org: "acme", api: api, cursor: at(0))
        #expect(searches.count == 2)
    }

    @Test func clearingMidRunDiscardsTheResult() async {
        let gate = Gate()
        let searches = Searches()
        let feeds = ChangeFeeds(search: { _, _, batches, _ in
            searches.batches.append(batches)
            await gate.wait()
            return ([self.entry("a", 20)], false)
        })
        let run = Task { await feeds.current(org: "acme", api: api, cursor: at(0)) }
        await waitUntil { gate.isWaiting }
        feeds.clear()
        gate.open()
        #expect(await run.value == nil)
        let next = await feeds.current(org: "acme", api: api, cursor: at(0))
        #expect(next != nil)
        #expect(searches.count == 2)
    }
}
