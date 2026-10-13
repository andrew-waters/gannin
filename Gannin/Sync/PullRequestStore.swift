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

    /// The newer person, keeping a name or avatar only the older one has.
    private static func merged(_ newer: Person?, _ older: Person?) -> Person? {
        guard let newer, let older, newer.login == older.login else { return newer ?? older }
        return Person(login: newer.login, name: newer.name ?? older.name, avatarUrl: newer.avatarUrl ?? older.avatarUrl)
    }

    /// This PR's fields with `incoming`'s laid over them, field by field: a
    /// field one fetch didn't read (a work log fetch has no `changedFiles`)
    /// keeps what another stored. When the held `updatedAt` is newer than
    /// the incoming one, the held fields win and incoming only fills gaps.
    func merged(with incoming: PullRequestCore) -> PullRequestCore {
        let incomingIsStale = updatedAt.map { held in incoming.updatedAt.map { held > $0 } ?? true } ?? false
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

/// What only the workload fetch reads, kept beside the core.
struct WorkloadExtras: Codable, Hashable {
    /// The PR's `updatedAt` when this was fetched. Open PRs are fetched again
    /// at the same `updatedAt` (their checks change without it moving), and
    /// the newer fetch wins.
    var updatedAt: Date?
    let state: String
    let isDraft: Bool
    let reviewDecision: PullRequest.ReviewState?
    let assignees: [Person]
    var requestedReviewers: [Person]
    var reviewRequestedAt: [String: Date]
    let reviewers: [Person]
    let linkedIssues: [LinkedItem]
    var checks: ItemDetail.CheckState?
    var reviewStates: [String: String]?
    var reviewedAt: [String: Date]?
    var lastCommitAt: Date?
    var authorRepliedAt: Date?
}

struct StoredPullRequest: Codable, Hashable, Identifiable {
    /// The part of a stored PR one store owns.
    enum Slot { case metrics, workLog, workload }

    var core: PullRequestCore
    /// Nil until a metrics sync has fetched the PR.
    var metrics: MetricsExtras?
    /// Nil until a work log sync has fetched the PR.
    var workLog: WorkLogExtras?
    /// Nil until a workload refresh has fetched the PR.
    var workload: WorkloadExtras?

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
    /// Saves waiting for a burst of writes to end, by org.
    private var delayedSaves: [String: SaveCoalescer] = [:]

    init(folder: String = "PullRequests") {
        cache = OrgJSONCache(folder: folder)
    }

    var cacheDirectory: URL { cache.directory }

    func pullRequests(org: String) -> [String: StoredPullRequest] {
        load(org)
    }

    /// Adds or updates PRs. A PR held at a newer `updatedAt` than the one
    /// given keeps its core; extras are replaced only by extras. `delayed`
    /// saves once a burst of writes ends, for edits made one after another.
    func merge(_ incoming: [StoredPullRequest], org: String, delayed: Bool = false) {
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
        if delayed { saveSoon(org) } else { save(org) }
    }

    /// Removes one store's part from the PRs it no longer needs, and any PR
    /// left with nothing from a store, so the file doesn't grow with PRs
    /// that have closed or aged out.
    func prune(_ slot: StoredPullRequest.Slot, org: String, keeping ids: Set<String>) {
        var held = load(org)
        var changed = false
        for (id, var pr) in held where !ids.contains(id) {
            pr.remove(slot)
            held[id] = pr.isEmpty ? nil : pr
            changed = true
        }
        guard changed else { return }
        loaded[org] = held
        save(org)
    }

    /// Writes any save still waiting.
    func flush() {
        delayedSaves.values.forEach { $0.flush() }
    }

    /// Changes a held PR, as after a write to GitHub, so it shows before the
    /// next fetch.
    func update(_ id: String, org: String, _ change: (inout StoredPullRequest) -> Void) {
        var held = load(org)
        guard var pr = held[id] else { return }
        change(&pr)
        held[id] = pr
        loaded[org] = held
        saveSoon(org)
    }

    func clear() {
        loaded = [:]
        delayedSaves.values.forEach { $0.cancel() }
        cache.clear()
    }

    /// Removes what one store fetched, in every org, and any PR left with
    /// nothing from a store. The other stores' parts stay.
    func clear(_ slot: StoredPullRequest.Slot) {
        for org in cache.orgs() {
            var held = load(org)
            for (id, var pr) in held {
                pr.remove(slot)
                held[id] = pr.isEmpty ? nil : pr
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

    private func saveSoon(_ org: String) {
        let saver = delayedSaves[org] ?? SaveCoalescer { [weak self] in self?.save(org) }
        delayedSaves[org] = saver
        saver.request()
    }
}

extension StoredPullRequest {
    mutating func remove(_ slot: Slot) {
        switch slot {
        case .metrics: metrics = nil
        case .workLog: workLog = nil
        case .workload: workload = nil
        }
    }

    /// Whether no store has a part of it.
    var isEmpty: Bool { metrics == nil && workLog == nil && workload == nil }

    /// This PR with `incoming` laid over it: core field by field, and each
    /// store's part replaced only by a part fetched at least as recently.
    func merged(with incoming: StoredPullRequest) -> StoredPullRequest {
        var next = self
        next.core = core.merged(with: incoming.core)
        next.metrics = Self.newer(metrics, incoming.metrics) { $0.updatedAt }
        next.workLog = Self.newer(workLog, incoming.workLog) { $0.updatedAt }
        next.workload = Self.newer(workload, incoming.workload) { $0.updatedAt }
        return next
    }

    /// The incoming part, unless the held one was fetched at a newer `updatedAt`
    /// or the incoming one has none (carried over from an old cache).
    private static func newer<Extras>(_ held: Extras?, _ incoming: Extras?, stamp: (Extras) -> Date?) -> Extras? {
        guard let held, let incoming else { return incoming ?? held }
        if let heldAt = stamp(held), stamp(incoming).map({ heldAt > $0 }) ?? true { return held }
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

    /// A PR as the workload fetch has it.
    init(workload pr: PullRequest) {
        core = PullRequestCore(
            id: pr.id, number: pr.number, title: pr.title, url: pr.url, repo: pr.repo,
            author: pr.author, authorIsBot: nil, createdAt: pr.createdAt, mergedAt: pr.mergedAt, updatedAt: pr.updatedAt,
            additions: pr.additions, deletions: pr.deletions, changedFiles: pr.changedFiles
        )
        workload = WorkloadExtras(
            updatedAt: pr.updatedAt, state: pr.state, isDraft: pr.isDraft, reviewDecision: pr.reviewDecision,
            assignees: pr.assignees, requestedReviewers: pr.requestedReviewers, reviewRequestedAt: pr.reviewRequestedAt,
            reviewers: pr.reviewers, linkedIssues: pr.linkedIssues, checks: pr.checks, reviewStates: pr.reviewStates,
            reviewedAt: pr.reviewedAt, lastCommitAt: pr.lastCommitAt, authorRepliedAt: pr.authorRepliedAt
        )
    }

    /// Nil until a workload refresh has fetched it.
    var workloadPullRequest: PullRequest? {
        guard let workload else { return nil }
        return PullRequest(
            id: core.id, number: core.number, title: core.title, url: core.url, repo: core.repo, author: core.author,
            isDraft: workload.isDraft, state: workload.state, createdAt: core.createdAt,
            updatedAt: workload.updatedAt ?? core.updatedAt ?? core.createdAt, mergedAt: core.mergedAt,
            reviewDecision: workload.reviewDecision, additions: core.additions ?? 0, deletions: core.deletions ?? 0,
            changedFiles: core.changedFiles, assignees: workload.assignees, requestedReviewers: workload.requestedReviewers,
            reviewRequestedAt: workload.reviewRequestedAt, reviewers: workload.reviewers, linkedIssues: workload.linkedIssues,
            checks: workload.checks, reviewStates: workload.reviewStates, reviewedAt: workload.reviewedAt,
            lastCommitAt: workload.lastCommitAt, authorRepliedAt: workload.authorRepliedAt
        )
    }
}
