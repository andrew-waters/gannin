import Foundation

/// What every store that fetches a PR shares, so a PR is kept once.
struct PullRequestCore: Codable, Hashable, Identifiable {
    let id: String
    let number: Int
    let title: String
    let url: URL
    let repo: String
    let author: Person?
    var authorIsBot: Bool?
    let createdAt: Date
    var mergedAt: Date?
    /// When GitHub last updated it. Nil for a PR carried over from a cache
    /// that never recorded it: the change feed fetches it again once, when
    /// it next reports the PR changed.
    var updatedAt: Date?
    var additions: Int?
    var deletions: Int?
    var changedFiles: Int?

    /// This PR's fields with `incoming`'s laid over them, field by field: a
    /// field one fetch didn't read (a work log fetch has no `changedFiles`)
    /// keeps what another stored. When the held `updatedAt` is newer than
    /// the incoming one, the held fields win and incoming only fills gaps.
    private static func merged(_ newer: Person?, _ older: Person?) -> Person? {
        guard let newer, let older, newer.login == older.login else { return newer ?? older }
        return Person(login: newer.login, name: newer.name ?? older.name, avatarUrl: newer.avatarUrl ?? older.avatarUrl)
    }

    func merged(with incoming: PullRequestCore) -> PullRequestCore {
        let incomingIsStale = updatedAt.flatMap { held in incoming.updatedAt.map { held > $0 } } ?? false
        let (newer, older) = incomingIsStale ? (self, incoming) : (incoming, self)
        return PullRequestCore(
            id: id, number: newer.number, title: newer.title, url: newer.url, repo: newer.repo,
            author: Self.merged(newer.author, older.author), authorIsBot: newer.authorIsBot ?? older.authorIsBot,
            createdAt: newer.createdAt, mergedAt: newer.mergedAt ?? older.mergedAt,
            updatedAt: newer.updatedAt ?? older.updatedAt,
            additions: newer.additions ?? older.additions, deletions: newer.deletions ?? older.deletions,
            changedFiles: newer.changedFiles ?? older.changedFiles
        )
    }
}

/// What only the metrics fetch reads, kept beside the core.
struct MetricsExtras: Codable, Hashable {
    /// The PR's `updatedAt` when this was fetched. The core's is the newest
    /// any store has seen, so it can't say whether these are current.
    var updatedAt: Date?
    let firstCommitAt: Date?
    let readyAt: Date?
    var reviews: [MetricReview]
    var reviewRequests: [MetricReviewRequest]
}

/// What only the work log fetch reads, kept beside the core.
struct WorkLogExtras: Codable, Hashable {
    /// The PR's `updatedAt` when this was fetched (see `MetricsExtras`).
    var updatedAt: Date?
    let closedAt: Date?
    let mergedBy: String?
    let commits: [WorkLogCommit]
    let reviews: [WorkLogReview]
    var isDraft: Bool?
    var closingIssues: [LinkedItem]
}

struct StoredPullRequest: Codable, Hashable, Identifiable {
    /// The part of a stored PR one store owns.
    enum Slot { case metrics, workLog }

    var core: PullRequestCore
    /// Nil until a metrics sync has fetched the PR.
    var metrics: MetricsExtras?
    /// Nil until a work log sync has fetched the PR.
    var workLog: WorkLogExtras?

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
                next = existing.merged(with: pr)
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

    /// Removes what one store fetched, in every org, and any PR left with
    /// nothing from a store. The other stores' parts stay.
    func clear(_ slot: StoredPullRequest.Slot) {
        for org in cache.orgs() {
            var held = load(org)
            for (id, var pr) in held {
                switch slot {
                case .metrics: pr.metrics = nil
                case .workLog: pr.workLog = nil
                }
                held[id] = pr.metrics == nil && pr.workLog == nil ? nil : pr
            }
            loaded[org] = held
            save(org)
        }
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
    /// This PR with `incoming` laid over it: core field by field, and each
    /// store's part replaced only by a part fetched at least as recently.
    func merged(with incoming: StoredPullRequest) -> StoredPullRequest {
        var next = self
        next.core = core.merged(with: incoming.core)
        next.metrics = Self.newer(metrics, incoming.metrics) { $0.updatedAt }
        next.workLog = Self.newer(workLog, incoming.workLog) { $0.updatedAt }
        return next
    }

    /// The incoming part, unless the held one was fetched at a newer `updatedAt`.
    private static func newer<Extras>(_ held: Extras?, _ incoming: Extras?, stamp: (Extras) -> Date?) -> Extras? {
        guard let held, let incoming else { return incoming ?? held }
        if let heldAt = stamp(held), let incomingAt = stamp(incoming), heldAt > incomingAt { return held }
        return incoming
    }

    /// A PR as the work log fetch has it.
    init(workLog pr: WorkLogPullRequest) {
        core = PullRequestCore(
            id: pr.id, number: pr.number, title: pr.title, url: pr.url, repo: pr.repo,
            author: pr.author.map { Person(login: $0, name: nil, avatarUrl: pr.authorAvatarUrl) },
            authorIsBot: pr.authorIsBot, createdAt: pr.createdAt, mergedAt: pr.mergedAt, updatedAt: pr.updatedAt,
            additions: pr.additions, deletions: pr.deletions, changedFiles: nil
        )
        workLog = WorkLogExtras(
            updatedAt: pr.updatedAt, closedAt: pr.closedAt, mergedBy: pr.mergedBy, commits: pr.commits, reviews: pr.reviews,
            isDraft: pr.isDraft, closingIssues: pr.closingIssues
        )
    }

    /// Nil until a work log sync has fetched it.
    var workLogPullRequest: WorkLogPullRequest? {
        guard let workLog else { return nil }
        return WorkLogPullRequest(
            id: core.id, number: core.number, title: core.title, url: core.url, repo: core.repo,
            author: core.author?.login, createdAt: core.createdAt, mergedAt: core.mergedAt,
            closedAt: workLog.closedAt, mergedBy: workLog.mergedBy, commits: workLog.commits, reviews: workLog.reviews,
            isDraft: workLog.isDraft, closingIssues: workLog.closingIssues, updatedAt: workLog.updatedAt,
            additions: core.additions, deletions: core.deletions, authorAvatarUrl: core.author?.avatarUrl, authorIsBot: core.authorIsBot
        )
    }

    /// A PR as the metrics fetch has it.
    init(metrics pr: MetricPullRequest) {
        core = PullRequestCore(
            id: pr.id, number: pr.number, title: pr.title, url: pr.url, repo: pr.repo,
            author: pr.author, authorIsBot: pr.authorIsBot, createdAt: pr.createdAt,
            mergedAt: pr.mergedAt, updatedAt: pr.updatedAt,
            additions: pr.additions, deletions: pr.deletions, changedFiles: pr.changedFiles
        )
        metrics = MetricsExtras(updatedAt: pr.updatedAt, firstCommitAt: pr.firstCommitAt, readyAt: pr.readyAt, reviews: pr.reviews, reviewRequests: pr.reviewRequests)
    }

    /// Nil until a metrics sync has fetched it, or while it isn't merged.
    var metricPullRequest: MetricPullRequest? {
        guard let metrics, let mergedAt = core.mergedAt else { return nil }
        return MetricPullRequest(
            id: core.id, number: core.number, title: core.title, url: core.url, repo: core.repo,
            author: core.author, authorIsBot: core.authorIsBot ?? false, createdAt: core.createdAt, mergedAt: mergedAt,
            firstCommitAt: metrics.firstCommitAt, readyAt: metrics.readyAt,
            reviews: metrics.reviews, reviewRequests: metrics.reviewRequests,
            additions: core.additions ?? 0, deletions: core.deletions ?? 0, changedFiles: core.changedFiles,
            updatedAt: metrics.updatedAt
        )
    }
}
