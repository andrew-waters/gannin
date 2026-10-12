import Foundation
import Observation

/// Recent PR activity per org for the work log, persisted as JSON in
/// Application Support. Only fetched for orgs whose work log has been opened.
@Observable
final class WorkLogStore {
    /// Days fetched up front; paging further back fetches more.
    static let keptDays = 28
    /// Overlap on the changes search, so an update landing mid-fetch isn't missed.
    private static let overlap: TimeInterval = 5 * 60

    private(set) var histories: [String: WorkLogHistory] = [:]
    private(set) var syncing: Set<String> = []
    private(set) var errors: [String: String] = [:]

    private let auth: AuthStore
    private let activity: SyncActivity

    init(auth: AuthStore, activity: SyncActivity) {
        self.auth = auth
        self.activity = activity
    }

    func history(for org: String) -> WorkLogHistory? { histories[org] }

    /// PRs fetched one by one for an issue's timeline, by URL; in memory.
    private(set) var linked: [URL: WorkLogPullRequest] = [:]
    @ObservationIgnored private var fetchingLinked: Set<URL> = []

    /// The PR as the work log has it, else as fetched for a timeline.
    func pullRequest(org: String, url: URL) -> WorkLogPullRequest? {
        histories[org]?.pullRequests.values.first { $0.url == url } ?? linked[url]
    }

    /// Fetches the PRs neither the work log nor an earlier call has.
    func loadLinked(org: String, urls: [URL]) async {
        let missing = urls.filter { pullRequest(org: org, url: $0) == nil && !fetchingLinked.contains($0) }
        guard let api = auth.api, !missing.isEmpty else { return }
        fetchingLinked.formUnion(missing)
        defer { fetchingLinked.subtract(missing) }
        for pr in (try? await chargingTo(.details) { try await RequestLimiter.interactive { try await api.workLogPullRequests(urls: missing) } }) ?? [] {
            linked[pr.url] = pr
        }
    }

    /// Whether this org's log has been loaded, so Refresh includes it.
    func isTracking(_ org: String) -> Bool { histories[org] != nil }

    /// Brings the org's log up to date, reaching back to `from` (default
    /// the last `keptDays`). Missing weeks are searched a week at a time,
    /// several at once; a stored range only needs what changed since.
    func sync(_ org: String, from requested: Date? = nil, force: Bool = false) async {
        loadCached(org)
        guard let api = auth.api, !syncing.contains(org), SyncSettings.isOn(.workLog) else { return }
        // Held from here, since the change feed is awaited before the work.
        syncing.insert(org)
        defer { syncing.remove(org) }
        let now = Date.now
        let calendar = Calendar.current
        let defaultStart = calendar.date(byAdding: .day, value: -Self.keptDays, to: calendar.startOfDay(for: now)) ?? now
        let start = min(requested ?? defaultStart, defaultStart)
        let history = histories[org]

        // Searches, each a week of "last updated", so none reaches the cap.
        var searches: [String] = []
        var feedIDs: [String]?
        if let history {
            if start < history.coveredFrom {
                searches += ParallelSearches.weeks(from: start, to: history.coveredFrom).map { GitHubAPI.workLogSearch(org: org, from: $0.0, to: $0.1) }
            }
            if auth.shouldFetch(.workLog, since: history.fetchedAt, now: now, force: force) {
                // From the change feed when it can say; its own search is the fallback.
                let cursor = history.fetchedAt.addingTimeInterval(-Self.overlap)
                let feed = await ChangeFeeds.shared.current(org: org, api: api, cursor: cursor)
                if case .fetch(let entries) = Self.feedPlan(feed, cursor: cursor, history: history) {
                    feedIDs = entries.map(\.id)
                } else {
                    searches.append(GitHubAPI.workLogSearch(org: org, from: cursor))
                }
            }
        } else {
            let weeks = ParallelSearches.weeks(from: start, to: now)
            searches += weeks.dropLast().map { GitHubAPI.workLogSearch(org: org, from: $0.0, to: $0.1) }
            if let last = weeks.last { searches.append(GitHubAPI.workLogSearch(org: org, from: last.0)) }
        }
        guard !searches.isEmpty || feedIDs != nil else { return }

        let run = activity.begin(.workLog, org: org)
        let detail = history == nil
            ? "Last \(calendar.dateComponents([.day], from: start, to: now).day ?? Self.keptDays) days, \(searches.count) searches"
            : "\(searches.count == 1 ? "1 search" : "\(searches.count) searches")"
        run.add("prs", title: "PR activity", detail: feedIDs.map { "\(detail), \($0.count) from the change feed" } ?? detail)

        let keyed = Dictionary(uniqueKeysWithValues: searches.enumerated().map { ("w\($0.offset)", $0.element) })
        if let counts = try? await run.overhead({ try await api.counts(searches: keyed) }) {
            run.setTotal(counts.values.map { min($0, 1000) }.reduce(0, +) + (feedIDs?.count ?? 0), for: "prs")
        }
        do {
            let prs = try await run.track("prs", count: \.count) { progress in
                var found = try await Self.fetch(searches, api: api, progress: progress)
                if let feedIDs, !feedIDs.isEmpty { found += try await api.workLogPullRequests(ids: feedIDs) }
                return found
            }
            var updated = history ?? WorkLogHistory(orgLogin: org, coveredFrom: start, fetchedAt: now, pullRequests: [:])
            for pr in prs { updated.pullRequests[pr.id] = pr }
            updated.coveredFrom = min(updated.coveredFrom, start)
            updated.fetchedAt = now
            histories[org] = updated
            errors[org] = nil
            save(updated)
            run.finish()
        } catch is CancellationError {
            run.finish()
        } catch APIError.unauthorized {
            run.finish(error: APIError.unauthorized)
            auth.signOut()
        } catch {
            run.finish(error: error)
            errors[org] = error.localizedDescription
        }
    }

    /// The PRs to fetch from `feed`, or a fallback to the work log's own
    /// search, which covers only the account's own repos. A PR whose
    /// `updatedAt` is already held isn't fetched.
    static func feedPlan(_ feed: ChangeFeed?, cursor: Date, history: WorkLogHistory) -> ChangeFeed.Plan {
        ChangeFeed.plan(
            feed: feed, cursor: cursor,
            include: { $0.kind == .pullRequest && !$0.isOutside },
            stored: { history.pullRequests[$0]?.updatedAt }
        )
    }

    /// Runs the searches in parallel, reporting PRs fetched across them all.
    private static func fetch(_ searches: [String], api: GitHubAPI, progress: @escaping (Int, Int?) -> Void) async throws -> [WorkLogPullRequest] {
        try await ParallelSearches.run(count: searches.count, progress: progress) { index, fetched in
            try await api.workLogPullRequests(query: searches[index]) { count, _ in fetched(count) }
        }
    }

    static var cacheDirectory: URL { directory }

    func clear() {
        histories = [:]
        errors = [:]
        try? FileManager.default.removeItem(at: Self.directory)
    }

    // MARK: Disk cache

    private func loadCached(_ org: String) {
        guard histories[org] == nil,
              let data = try? Data(contentsOf: Self.fileURL(org)),
              let history = try? Self.decoder.decode(WorkLogHistory.self, from: data),
              history.version == WorkLogHistory.currentVersion else {
            return
        }
        histories[org] = history
    }

    private func save(_ history: WorkLogHistory) {
        if let data = try? Self.encoder.encode(history) {
            try? data.write(to: Self.fileURL(history.orgLogin), options: .atomic)
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

    private static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "WorkLog", directoryHint: .isDirectory)
    }

    private static func fileURL(_ org: String) -> URL {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "\(org).json")
    }
}

