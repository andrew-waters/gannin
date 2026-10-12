import Foundation
import Testing
@testable import Gannin

struct PullRequestStoreTests {
    private func makeStore() -> PullRequestStore {
        PullRequestStore(folder: "PullRequestStoreTests-\(UUID().uuidString)")
    }

    private func metricPR(_ id: String, updatedAt: Date? = nil, files: Int? = nil) -> MetricPullRequest {
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
