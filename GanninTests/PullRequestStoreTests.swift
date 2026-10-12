import Foundation
import Testing
@testable import Gannin

struct PullRequestStoreTests {
    private func makeStore() -> PullRequestStore {
        PullRequestStore(folder: "PullRequestStoreTests-\(UUID().uuidString)")
    }

    func metricPR(_ id: String, updatedAt: Date? = nil, files: Int? = nil) -> MetricPullRequest {
        MetricPullRequest(
            id: id, number: 1, title: "Title", url: URL(string: "https://github.com/acme/app/pull/1")!, repo: "acme/app",
            author: Person(login: "sam", name: nil, avatarUrl: nil), authorIsBot: false,
            createdAt: Date(timeIntervalSince1970: 1_000), mergedAt: Date(timeIntervalSince1970: 5_000),
            firstCommitAt: Date(timeIntervalSince1970: 900), readyAt: nil,
            reviews: [MetricReview(login: "kim", state: "APPROVED", submittedAt: Date(timeIntervalSince1970: 3_000))],
            reviewRequests: [], additions: 10, deletions: 2, changedFiles: files, updatedAt: updatedAt
        )
    }

    @Test func aMetricPullRequestRoundTripsThroughTheStore() {
        let pr = metricPR("a", updatedAt: Date(timeIntervalSince1970: 6_000), files: 3)
        #expect(StoredPullRequest(metrics: pr).metricPullRequest == pr)
    }

    @Test func aPullRequestWithoutMetricsExtrasIsNotAMetricPullRequest() {
        var stored = StoredPullRequest(metrics: metricPR("a"))
        stored.metrics = nil
        #expect(stored.metricPullRequest == nil)
    }

    @Test func savedPullRequestsLoadInANewStore() {
        let folder = "PullRequestStoreTests-\(UUID().uuidString)"
        let store = PullRequestStore(folder: folder)
        defer { store.clear() }
        store.merge([StoredPullRequest(metrics: metricPR("a"))], org: "acme")
        #expect(PullRequestStore(folder: folder).pullRequests(org: "acme").keys.sorted() == ["a"])
        #expect(PullRequestStore(folder: folder).pullRequests(org: "other").isEmpty)
    }

    @Test func aNewerHeldUpdateIsNotReplacedByAnOlderOne() {
        let store = makeStore()
        defer { store.clear() }
        store.merge([StoredPullRequest(metrics: metricPR("a", updatedAt: Date(timeIntervalSince1970: 9_000), files: 5))], org: "acme")
        store.merge([StoredPullRequest(metrics: metricPR("a", updatedAt: Date(timeIntervalSince1970: 7_000), files: 1))], org: "acme")
        #expect(store.pullRequests(org: "acme")["a"]?.core.changedFiles == 5)
    }

    @Test func aCarriedOverPullRequestOnlyFillsGapsInOneHeldWithADate() {
        let store = makeStore()
        defer { store.clear() }
        let fresh = Date(timeIntervalSince1970: 7_000)
        store.merge([StoredPullRequest(metrics: metricPR("a", updatedAt: fresh, files: 4))], org: "acme")
        var carried = StoredPullRequest(workLog: workLogPR("a"))
        carried.core = PullRequestCore(
            id: "a", number: 1, title: "Old title", url: carried.core.url, repo: "acme/app", author: nil, authorIsBot: nil,
            createdAt: carried.core.createdAt, mergedAt: nil, updatedAt: nil, additions: nil, deletions: nil, changedFiles: nil
        )
        store.merge([carried], org: "acme")
        let held = store.pullRequests(org: "acme")["a"]
        #expect(held?.core.title == "Title")
        #expect(held?.core.updatedAt == fresh)
        #expect(held?.core.changedFiles == 4)
        #expect(held?.workLog != nil)
    }

    @Test func aCarriedOverSlotDoesNotReplaceOneFetchedAtADate() {
        let store = makeStore()
        defer { store.clear() }
        store.merge([StoredPullRequest(workLog: workLogPR("a", updatedAt: Date(timeIntervalSince1970: 7_000)))], org: "acme")
        var carried = StoredPullRequest(workLog: workLogPR("a"))
        carried.workLog = WorkLogExtras(updatedAt: nil, closedAt: nil, mergedBy: nil, commits: [], reviews: [], isDraft: nil, closingIssues: [])
        store.merge([carried], org: "acme")
        #expect(store.pullRequests(org: "acme")["a"]?.workLog?.commits.count == 1)
    }

    @Test func aPullRequestWithoutUpdatedAtIsReplacedByAFetchedOne() {
        let store = makeStore()
        defer { store.clear() }
        store.merge([StoredPullRequest(metrics: metricPR("a"))], org: "acme")
        store.merge([StoredPullRequest(metrics: metricPR("a", updatedAt: Date(timeIntervalSince1970: 7_000), files: 4))], org: "acme")
        let core = store.pullRequests(org: "acme")["a"]?.core
        #expect(core?.changedFiles == 4)
        #expect(core?.updatedAt == Date(timeIntervalSince1970: 7_000))
    }

    @Test func mergingCoreFieldsKeepsExtrasFetchedByAnotherStore() {
        let store = makeStore()
        defer { store.clear() }
        store.merge([StoredPullRequest(metrics: metricPR("a"))], org: "acme")
        var coreOnly = StoredPullRequest(metrics: metricPR("a", updatedAt: Date(timeIntervalSince1970: 7_000)))
        coreOnly.metrics = nil
        store.merge([coreOnly], org: "acme")
        #expect(store.pullRequests(org: "acme")["a"]?.metrics?.reviews.count == 1)
    }

    func workLogPR(_ id: String, updatedAt: Date? = nil) -> WorkLogPullRequest {
        WorkLogPullRequest(
            id: id, number: 1, title: "Title", url: URL(string: "https://github.com/acme/app/pull/1")!, repo: "acme/app",
            author: "sam", createdAt: Date(timeIntervalSince1970: 1_000), mergedAt: Date(timeIntervalSince1970: 5_000),
            closedAt: Date(timeIntervalSince1970: 5_000), mergedBy: "kim",
            commits: [WorkLogCommit(authoredAt: Date(timeIntervalSince1970: 900), author: "sam", additions: 4, deletions: 1, utcOffset: 0)],
            reviews: [WorkLogReview(submittedAt: Date(timeIntervalSince1970: 3_000), author: "kim", state: "APPROVED")],
            isDraft: false, updatedAt: updatedAt, additions: 10, deletions: 2, authorIsBot: false
        )
    }

    @Test func aWorkLogPullRequestRoundTripsThroughTheStore() {
        let pr = workLogPR("a", updatedAt: Date(timeIntervalSince1970: 6_000))
        #expect(StoredPullRequest(workLog: pr).workLogPullRequest == pr)
    }

    @Test func theMetricsAndWorkLogFetchesOfAPullRequestAreKeptOnce() {
        let store = makeStore()
        defer { store.clear() }
        store.merge([StoredPullRequest(metrics: metricPR("a", updatedAt: Date(timeIntervalSince1970: 6_000), files: 3))], org: "acme")
        store.merge([StoredPullRequest(workLog: workLogPR("a", updatedAt: Date(timeIntervalSince1970: 6_000)))], org: "acme")
        let held = store.pullRequests(org: "acme")
        #expect(held.count == 1)
        #expect(held["a"]?.metricPullRequest != nil)
        #expect(held["a"]?.workLogPullRequest?.commits.count == 1)
        #expect(held["a"]?.core.changedFiles == 3)
    }

    @Test func aFetchThatLacksAFieldKeepsWhatAnotherStoreStored() {
        let store = makeStore()
        defer { store.clear() }
        store.merge([StoredPullRequest(metrics: metricPR("a"))], org: "acme")
        var legacy = StoredPullRequest(workLog: workLogPR("a"))
        legacy.core.additions = nil
        legacy.core.authorIsBot = nil
        store.merge([legacy], org: "acme")
        #expect(store.pullRequests(org: "acme")["a"]?.core.additions == 10)
    }

    @Test func clearingOneStoresPartKeepsTheOthers() {
        let store = makeStore()
        defer { store.clear() }
        store.merge([StoredPullRequest(metrics: metricPR("a")), StoredPullRequest(metrics: metricPR("b"))], org: "acme")
        store.merge([StoredPullRequest(workLog: workLogPR("a"))], org: "acme")
        store.clear(.metrics)
        let held = store.pullRequests(org: "acme")
        #expect(held["a"]?.metrics == nil)
        #expect(held["a"]?.workLogPullRequest != nil)
        #expect(held["b"] == nil)
    }

    @Test func aStoreThatDidntFetchAPullRequestAtItsNewestUpdateSeesItsOwnCopyAsOld() {
        let store = makeStore()
        defer { store.clear() }
        store.merge([StoredPullRequest(workLog: workLogPR("a", updatedAt: Date(timeIntervalSince1970: 6_000)))], org: "acme")
        store.merge([StoredPullRequest(metrics: metricPR("a", updatedAt: Date(timeIntervalSince1970: 8_000)))], org: "acme")
        let held = store.pullRequests(org: "acme")["a"]
        #expect(held?.core.updatedAt == Date(timeIntervalSince1970: 8_000))
        #expect(held?.workLogPullRequest?.updatedAt == Date(timeIntervalSince1970: 6_000))
        #expect(held?.metricPullRequest?.updatedAt == Date(timeIntervalSince1970: 8_000))
    }

    @Test func anOlderFetchDoesNotReplaceANewerSlot() {
        let store = makeStore()
        defer { store.clear() }
        store.merge([StoredPullRequest(workLog: workLogPR("a", updatedAt: Date(timeIntervalSince1970: 8_000)))], org: "acme")
        store.merge([StoredPullRequest(workLog: workLogPR("a", updatedAt: Date(timeIntervalSince1970: 6_000)))], org: "acme")
        #expect(store.pullRequests(org: "acme")["a"]?.workLogPullRequest?.updatedAt == Date(timeIntervalSince1970: 8_000))
    }

    @Test func anAuthorsNameSurvivesAFetchThatDidntKnowIt() {
        let store = makeStore()
        defer { store.clear() }
        var named = StoredPullRequest(metrics: metricPR("a"))
        named.core = PullRequestCore(
            id: "a", number: 1, title: "Title", url: named.core.url, repo: "acme/app",
            author: Person(login: "sam", name: "Sam Jones", avatarUrl: nil), authorIsBot: false,
            createdAt: named.core.createdAt, mergedAt: named.core.mergedAt, updatedAt: nil, additions: 1, deletions: 1, changedFiles: nil
        )
        store.merge([named], org: "acme")
        store.merge([StoredPullRequest(workLog: workLogPR("a"))], org: "acme")
        #expect(store.pullRequests(org: "acme")["a"]?.core.author?.name == "Sam Jones")
    }

    @Test func updateChangesAHeldPullRequestAndIgnoresAnUnknownOne() {
        let store = makeStore()
        defer { store.clear() }
        store.merge([StoredPullRequest(metrics: metricPR("a"))], org: "acme")
        store.update("a", org: "acme") { $0.core.changedFiles = 9 }
        store.update("missing", org: "acme") { $0.core.changedFiles = 1 }
        #expect(store.pullRequests(org: "acme")["a"]?.core.changedFiles == 9)
        #expect(store.pullRequests(org: "acme")["missing"] == nil)
    }
}
