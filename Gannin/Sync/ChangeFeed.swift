import Foundation

/// A PR or issue the change feed saw updated: enough to decide whether a
/// store needs to fetch it in its own shape.
nonisolated struct ChangeEntry: Equatable, Sendable {
    enum Kind: Sendable { case pullRequest, issue }

    let id: String
    let kind: Kind
    /// OPEN, CLOSED or MERGED, as GitHub reports it.
    let state: String
    let repo: String
    let updatedAt: Date
    /// In a repo the account doesn't own that a project names, so a store
    /// that doesn't cover it (or hasn't a baseline for it yet) can leave it out.
    let isOutside: Bool
}

/// What one org's PRs and issues did since `coveredFrom`: every update
/// GitHub's search showed, kept so a store that last synced a while ago can
/// still ask for what changed after its own cursor.
nonisolated struct ChangeFeed: Sendable {
    /// How long updates are kept; a store whose cursor is older than the feed
    /// remembers searches for itself.
    static let retention: TimeInterval = 6 * 60 * 60
    /// Overlap on each run's search, so an update landing while the previous
    /// run was fetching isn't missed.
    static let overlap: TimeInterval = 5 * 60
    /// GitHub returns at most this many results for a search.
    static let searchCap = 1000

    var entries: [String: ChangeEntry]
    /// Every update after this is in `entries`.
    var coveredFrom: Date
    var lastRunAt: Date
    /// The outside repos the searches covered.
    var outsideRepos: Set<String>

    /// What a store does about the feed.
    enum Plan: Equatable {
        /// Fetch these, in its own shape.
        case fetch([ChangeEntry])
        /// Run its own changes search, as before the feed.
        case fallback
    }

    /// What a store needs fetched: entries updated since `cursor` that
    /// `include` accepts, leaving out any whose `updatedAt` the store already
    /// holds (`stored`). Falls back with no feed (its search failed or was
    /// capped, which empties the feed), one that doesn't reach back to
    /// `cursor`, or one that doesn't cover every outside repo the store
    /// needs (`needing`), whose changes it would otherwise miss.
    static func plan(
        feed: ChangeFeed?,
        cursor: Date,
        needing: Set<String> = [],
        include: (ChangeEntry) -> Bool = { _ in true },
        stored: (String) -> Date?
    ) -> Plan {
        guard let feed, feed.coveredFrom <= cursor, needing.isSubset(of: feed.outsideRepos) else { return .fallback }
        let wanted = feed.entries.values.filter { entry in
            guard entry.updatedAt >= cursor, include(entry) else { return false }
            return stored(entry.id).map { $0 < entry.updatedAt } ?? true
        }
        return .fetch(wanted.sorted { ($0.updatedAt, $0.id) > ($1.updatedAt, $1.id) })
    }

    /// The feed after a run that searched since `since` and found `found`.
    /// A run that hit the search cap lost some updates, so everything held is
    /// dropped and the feed starts again from `now`: stores older than that
    /// fall back. So does a change in the outside repos covered, since the
    /// feed has no history for one just added.
    static func updated(
        _ previous: ChangeFeed?,
        found: [ChangeEntry],
        capped: Bool,
        outsideRepos: Set<String>,
        since: Date,
        now: Date
    ) -> ChangeFeed {
        guard let previous, previous.outsideRepos == outsideRepos, !capped else {
            return ChangeFeed(
                entries: capped ? [:] : Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: Self.newer),
                coveredFrom: capped ? now : since,
                lastRunAt: now,
                outsideRepos: outsideRepos
            )
        }
        let oldest = now.addingTimeInterval(-retention)
        var entries = previous.entries
        for entry in found { entries[entry.id] = entries[entry.id].map { newer($0, entry) } ?? entry }
        entries = entries.filter { $0.value.updatedAt >= oldest }
        return ChangeFeed(
            entries: entries,
            coveredFrom: max(previous.coveredFrom, oldest),
            lastRunAt: now,
            outsideRepos: outsideRepos
        )
    }

    private static func newer(_ a: ChangeEntry, _ b: ChangeEntry) -> ChangeEntry { b.updatedAt >= a.updatedAt ? b : a }
}

/// One change feed per org, run at most once at a time and not again while
/// the last run is fresh, so the stores a Refresh starts together share a search.
final class ChangeFeeds {
    static let shared = ChangeFeeds()

    /// A feed this recent is reused; what lands after is within every
    /// store's own overlap next time.
    static let freshFor: TimeInterval = 15

    /// What one run searches with; the GitHub search unless a test passes its own.
    typealias Search = (GitHubAPI, _ org: String, _ outsideBatches: [[String]], _ since: Date) async throws -> (entries: [ChangeEntry], capped: Bool)

    private let search: Search
    private var feeds: [String: ChangeFeed] = [:]
    private var running: [String: Task<ChangeFeed?, Never>] = [:]
    /// Bumped by `clear`, so a run that started before it doesn't store its
    /// feed (the last account's) afterwards.
    private var generation = 0

    init(search: @escaping Search = { api, org, batches, since in
        try await api.changeEntries(org: org, outsideBatches: batches, since: since)
    }) {
        self.search = search
    }

    /// The org's feed, brought up to date unless a run is under way (awaited)
    /// or just finished; nil when the search failed, so a store falls back.
    /// `cursor` is the caller's own, which sets how far back a first run
    /// searches. `outside` is the outside repos the caller needs covered
    /// (none for the work log, which only reads the account's own): a feed
    /// that covers more is reused, one that covers fewer is extended, so
    /// stores with different views of which repos are readable don't undo
    /// each other. `run` shows the search as a step of the caller's sync when
    /// this call is the one that starts it.
    func current(org: String, api: GitHubAPI, outside: Set<String> = [], cursor: Date, run: SyncRun? = nil) async -> ChangeFeed? {
        // A run under way may cover fewer repos than this caller needs. A
        // failed run isn't retried, as the store falls back; a feed that
        // covers too little is extended by a second run, started once the
        // first has cleared `running`.
        for _ in 0..<2 {
            if let task = running[org] {
                guard let feed = await task.value else { return nil }
                if outside.isSubset(of: feed.outsideRepos) { return feed }
                continue
            }
            if let feed = feeds[org], Date.now.timeIntervalSince(feed.lastRunAt) < Self.freshFor, outside.isSubset(of: feed.outsideRepos) {
                return feed
            }
            let started = generation
            let task = Task {
                let feed = await self.refresh(org: org, api: api, outside: outside, cursor: cursor, run: run)
                if started == self.generation { self.running[org] = nil }
                return feed
            }
            running[org] = task
            return await task.value
        }
        return nil
    }

    func clear() {
        generation += 1
        feeds = [:]
        running.values.forEach { $0.cancel() }
        running = [:]
    }

    private func refresh(org: String, api: GitHubAPI, outside: Set<String>, cursor: Date, run: SyncRun?) async -> ChangeFeed? {
        let started = generation
        let previous = feeds[org]
        let outsideRepos = outside.union(previous?.outsideRepos ?? [])
        let now = Date.now
        let continuing = previous?.outsideRepos == outsideRepos
        let since = continuing
            ? (previous?.lastRunAt ?? now).addingTimeInterval(-ChangeFeed.overlap)
            : max(cursor, now.addingTimeInterval(-ChangeFeed.retention))
        let batches = GitHubAPI.outsideRepoBatches(outsideRepos)
        do {
            let search = { try await chargingTo(.changeFeed) { try await self.search(api, org, batches, since) } }
            let result: (entries: [ChangeEntry], capped: Bool)
            if let run {
                run.add("change-feed", title: "Change feed", detail: "Updated since \(since.formatted(date: .omitted, time: .shortened))")
                result = try await run.track("change-feed", count: { $0.entries.count }) { _ in try await search() }
            } else {
                result = try await search()
            }
            let feed = ChangeFeed.updated(previous, found: result.entries, capped: result.capped, outsideRepos: outsideRepos, since: since, now: now)
            guard started == generation else { return nil }
            feeds[org] = feed
            return feed
        } catch {
            return nil
        }
    }
}
