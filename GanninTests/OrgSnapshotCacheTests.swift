import Foundation
import Testing
@testable import Gannin

struct OrgSnapshotCacheTests {
    private func at(_ seconds: Double) -> Date { Date(timeIntervalSince1970: 1_760_000_000 + seconds) }

    private func uniqueFolder() -> String { "OrgSnapshotCacheTests-\(UUID().uuidString)" }

    /// This test's own issue store, so none touches the app's.
    private let issueFolder = "OrgSnapshotCacheTests-issues-\(UUID().uuidString)"

    private func cache(_ directory: URL, _ pullRequests: PullRequestStore) -> OrgSnapshotCache {
        OrgSnapshotCache(directory: directory, pullRequests: pullRequests, issues: SharedIssueStore(folder: issueFolder))
    }

    private func issue(_ id: String, updated: Double = 10) -> Gannin.Issue {
        Gannin.Issue(
            id: id, number: 3, title: "Issue \(id)", url: URL(string: "https://github.com/acme/api/issues/3")!, repo: "acme/api",
            author: Person(login: "sam", name: "Sam Jones", avatarUrl: URL(string: "https://example.com/sam.png")),
            state: "OPEN", createdAt: at(0), updatedAt: at(updated), closedAt: nil,
            assignees: [Person(login: "kim", name: "Kim", avatarUrl: URL(string: "https://example.com/kim.png"))],
            labels: [IssueLabel(name: "bug", color: "d73a4a")],
            linkedPullRequests: [LinkedItem(id: "p1", number: 7, title: "PR", url: URL(string: "https://github.com/acme/api/pull/7")!, repo: "acme/api", state: "OPEN")]
        )
    }

    private func snapshot(issues: [Gannin.Issue]) -> OrgSnapshot {
        var snapshot = snapshot(open: [])
        snapshot.issues = issues
        return snapshot
    }

    private func directory() -> URL {
        URL.applicationSupportDirectory.appending(path: uniqueFolder(), directoryHint: .isDirectory)
    }

    private func pr(_ id: String, state: String = "OPEN", updated: Double = 10, checks: ItemDetail.CheckState? = .pending) -> PullRequest {
        PullRequest(
            id: id, number: 7, title: "Title \(id)", url: URL(string: "https://github.com/acme/api/pull/7")!, repo: "acme/api",
            author: Person(login: "sam", name: "Sam Jones", avatarUrl: URL(string: "https://example.com/sam.png")),
            isDraft: true, state: state, createdAt: at(0), updatedAt: at(updated), mergedAt: state == "MERGED" ? at(5) : nil,
            reviewDecision: .changesRequested, additions: 12, deletions: 3, changedFiles: 4,
            assignees: [Person(login: "kim", name: nil, avatarUrl: nil)],
            requestedReviewers: [Person(login: "lee", name: nil, avatarUrl: nil)], reviewRequestedAt: ["lee": at(2)],
            reviewers: [Person(login: "kim", name: nil, avatarUrl: nil)],
            linkedIssues: [LinkedItem(id: "i1", number: 3, title: "Issue", url: URL(string: "https://github.com/acme/api/issues/3")!, repo: "acme/api", state: "OPEN")],
            checks: checks, reviewStates: ["kim": "COMMENTED"], reviewedAt: ["kim": at(4)], lastCommitAt: at(6), authorRepliedAt: at(8)
        )
    }

    private func snapshot(open: [PullRequest], merged: [PullRequest] = []) -> OrgSnapshot {
        OrgSnapshot(
            orgLogin: "acme", fetchedAt: at(30), peopleFetchedAt: nil, fullFetchedAt: at(0), lookbackDays: 14, members: [], teams: [],
            openPullRequests: open, mergedPullRequests: merged, issues: [], unreadableRepos: nil, outsideReposFetched: nil, warnings: []
        )
    }

    private func json(_ url: URL) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]) ?? [:]
    }

    private struct LegacySnapshotFile: Encodable {
        var orgLogin = "acme"
        var fetchedAt: Date
        var lookbackDays = 14
        var members: [Person] = []
        var teams: [Team] = []
        var openPullRequests: [PullRequest]
        var mergedPullRequests: [PullRequest]
        var issues: [Gannin.Issue] = []
        var warnings: [String] = []
    }

    @Test func everyWorkloadFieldOfAPullRequestRoundTripsThroughTheStore() {
        let original = pr("a", state: "MERGED")
        #expect(StoredPullRequest(workload: original).workloadPullRequest == original)
    }

    @Test func aSavedSnapshotLoadsWithItsPullRequestsInOrderAndHoldsNoneInItsFile() {
        let dir = directory()
        let store = PullRequestStore(folder: uniqueFolder())
        defer { try? FileManager.default.removeItem(at: dir); store.clear(); SharedIssueStore(folder: issueFolder).clear() }
        let saved = snapshot(open: [pr("b"), pr("a")], merged: [pr("m", state: "MERGED")])
        cache(dir, store).save(saved)

        let loaded = cache(dir, store).load("acme")
        #expect(loaded?.openPullRequests.map(\.id) == ["b", "a"])
        #expect(loaded?.mergedPullRequests.map(\.id) == ["m"])
        #expect(loaded?.openPullRequests == saved.openPullRequests)
        #expect(loaded?.lacksFileCounts == false)
        let file = json(dir.appending(path: "acme.json"))
        #expect(file["openPullRequests"] == nil)
        #expect(file["mergedPullRequests"] == nil)
    }

    @Test func aSnapshotFromBeforeTheStoreMovesItsPullRequestsIntoIt() throws {
        let dir = directory()
        let store = PullRequestStore(folder: uniqueFolder())
        defer { try? FileManager.default.removeItem(at: dir); store.clear(); SharedIssueStore(folder: issueFolder).clear() }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let open = [pr("a")], merged = [pr("m", state: "MERGED")]
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encoder.encode(LegacySnapshotFile(fetchedAt: at(30), openPullRequests: open, mergedPullRequests: merged))
            .write(to: dir.appending(path: "acme.json"))

        let loaded = cache(dir, store).load("acme")
        #expect(loaded?.openPullRequests == open)
        #expect(loaded?.mergedPullRequests == merged)
        #expect(store.pullRequests(org: "acme")["a"]?.workload != nil)
        #expect(json(dir.appending(path: "acme.json"))["openPullRequests"] == nil)
        // Read again from the rewritten file.
        #expect(cache(dir, store).load("acme")?.openPullRequests == open)
    }

    @Test func aSnapshotWhoseStoreWasClearedIsDropped() {
        let dir = directory()
        let folder = uniqueFolder()
        let store = PullRequestStore(folder: folder)
        defer { try? FileManager.default.removeItem(at: dir); store.clear(); SharedIssueStore(folder: issueFolder).clear() }
        cache(dir, store).save(snapshot(open: [pr("a")]))
        store.clear()
        #expect(cache(dir, PullRequestStore(folder: folder)).load("acme") == nil)
    }

    @Test func aPullRequestThatLeavesTheSnapshotLosesOnlyTheWorkloadsPart() {
        let dir = directory()
        let store = PullRequestStore(folder: uniqueFolder())
        defer { try? FileManager.default.removeItem(at: dir); store.clear(); SharedIssueStore(folder: issueFolder).clear() }
        let cache = cache(dir, store)
        cache.save(snapshot(open: [pr("a"), pr("b")]))
        var withMetrics = store.pullRequests(org: "acme")["a"]!
        withMetrics.metrics = MetricsExtras(updatedAt: nil, firstCommitAt: nil, readyAt: nil, reviews: [], reviewRequests: [])
        store.merge([withMetrics], org: "acme")

        cache.save(snapshot(open: []))
        let held = store.pullRequests(org: "acme")
        #expect(held["a"]?.workload == nil)
        #expect(held["a"]?.metrics != nil)
        #expect(held["b"] == nil)
    }

    @Test func aFetchAtTheSameUpdatedAtReplacesTheHeldChecks() {
        let dir = directory()
        let store = PullRequestStore(folder: uniqueFolder())
        defer { try? FileManager.default.removeItem(at: dir); store.clear(); SharedIssueStore(folder: issueFolder).clear() }
        let cache = cache(dir, store)
        cache.save(snapshot(open: [pr("a", checks: .pending)]))
        cache.save(snapshot(open: [pr("a", checks: .success)]))
        #expect(store.pullRequests(org: "acme")["a"]?.workloadPullRequest?.checks == .success)
    }

    @Test func anOptimisticUpdateIsWrittenThroughToTheStore() {
        let dir = directory()
        let folder = uniqueFolder()
        let store = PullRequestStore(folder: folder)
        defer { try? FileManager.default.removeItem(at: dir); store.clear(); SharedIssueStore(folder: issueFolder).clear() }
        let cache = cache(dir, store)
        var changed = pr("a")
        cache.save(snapshot(open: [changed]))
        changed.requestedReviewers.append(Person(login: "new", name: nil, avatarUrl: nil))
        changed.reviewRequestedAt["new"] = at(20)
        cache.update(changed, org: "acme")
        store.flush()

        let reloaded = PullRequestStore(folder: folder).pullRequests(org: "acme")["a"]?.workloadPullRequest
        #expect(reloaded?.requestedReviewers.map(\.login) == ["lee", "new"])
        #expect(reloaded?.reviewRequestedAt["new"] == at(20))
    }

    @Test func clearingTheSnapshotsKeepsWhatTheOtherStoresFetched() {
        let dir = directory()
        let store = PullRequestStore(folder: uniqueFolder())
        defer { try? FileManager.default.removeItem(at: dir); store.clear(); SharedIssueStore(folder: issueFolder).clear() }
        let cache = cache(dir, store)
        cache.save(snapshot(open: [pr("a")]))
        var shared = store.pullRequests(org: "acme")["a"]!
        shared.workLog = WorkLogExtras(updatedAt: nil, closedAt: nil, mergedBy: nil, commits: [], reviews: [], isDraft: nil, closingIssues: [])
        store.merge([shared], org: "acme")

        cache.clear()
        #expect(cache.load("acme") == nil)
        #expect(store.pullRequests(org: "acme")["a"]?.workLog != nil)
        #expect(store.pullRequests(org: "acme")["a"]?.workload == nil)
    }

    // MARK: Issues

    @Test func everyWorkloadFieldOfAnIssueRoundTripsThroughTheStore() {
        let original = issue("a")
        #expect(StoredIssue(workload: original).workloadIssue == original)
    }

    @Test func aSavedSnapshotLoadsItsIssuesInOrderAndHoldsNoneInItsFile() {
        let dir = directory()
        let store = PullRequestStore(folder: uniqueFolder())
        defer { try? FileManager.default.removeItem(at: dir); store.clear(); SharedIssueStore(folder: issueFolder).clear() }
        let saved = snapshot(issues: [issue("b"), issue("a")])
        cache(dir, store).save(saved)

        let loaded = cache(dir, store).load("acme")
        #expect(loaded?.issues == saved.issues)
        #expect(json(dir.appending(path: "acme.json"))["issues"] == nil)
        #expect(json(dir.appending(path: "acme.json"))["storedIssueIDs"] as? [String] == ["b", "a"])
    }

    @Test func aSnapshotFromBeforeTheStoreMovesItsIssuesIntoIt() throws {
        let dir = directory()
        let store = PullRequestStore(folder: uniqueFolder())
        defer { try? FileManager.default.removeItem(at: dir); store.clear(); SharedIssueStore(folder: issueFolder).clear() }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let issues = [issue("a"), issue("b")]
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encoder.encode(LegacySnapshotFile(fetchedAt: at(30), openPullRequests: [], mergedPullRequests: [], issues: issues))
            .write(to: dir.appending(path: "acme.json"))

        let issueStore = SharedIssueStore(folder: issueFolder)
        #expect(cache(dir, store).load("acme")?.issues == issues)
        #expect(issueStore.issues(org: "acme")["a"]?.workload != nil)
        #expect(json(dir.appending(path: "acme.json"))["issues"] == nil)
        #expect(cache(dir, store).load("acme")?.issues == issues)
    }

    @Test func aSnapshotWhoseIssueStoreWasClearedIsDropped() {
        let dir = directory()
        let store = PullRequestStore(folder: uniqueFolder())
        defer { try? FileManager.default.removeItem(at: dir); store.clear(); SharedIssueStore(folder: issueFolder).clear() }
        cache(dir, store).save(snapshot(issues: [issue("a")]))
        SharedIssueStore(folder: issueFolder).clear()
        #expect(cache(dir, store).load("acme") == nil)
    }

    @Test func anIssueTheHistorySawClosedIsLeftOutOfTheWorkloadNotTreatedAsMissing() {
        let dir = directory()
        let store = PullRequestStore(folder: uniqueFolder())
        defer { try? FileManager.default.removeItem(at: dir); store.clear(); SharedIssueStore(folder: issueFolder).clear() }
        cache(dir, store).save(snapshot(issues: [issue("a"), issue("b")]))

        let issues = SharedIssueStore(folder: issueFolder)
        var closed = issues.issues(org: "acme")["a"]!
        closed.core = IssueCore(
            id: "a", number: 3, title: "Issue a", url: closed.core.url, repo: "acme/api", author: closed.core.author,
            createdAt: at(0), closedAt: at(50), updatedAt: at(60), assignees: closed.core.assignees, labels: closed.core.labels
        )
        issues.merge([closed], org: "acme")

        #expect(cache(dir, store).load("acme")?.issues.map(\.id) == ["b"])
    }

    @Test func anIssueThatLeavesTheSnapshotLosesOnlyTheWorkloadsPart() {
        let dir = directory()
        let store = PullRequestStore(folder: uniqueFolder())
        defer { try? FileManager.default.removeItem(at: dir); store.clear(); SharedIssueStore(folder: issueFolder).clear() }
        let issues = SharedIssueStore(folder: issueFolder)
        let c = OrgSnapshotCache(directory: dir, pullRequests: store, issues: issues)
        c.save(snapshot(issues: [issue("a"), issue("b")]))
        var withHistory = issues.issues(org: "acme")["a"]!
        withHistory.history = HistoryIssueExtras(
            updatedAt: at(10), issueType: nil, milestone: nil, parentID: nil, stateReason: nil, statusChanges: [], assignedAt: [],
            reopenedAt: [], subIssuesAddedAt: [], linkedPullRequests: [], mentionedInPullRequests: nil, projectFields: []
        )
        issues.merge([withHistory], org: "acme")

        c.save(snapshot(issues: []))
        let held = issues.issues(org: "acme")
        #expect(held["a"]?.workload == nil)
        #expect(held["a"]?.history != nil)
        #expect(held["b"] == nil)
    }
}
