import Foundation
import Testing
@testable import Gannin

/// A cache written before PRs moved into `PullRequestStore` is read once, its
/// PRs carried over, and its own file rewritten without them.
struct PullRequestMigrationTests {
    private let helper = PullRequestStoreTests()

    private struct LegacyMetricsFile: Encodable {
        var formatVersion = 4
        var orgLogin = "acme"
        var coveredFrom = Date(timeIntervalSince1970: 100)
        var syncedAt = Date(timeIntervalSince1970: 9_000)
        var pullRequests: [String: MetricPullRequest]
        var openedPerWeek: [Date: Int] = [:]
    }

    private struct LegacyWorkLogFile: Encodable {
        var version = 4
        var orgLogin = "acme"
        var coveredFrom = Date(timeIntervalSince1970: 100)
        var fetchedAt = Date(timeIntervalSince1970: 9_000)
        var pullRequests: [String: WorkLogPullRequest]
        var issues: [String: WorkLogIssue] = [:]
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func uniqueFolder() -> String { "PullRequestMigrationTests-\(UUID().uuidString)" }

    private func json(at url: URL) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]) ?? [:]
    }

    // MARK: Metrics

    private func metricsStore(cache: OrgJSONCache, store: PullRequestStore) -> MetricsStore {
        MetricsStore(auth: AuthStore(), activity: SyncActivity(), pullRequestStore: store, cache: cache)
    }

    @Test func aFormat4MetricsHistoryMovesItsPullRequestsIntoTheStore() throws {
        let cache = OrgJSONCache(folder: uniqueFolder())
        let prs = PullRequestStore(folder: uniqueFolder())
        defer { cache.clear(); prs.clear() }
        let pr = helper.metricPR("a", files: 3)
        let data = try encoder().encode(LegacyMetricsFile(pullRequests: ["a": pr]))
        try FileManager.default.createDirectory(at: cache.directory, withIntermediateDirectories: true)
        try data.write(to: cache.directory.appending(path: "acme.json"))

        let store = metricsStore(cache: cache, store: prs)
        store.loadCached("acme")

        #expect(store.history(for: "acme")?.pullRequests["a"] == pr)
        #expect(prs.pullRequests(org: "acme")["a"]?.metricPullRequest == pr)
        let file = json(at: cache.directory.appending(path: "acme.json"))
        #expect(file["formatVersion"] as? Int == MetricsHistory.currentFormat)
        #expect(file["pullRequests"] == nil)

        // The rewritten file isn't imported again, and reads back from the store.
        let again = metricsStore(cache: cache, store: prs)
        again.loadCached("acme")
        #expect(again.history(for: "acme")?.pullRequests["a"] == pr)
    }

    @Test func aMetricsHistoryWhoseStoreWasClearedIsDropped() throws {
        let cache = OrgJSONCache(folder: uniqueFolder())
        let folder = uniqueFolder()
        let prs = PullRequestStore(folder: folder)
        defer { cache.clear(); prs.clear() }
        let data = try encoder().encode(LegacyMetricsFile(pullRequests: ["a": helper.metricPR("a")]))
        try FileManager.default.createDirectory(at: cache.directory, withIntermediateDirectories: true)
        try data.write(to: cache.directory.appending(path: "acme.json"))
        metricsStore(cache: cache, store: prs).loadCached("acme")

        prs.clear()
        let store = metricsStore(cache: cache, store: PullRequestStore(folder: folder))
        store.loadCached("acme")
        #expect(store.history(for: "acme") == nil)
    }

    // MARK: Work log

    private func workLogStore(directory: URL, store: PullRequestStore) -> WorkLogStore {
        WorkLogStore(auth: AuthStore(), activity: SyncActivity(), pullRequestStore: store, directory: directory)
    }

    private func workLogDirectory() -> URL {
        URL.applicationSupportDirectory.appending(path: uniqueFolder(), directoryHint: .isDirectory)
    }

    @Test func aVersion4WorkLogMovesItsPullRequestsIntoTheStore() throws {
        let directory = workLogDirectory()
        let prs = PullRequestStore(folder: uniqueFolder())
        defer { try? FileManager.default.removeItem(at: directory); prs.clear() }
        let pr = helper.workLogPR("a")
        let data = try encoder().encode(LegacyWorkLogFile(pullRequests: ["a": pr]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appending(path: "acme.json"))

        let store = workLogStore(directory: directory, store: prs)
        store.loadCached("acme")

        #expect(store.history(for: "acme")?.pullRequests["a"]?.commits == pr.commits)
        #expect(prs.pullRequests(org: "acme")["a"]?.workLog?.reviews == pr.reviews)
        let file = json(at: directory.appending(path: "acme.json"))
        #expect(file["version"] as? Int == WorkLogHistory.currentVersion)
        #expect(file["pullRequests"] == nil)

        let again = workLogStore(directory: directory, store: prs)
        again.loadCached("acme")
        #expect(again.history(for: "acme")?.pullRequests["a"]?.commits == pr.commits)
    }

    @Test func aWorkLogWhoseStoreWasClearedIsDropped() throws {
        let directory = workLogDirectory()
        let folder = uniqueFolder()
        let prs = PullRequestStore(folder: folder)
        defer { try? FileManager.default.removeItem(at: directory); prs.clear() }
        let data = try encoder().encode(LegacyWorkLogFile(pullRequests: ["a": helper.workLogPR("a")]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appending(path: "acme.json"))
        workLogStore(directory: directory, store: prs).loadCached("acme")

        prs.clear()
        let store = workLogStore(directory: directory, store: PullRequestStore(folder: folder))
        store.loadCached("acme")
        #expect(store.history(for: "acme") == nil)
    }
}
