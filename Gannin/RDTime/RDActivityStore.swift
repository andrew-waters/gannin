import Foundation
import Observation

/// The activity R&D Time allocates from, fetched only when asked on the
/// page, never by Refresh or any automatic sync: a year of it is many
/// searches. Each fetch is planned and priced first (one cheap count query),
/// confirmed, run a week at a time with progress, and can be cancelled.
/// What's fetched is kept in its own file, contiguous from `coveredFrom`
/// to `fetchedAt`, so a cancelled fetch keeps its weeks and the next picks
/// up where it stopped.
@Observable
final class RDActivityStore {
    /// The PRs and issues updated since `coveredFrom`, as of `fetchedAt`,
    /// and the issues their work went to, for what counts.
    struct Cache: Codable {
        static let currentVersion = 1

        var version = Self.currentVersion
        let org: String
        var coveredFrom: Date
        var fetchedAt: Date
        var pullRequests: [String: WorkLogPullRequest] = [:]
        var issues: [String: WorkLogIssue] = [:]
        /// The issues time went to (and their parents), for labels, fields
        /// and parents.
        var records: [String: IssueRecord] = [:]
        /// Issues GitHub returned nothing for (deleted, or out of reach), so
        /// they aren't asked for again.
        var unreadable: Set<String> = []

        /// Issues to look up: touched, not held and not unreadable.
        var missingRecords: Set<String> { touchedIssueIDs.subtracting(records.keys).subtracting(unreadable) }

        /// The issues time could go to, and their parents, by node ID.
        var touchedIssueIDs: Set<String> {
            var ids = Set(issues.keys)
            for pr in pullRequests.values { ids.formUnion(pr.closingIssues.map(\.id)) }
            ids.formUnion(records.values.compactMap(\.parentID))
            return ids
        }
    }

    /// What a fetch would search, and what it should cost.
    struct Plan: Identifiable {
        struct Week {
            let start: Date
            /// Nil for the open-ended search up to now.
            let end: Date?
            var pullRequests = 0
            var issues = 0
        }

        let id = UUID()
        let org: String
        /// Where coverage reaches once it's done.
        let start: Date
        /// Searches up to now, newest first.
        var topUp: [Week]
        /// Searches further back, newest first, so coverage stays contiguous
        /// as each finishes.
        var backfill: [Week]
        /// Issues already known but not yet looked up.
        var missingRecords: Int

        var weeks: [Week] { topUp + backfill }
        var pullRequests: Int { weeks.reduce(0) { $0 + min($1.pullRequests, Self.searchCap) } }
        var issues: Int { weeks.reduce(0) { $0 + min($1.issues, Self.searchCap) } }

        /// GitHub stops a search at 1000 results.
        static let searchCap = 1000
        static let pullRequestPage = 20
        static let issuePage = 50
        static let recordBatch = 15

        /// Requests: a page per 20 PRs and 50 issues in each week (at least
        /// one each), and a batch per 15 issues looked up, guessing one
        /// issue looked up per two PRs and issues found.
        var requests: Int {
            let searches = weeks.reduce(0) { total, week in
                total + Self.pages(min(week.pullRequests, Self.searchCap), Self.pullRequestPage)
                    + Self.pages(min(week.issues, Self.searchCap), Self.issuePage)
            }
            return searches + Self.pages(missingRecords + (pullRequests + issues) / 2, Self.recordBatch)
        }

        /// GraphQL points: about one per search page and two per batch of
        /// issues looked up, as GitHub prices these queries.
        var points: Int { requests + Self.pages(missingRecords + (pullRequests + issues) / 2, Self.recordBatch) }

        var isEmpty: Bool { weeks.isEmpty && missingRecords == 0 }

        private static func pages(_ count: Int, _ size: Int) -> Int { max(1, (count + size - 1) / size) }
    }

    /// A fetch under way.
    struct Progress: Equatable {
        var weeksDone = 0
        var weeks = 0
        var pullRequests = 0
        var issues = 0
        var records = 0
        var step = "Starting"
    }

    private(set) var caches: [String: Cache] = [:]
    /// Orgs whose cost is being counted.
    private(set) var estimating: Set<String> = []
    private(set) var progress: [String: Progress] = [:]
    /// Why the last fetch stopped short, if it did.
    private(set) var notices: [String: String] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]

    private let auth: AuthStore
    private let directory: URL
    /// Overlap on the top-up search, so an update landing mid-fetch isn't missed.
    private static let overlap: TimeInterval = 5 * 60
    /// Points left untouched, so a long fetch never empties the budget the
    /// rest of the app needs.
    static let reserve = 500

    init(auth: AuthStore, directory: URL = RDActivityStore.defaultDirectory) {
        self.auth = auth
        self.directory = directory
    }

    func cache(for org: String) -> Cache? {
        if caches[org] == nil { loadCached(org) }
        return caches[org]
    }

    func isFetching(_ org: String) -> Bool { progress[org] != nil }

    // MARK: Planning

    /// The searches that would bring coverage back to `start`, and up to
    /// now when the range runs past the last fetch (`through`), each week
    /// counted (one query, a point or so), so the cost can be shown before
    /// anything is fetched.
    func plan(org: String, from start: Date, through end: Date, now: Date = .now) async throws -> Plan {
        guard let api = auth.api else { throw APIError.unauthorized }
        estimating.insert(org)
        defer { estimating.remove(org) }
        var plan = Self.weeks(cache: cache(for: org), org: org, from: start, through: end, now: now)
        let keyed = Dictionary(uniqueKeysWithValues: plan.weeks.enumerated().flatMap { index, week in
            [("p\(index)", GitHubAPI.workLogSearch(org: org, from: week.start, to: week.end)),
             ("i\(index)", GitHubAPI.workLogIssueSearch(org: org, from: week.start, to: week.end))]
        })
        if !keyed.isEmpty {
            let counts = try await chargingTo(.rdTime) { try await RequestLimiter.interactive { try await api.counts(searches: keyed) } }
            func fill(_ weeks: inout [Plan.Week], offset: Int) {
                for index in weeks.indices {
                    weeks[index].pullRequests = counts["p\(index + offset)"] ?? 0
                    weeks[index].issues = counts["i\(index + offset)"] ?? 0
                }
            }
            fill(&plan.topUp, offset: 0)
            fill(&plan.backfill, offset: plan.topUp.count)
        }
        return plan
    }

    /// The weeks to search: from `fetchedAt` up to now (only when the range
    /// runs past it: activity before then is held as it was when each PR
    /// was last updated), and from `coveredFrom` back to `start`, a week a
    /// search so none reaches GitHub's cap; with nothing fetched yet,
    /// `start` to now. Searches go by when a PR or issue was last updated,
    /// so anything with activity since `start` is found whenever it ended.
    static func weeks(cache: Cache?, org: String, from start: Date, through end: Date, now: Date) -> Plan {
        let missing = cache?.missingRecords.count ?? 0
        guard let cache else {
            return Plan(org: org, start: start, topUp: [], backfill: weeks(from: start, to: now, openEnded: true), missingRecords: 0)
        }
        let topUp = end > cache.fetchedAt ? weeks(from: cache.fetchedAt.addingTimeInterval(-overlap), to: now, openEnded: true) : []
        let backfill = start < cache.coveredFrom ? weeks(from: start, to: cache.coveredFrom, openEnded: false) : []
        return Plan(org: org, start: min(start, cache.coveredFrom), topUp: topUp, backfill: backfill, missingRecords: missing)
    }

    /// Week-long searches between the dates, newest first; the newest is
    /// open-ended when it runs to now.
    private static func weeks(from start: Date, to end: Date, openEnded: Bool) -> [Plan.Week] {
        guard start < end else { return [] }
        let spans = ParallelSearches.weeks(from: start, to: end)
        return spans.enumerated().map { index, span in
            Plan.Week(start: span.0, end: openEnded && index == spans.count - 1 ? nil : span.1)
        }.reversed()
    }

    // MARK: Fetching

    /// Runs the plan: top-up first, then each week further back, saving as
    /// each finishes; then looks up the issues the time went to.
    func fetch(_ plan: Plan) {
        let org = plan.org
        guard tasks[org] == nil else { return }
        notices[org] = nil
        progress[org] = Progress(weeks: plan.weeks.count)
        tasks[org] = Task { [weak self] in
            await self?.run(plan)
            self?.tasks[org] = nil
            self?.progress[org] = nil
        }
    }

    /// Stops the fetch; the weeks already fetched are kept.
    func cancel(_ org: String) {
        tasks[org]?.cancel()
        notices[org] = "Cancelled. What was fetched is kept, and fetching again carries on from there."
    }

    /// Forgets the org's fetched activity.
    func clear(_ org: String) {
        cancel(org)
        caches[org] = nil
        notices[org] = nil
        try? FileManager.default.removeItem(at: fileURL(org))
    }

    private func run(_ plan: Plan) async {
        let org = plan.org
        guard let api = auth.api else { return }
        let now = Date.now
        var cache = cache(for: org) ?? Cache(org: org, coveredFrom: now, fetchedAt: now)
        do {
            try await chargingTo(.rdTime) {
                for week in plan.topUp {
                    try await fetchWeek(week, into: &cache, api: api)
                }
                if !plan.topUp.isEmpty || caches[org] == nil {
                    cache.fetchedAt = now
                    if caches[org] == nil { cache.coveredFrom = plan.topUp.last?.start ?? now }
                    save(cache)
                }
                for week in plan.backfill {
                    try await fetchWeek(week, into: &cache, api: api)
                    cache.coveredFrom = min(cache.coveredFrom, week.start)
                    save(cache)
                }
                try await lookUpIssues(into: &cache, api: api)
            }
        } catch is CancellationError {
            save(cache)
        } catch APIError.unauthorized {
            save(cache)
            auth.signOut()
        } catch let error as Stop {
            save(cache)
            notices[org] = error.message
        } catch {
            save(cache)
            notices[org] = "Stopped: \(error.localizedDescription). What was fetched is kept, and fetching again carries on from there."
        }
    }

    private struct Stop: Error {
        let message: String
    }

    private func checkBudget() throws {
        try Task.checkCancellation()
        if auth.isPaused || (auth.rateLimit.map { $0.remaining < Self.reserve && $0.resetAt > .now } ?? false) {
            let reset = auth.rateLimit?.resetAt.formatted(date: .omitted, time: .shortened) ?? "the reset"
            throw Stop(message: "Paused to keep \(Self.reserve) points of the GitHub budget for the rest of Gannin. What was fetched is kept; fetch again after \(reset) to carry on.")
        }
    }

    private func fetchWeek(_ week: Plan.Week, into cache: inout Cache, api: GitHubAPI) async throws {
        let org = cache.org
        try checkBudget()
        progress[org]?.step = "Week of \(week.start.formatted(date: .abbreviated, time: .omitted))"
        let prs = try await RequestLimiter.interactive {
            try await api.workLogPullRequests(query: GitHubAPI.workLogSearch(org: org, from: week.start, to: week.end))
        }
        try checkBudget()
        let issues = try await RequestLimiter.interactive {
            try await api.workLogIssues(query: GitHubAPI.workLogIssueSearch(org: org, from: week.start, to: week.end))
        }
        for pr in prs { cache.pullRequests[pr.id] = pr }
        for issue in issues { cache.issues[issue.id] = issue }
        progress[org]?.weeksDone += 1
        progress[org]?.pullRequests += prs.count
        progress[org]?.issues += issues.count
    }

    /// Looks up the issues time went to that aren't held yet, then their
    /// parents, a batch at a time.
    private func lookUpIssues(into cache: inout Cache, api: GitHubAPI) async throws {
        let org = cache.org
        for _ in 0..<2 {
            let missing = cache.missingRecords.sorted()
            guard !missing.isEmpty else { return }
            progress[org]?.step = "Looking up \(missing.count) issues"
            for batch in stride(from: 0, to: missing.count, by: 60).map({ Array(missing[$0..<min($0 + 60, missing.count)]) }) {
                try checkBudget()
                let records = try await RequestLimiter.interactive { try await api.issueRecords(ids: batch) }
                for record in records { cache.records[record.id] = record }
                cache.unreadable.formUnion(batch.filter { cache.records[$0] == nil })
                progress[org]?.records += records.count
                save(cache)
            }
        }
    }

    // MARK: Disk

    private func loadCached(_ org: String) {
        guard let data = try? Data(contentsOf: fileURL(org)),
              let cache = try? Self.decoder.decode(Cache.self, from: data), cache.version == Cache.currentVersion else { return }
        caches[org] = cache
    }

    private func save(_ cache: Cache) {
        caches[cache.org] = cache
        if let data = try? Self.encoder.encode(cache) {
            try? data.write(to: fileURL(cache.org), options: .atomic)
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static var defaultDirectory: URL {
        AppPaths.support.appending(path: "RDTime", directoryHint: .isDirectory)
    }

    private func fileURL(_ org: String) -> URL {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "\(org).json")
    }
}
