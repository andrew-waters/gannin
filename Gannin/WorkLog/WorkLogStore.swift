import Foundation
import Observation

/// Recent PR and issue activity per org for the work log, persisted as JSON in
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
    private let pullRequestStore: PullRequestStore
    private let issueStore: SharedIssueStore
    private let directory: URL

    init(
        auth: AuthStore, activity: SyncActivity, pullRequestStore: PullRequestStore = .shared,
        issueStore: SharedIssueStore = .shared, directory: URL = WorkLogStore.defaultDirectory
    ) {
        self.auth = auth
        self.activity = activity
        self.pullRequestStore = pullRequestStore
        self.issueStore = issueStore
        self.directory = directory
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
        // Backfilled weeks are searched for PRs and again for issues. What
        // changed since the last sync comes from the change feed for PRs and
        // issues when it can say, each falling back to its own changes search.
        var searches: [String] = []
        // Issue searches as ranges, so one that reaches the cap can be cut into days.
        var issueRanges: [(from: Date, to: Date?)] = []
        var feedIDs: [String]?
        var feedIssueIDs: [String]?
        if let history {
            if start < history.coveredFrom {
                for week in ParallelSearches.weeks(from: start, to: history.coveredFrom) {
                    searches.append(GitHubAPI.workLogSearch(org: org, from: week.0, to: week.1))
                    issueRanges.append((week.0, week.1))
                }
            }
            if auth.shouldFetch(.workLog, since: history.fetchedAt, now: now, force: force) {
                let cursor = history.fetchedAt.addingTimeInterval(-Self.overlap)
                let feed = await ChangeFeeds.shared.current(org: org, api: api, cursor: cursor)
                if case .fetch(let entries) = Self.feedPlan(feed, cursor: cursor, history: history) {
                    feedIDs = entries.map(\.id)
                } else {
                    searches.append(GitHubAPI.workLogSearch(org: org, from: cursor))
                }
                if case .fetch(let entries) = Self.issueFeedPlan(feed, cursor: cursor, history: history) {
                    feedIssueIDs = entries.map(\.id)
                } else {
                    issueRanges.append((cursor, nil))
                }
            }
        } else {
            let weeks = ParallelSearches.weeks(from: start, to: now)
            for week in weeks.dropLast() {
                searches.append(GitHubAPI.workLogSearch(org: org, from: week.0, to: week.1))
                issueRanges.append((week.0, week.1))
            }
            if let last = weeks.last {
                searches.append(GitHubAPI.workLogSearch(org: org, from: last.0))
                issueRanges.append((last.0, nil))
            }
        }
        guard !searches.isEmpty || !issueRanges.isEmpty || feedIDs != nil || feedIssueIDs != nil else { return }

        let run = activity.begin(.workLog, org: org)
        func detail(_ count: Int) -> String {
            history == nil
                ? "Last \(calendar.dateComponents([.day], from: start, to: now).day ?? Self.keptDays) days, \(count) searches"
                : "\(count == 1 ? "1 search" : "\(count) searches")"
        }
        run.add("prs", title: "PR activity", detail: feedIDs.map { "\(detail(searches.count)), \($0.count) from the change feed" } ?? detail(searches.count))
        run.add("issues", title: "Issues and comments", detail: feedIssueIDs.map { "\(detail(issueRanges.count)), \($0.count) from the change feed" } ?? detail(issueRanges.count))

        func issueSearches(_ ranges: [(from: Date, to: Date?)]) -> [String] {
            ranges.map { GitHubAPI.workLogIssueSearch(org: org, from: $0.from, to: $0.to) }
        }
        let keyed = Dictionary(uniqueKeysWithValues: searches.enumerated().map { ("w\($0.offset)", $0.element) }
            + issueSearches(issueRanges).enumerated().map { ("i\($0.offset)", $0.element) })
        let counts = try? await run.overhead({ try await api.counts(searches: keyed) })
        if let counts {
            run.setTotal(counts.filter { $0.key.hasPrefix("w") }.values.map { min($0, 1000) }.reduce(0, +) + (feedIDs?.count ?? 0), for: "prs")
        }
        // A search that reached the cap lost issues, so its range is searched a
        // day at a time. A range whose count is unknown (the count failed) is
        // treated as capped, since searching it whole could drop issues silently.
        let capped = issueRanges.indices.filter { index in
            counts?["i\(index)"].map { $0 >= ParallelSearches.searchCap } ?? true
        }
        let split = Self.splittingCapped(issueRanges, at: Set(capped), now: now)
        var issueTotal = counts.map { $0.filter { $0.key.hasPrefix("i") }.values.map { min($0, 1000) }.reduce(0, +) + (feedIssueIDs?.count ?? 0) }
        if split.count != issueRanges.count {
            issueRanges = split
            let recount = Dictionary(uniqueKeysWithValues: issueSearches(split).enumerated().map { ("i\($0.offset)", $0.element) })
            issueTotal = (try? await run.overhead({ try await api.counts(searches: recount) }))
                .map { $0.values.map { min($0, 1000) }.reduce(0, +) + (feedIssueIDs?.count ?? 0) }
        }
        if let issueTotal { run.setTotal(issueTotal, for: "issues") }
        let issueQueries = issueSearches(issueRanges)
        do {
            let prs = try await run.track("prs", count: \.count) { progress in
                var found = try await Self.fetch(searches, api: api, progress: progress)
                if let feedIDs, !feedIDs.isEmpty { found += try await api.workLogPullRequests(ids: feedIDs) }
                return found
            }
            // Issues are a step of their own: when they fail (the step says
            // why), the PRs are still kept, and the coverage stays where it
            // was so the next sync searches the same weeks again.
            let issues = try? await run.track("issues", count: \.count) { progress in
                var found = try await Self.fetchIssues(issueQueries, api: api, progress: progress)
                if let feedIssueIDs, !feedIssueIDs.isEmpty { found += try await api.workLogIssues(ids: feedIssueIDs) }
                return found
            }
            // A new log whose issues failed covers nothing yet, so the next
            // sync backfills the range a week at a time again (one search
            // over it all could pass GitHub's cap of 1000).
            var updated = history ?? WorkLogHistory(orgLogin: org, coveredFrom: issues == nil ? now : start, fetchedAt: now, pullRequests: [:])
            for pr in prs { updated.pullRequests[pr.id] = pr }
            if let issues {
                for issue in issues { updated.issues[issue.id] = issue }
                updated.coveredFrom = min(updated.coveredFrom, start)
                updated.fetchedAt = now
            }
            histories[org] = updated
            errors[org] = nil
            save(updated, merging: prs, issues: issues ?? [])
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

    /// The issues to fetch from `feed`, or a fallback to the work log's own
    /// search, which covers only the account's own repos. An issue whose
    /// `updatedAt` is already held isn't fetched.
    static func issueFeedPlan(_ feed: ChangeFeed?, cursor: Date, history: WorkLogHistory) -> ChangeFeed.Plan {
        ChangeFeed.plan(
            feed: feed, cursor: cursor,
            include: { $0.kind == .issue && !$0.isOutside },
            stored: { history.issues[$0]?.updatedAt }
        )
    }

    /// `ranges` with each one at an index in `capped` replaced by day-long
    /// ranges, since a search over a capped range returns only its first 1000
    /// issues. An open-ended range runs to `now`.
    static func splittingCapped(_ ranges: [(from: Date, to: Date?)], at capped: Set<Int>, now: Date) -> [(from: Date, to: Date?)] {
        ranges.enumerated().flatMap { index, range -> [(from: Date, to: Date?)] in
            guard capped.contains(index) else { return [range] }
            let days = ParallelSearches.days(from: range.from, to: range.to ?? now)
            // A range of a day or less can't be cut any finer.
            return days.count > 1 ? days.map { (from: $0.0, to: Optional($0.1)) } : [range]
        }
    }

    /// Runs the searches in parallel, reporting PRs fetched across them all.
    private static func fetch(_ searches: [String], api: GitHubAPI, progress: @escaping (Int, Int?) -> Void) async throws -> [WorkLogPullRequest] {
        try await ParallelSearches.run(count: searches.count, progress: progress) { index, fetched in
            try await api.workLogPullRequests(query: searches[index]) { count, _ in fetched(count) }
        }
    }

    /// Runs the issue searches in parallel, reporting issues fetched across them all.
    private static func fetchIssues(_ searches: [String], api: GitHubAPI, progress: @escaping (Int, Int?) -> Void) async throws -> [WorkLogIssue] {
        try await ParallelSearches.run(count: searches.count, progress: progress) { index, fetched in
            try await api.workLogIssues(query: searches[index]) { count, _ in fetched(count) }
        }
    }

    static var cacheDirectory: URL { defaultDirectory }

    /// Also removes the work log's part of every stored PR and issue: the log
    /// is rebuilt from them, so a log kept after they're gone would claim a
    /// coverage it no longer has.
    func clear() {
        histories = [:]
        errors = [:]
        try? FileManager.default.removeItem(at: directory)
        pullRequestStore.clear(.workLog)
        issueStore.clear(.workLog)
    }

    // MARK: Disk cache

    /// A log from before PRs, or issues, were kept in the shared stores brings
    /// them along, so the upgrade doesn't fetch them again; its file is then
    /// rewritten without them.
    func loadCached(_ org: String) {
        guard histories[org] == nil,
              let data = try? Data(contentsOf: fileURL(org)),
              var history = try? Self.decoder.decode(WorkLogHistory.self, from: data),
              let version = history.version else {
            return
        }
        if version == WorkLogHistory.Legacy.version {
            guard let legacy = try? Self.decoder.decode(WorkLogHistory.Legacy.self, from: data) else { return }
            pullRequestStore.merge(legacy.pullRequests.values.map { StoredPullRequest(workLog: $0) }, org: org)
            history.pullRequests = legacy.pullRequests
        } else if version == WorkLogHistory.currentVersion || WorkLogHistory.LegacyIssues.versions.contains(version) {
            history.pullRequests = Dictionary(uniqueKeysWithValues: pullRequestStore.pullRequests(org: org).values.compactMap { stored in
                stored.workLogPullRequest.map { ($0.id, $0) }
            })
            guard history.pullRequests.count >= (history.storedCount ?? 0) else { return }
        } else {
            return
        }

        if version == WorkLogHistory.currentVersion {
            history.issues = Dictionary(uniqueKeysWithValues: issueStore.issues(org: org).values.compactMap { stored in
                stored.workLogIssue.map { ($0.id, $0) }
            })
            guard history.issues.count >= (history.storedIssueCount ?? 0) else { return }
        } else {
            let legacy = (try? Self.decoder.decode(WorkLogHistory.LegacyIssues.self, from: data))?.issues ?? [:]
            history.issues = legacy
            history.version = WorkLogHistory.currentVersion
            issueStore.mergeCarriedOver(legacy.values.map { StoredIssue(workLog: $0) }, org: org)
            save(history, merging: [], issues: [])
        }
        histories[org] = history
    }

    /// The PRs and issues go to their stores first: a log saved without them
    /// would claim a coverage the stores don't have.
    private func save(_ history: WorkLogHistory, merging fetched: [WorkLogPullRequest], issues fetchedIssues: [WorkLogIssue]) {
        pullRequestStore.merge(fetched.map { StoredPullRequest(workLog: $0) }, org: history.orgLogin)
        issueStore.merge(fetchedIssues.map { StoredIssue(workLog: $0) }, org: history.orgLogin)
        var saved = history
        saved.storedCount = history.pullRequests.count
        saved.storedIssueCount = history.issues.count
        if let data = try? Self.encoder.encode(saved) {
            try? data.write(to: fileURL(history.orgLogin), options: .atomic)
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
        AppPaths.support.appending(path: "WorkLog", directoryHint: .isDirectory)
    }

    private func fileURL(_ org: String) -> URL {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "\(org).json")
    }
}
