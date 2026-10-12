import Foundation

/// What every store that fetches a PR shares, so a PR is kept once.
struct PullRequestCore: Codable, Hashable, Identifiable {
    let id: String
    let number: Int
    let title: String
    let url: URL
    let repo: String
    let author: Person?
    let authorIsBot: Bool
    let createdAt: Date
    var mergedAt: Date?
    /// When GitHub last updated it. Nil for a PR carried over from a cache
    /// that never recorded it: the change feed fetches it again once, when
    /// it next reports the PR changed.
    var updatedAt: Date?
    let additions: Int
    let deletions: Int
    var changedFiles: Int?
}

/// What only the metrics fetch reads, kept beside the core.
struct MetricsExtras: Codable, Hashable {
    let firstCommitAt: Date?
    let readyAt: Date?
    var reviews: [MetricReview]
    var reviewRequests: [MetricReviewRequest]
}

struct StoredPullRequest: Codable, Hashable, Identifiable {
    var core: PullRequestCore
    /// Nil until a metrics sync has fetched the PR.
    var metrics: MetricsExtras?

    var id: String { core.id }
}

/// Every PR the app has fetched, per org and keyed by node ID, in one file
/// per org. Stores write what they fetched through `merge` and read what's
/// held, rather than each keeping its own copy.
final class PullRequestStore {
    static let shared = PullRequestStore()
    /// Bumped when the stored shape changes, so older files are dropped and
    /// fetched again rather than half-filled.
    static let currentFormat = 1

    private struct File: Codable {
        var formatVersion: Int
        var pullRequests: [String: StoredPullRequest]
    }

    private let cache: OrgJSONCache
    private var loaded: [String: [String: StoredPullRequest]] = [:]

    init(folder: String = "PullRequests") {
        cache = OrgJSONCache(folder: folder)
    }

    var cacheDirectory: URL { cache.directory }

    func pullRequests(org: String) -> [String: StoredPullRequest] {
        load(org)
    }

    /// Adds or updates PRs. A PR held at a newer `updatedAt` than the one
    /// given keeps its core; extras are replaced only by extras.
    func merge(_ incoming: [StoredPullRequest], org: String) {
        var held = load(org)
        var changed = false
        for pr in incoming {
            var next = pr
            if let existing = held[pr.id] {
                if let stored = existing.core.updatedAt, let given = pr.core.updatedAt, stored > given {
                    next.core = existing.core
                }
                next.metrics = pr.metrics ?? existing.metrics
                guard next != existing else { continue }
            }
            held[pr.id] = next
            changed = true
        }
        guard changed else { return }
        loaded[org] = held
        save(org)
    }

    /// Changes a held PR, as after a write to GitHub, so it shows before the
    /// next fetch.
    func update(_ id: String, org: String, _ change: (inout StoredPullRequest) -> Void) {
        var held = load(org)
        guard var pr = held[id] else { return }
        change(&pr)
        held[id] = pr
        loaded[org] = held
        save(org)
    }

    func clear() {
        loaded = [:]
        cache.clear()
    }

    private func load(_ org: String) -> [String: StoredPullRequest] {
        if let held = loaded[org] { return held }
        let file = cache.load(File.self, org: org)
        let held = file?.formatVersion == Self.currentFormat ? file?.pullRequests ?? [:] : [:]
        loaded[org] = held
        return held
    }

    private func save(_ org: String) {
        cache.save(File(formatVersion: Self.currentFormat, pullRequests: loaded[org] ?? [:]), org: org)
    }
}

extension StoredPullRequest {
    /// A PR as the metrics fetch has it.
    init(metrics pr: MetricPullRequest) {
        core = PullRequestCore(
            id: pr.id, number: pr.number, title: pr.title, url: pr.url, repo: pr.repo,
            author: pr.author, authorIsBot: pr.authorIsBot, createdAt: pr.createdAt,
            mergedAt: pr.mergedAt, updatedAt: pr.updatedAt,
            additions: pr.additions, deletions: pr.deletions, changedFiles: pr.changedFiles
        )
        metrics = MetricsExtras(firstCommitAt: pr.firstCommitAt, readyAt: pr.readyAt, reviews: pr.reviews, reviewRequests: pr.reviewRequests)
    }

    /// Nil until a metrics sync has fetched it, or while it isn't merged.
    var metricPullRequest: MetricPullRequest? {
        guard let metrics, let mergedAt = core.mergedAt else { return nil }
        return MetricPullRequest(
            id: core.id, number: core.number, title: core.title, url: core.url, repo: core.repo,
            author: core.author, authorIsBot: core.authorIsBot, createdAt: core.createdAt, mergedAt: mergedAt,
            firstCommitAt: metrics.firstCommitAt, readyAt: metrics.readyAt,
            reviews: metrics.reviews, reviewRequests: metrics.reviewRequests,
            additions: core.additions, deletions: core.deletions, changedFiles: core.changedFiles,
            updatedAt: core.updatedAt
        )
    }
}
