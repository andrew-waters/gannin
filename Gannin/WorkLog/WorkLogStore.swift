import Foundation
import Observation

/// Recent PR activity per org for the work log, persisted as JSON in
/// Application Support. Only fetched for orgs whose work log has been opened.
@Observable
final class WorkLogStore {
    /// Days fetched up front; paging further back fetches more.
    static let keptDays = 28
    private static let maxAge: TimeInterval = 10 * 60
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

    /// Whether this org's log has been loaded, so Refresh includes it.
    func isTracking(_ org: String) -> Bool { histories[org] != nil }

    /// Brings the org's log up to date, reaching back to `from` (default
    /// the last `keptDays`). Missing weeks are searched a week at a time,
    /// several at once; a stored range only needs what changed since.
    func sync(_ org: String, from requested: Date? = nil, force: Bool = false) async {
        loadCached(org)
        guard let api = auth.api, !syncing.contains(org) else { return }
        let now = Date.now
        let calendar = Calendar.current
        let defaultStart = calendar.date(byAdding: .day, value: -Self.keptDays, to: calendar.startOfDay(for: now)) ?? now
        let start = min(requested ?? defaultStart, defaultStart)
        let history = histories[org]

        // Searches, each a week of "last updated", so none reaches the cap.
        var searches: [String] = []
        if let history {
            if start < history.coveredFrom {
                searches += Self.weeks(from: start, to: history.coveredFrom).map { GitHubAPI.workLogSearch(org: org, from: $0.0, to: $0.1) }
            }
            let isStale = now.timeIntervalSince(history.fetchedAt) >= Self.maxAge
            if force || (isStale && !auth.shouldHoldOff) {
                searches.append(GitHubAPI.workLogSearch(org: org, from: history.fetchedAt.addingTimeInterval(-Self.overlap)))
            }
        } else {
            let weeks = Self.weeks(from: start, to: now)
            searches += weeks.dropLast().map { GitHubAPI.workLogSearch(org: org, from: $0.0, to: $0.1) }
            if let last = weeks.last { searches.append(GitHubAPI.workLogSearch(org: org, from: last.0)) }
        }
        guard !searches.isEmpty else { return }

        syncing.insert(org)
        defer { syncing.remove(org) }
        let run = activity.begin(.workLog, org: org)
        let detail = history == nil
            ? "Last \(calendar.dateComponents([.day], from: start, to: now).day ?? Self.keptDays) days, \(searches.count) searches"
            : "\(searches.count == 1 ? "1 search" : "\(searches.count) searches")"
        run.add("prs", title: "PR activity", detail: detail)

        let keyed = Dictionary(uniqueKeysWithValues: searches.enumerated().map { ("w\($0.offset)", $0.element) })
        if let counts = try? await run.overhead({ try await api.counts(searches: keyed) }) {
            run.setTotal(counts.values.map { min($0, 1000) }.reduce(0, +), for: "prs")
        }
        do {
            let prs = try await run.track("prs", count: \.count) { progress in
                try await Self.fetch(searches, api: api, progress: progress)
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

    /// Searches run at most this many at once, to stay clear of GitHub's
    /// secondary rate limits.
    private static let concurrency = 4

    /// Runs the searches in parallel, reporting PRs fetched across them all.
    private static func fetch(_ searches: [String], api: GitHubAPI, progress: @escaping (Int, Int?) -> Void) async throws -> [WorkLogPullRequest] {
        let tally = Tally(report: progress)
        func task(_ index: Int) -> @MainActor @Sendable () async throws -> [WorkLogPullRequest] {
            let query = searches[index]
            return { try await api.workLogPullRequests(query: query) { fetched, _ in tally.set(index, fetched) } }
        }
        return try await withThrowingTaskGroup(of: [WorkLogPullRequest].self) { group in
            var next = 0
            while next < min(concurrency, searches.count) {
                group.addTask(operation: task(next))
                next += 1
            }
            var results: [WorkLogPullRequest] = []
            while let batch = try await group.next() {
                results += batch
                if next < searches.count {
                    group.addTask(operation: task(next))
                    next += 1
                }
            }
            return results
        }
    }

    /// Week-long `[start, end)` ranges covering `[from, to)`.
    private static func weeks(from: Date, to: Date) -> [(Date, Date)] {
        var ranges: [(Date, Date)] = []
        var start = from
        while start < to {
            let end = min(Calendar.current.date(byAdding: .day, value: 7, to: start) ?? to, to)
            ranges.append((start, end))
            start = end
        }
        return ranges
    }

    func clear() {
        histories = [:]
        errors = [:]
        try? FileManager.default.removeItem(at: Self.directory)
    }

    // MARK: Disk cache

    private func loadCached(_ org: String) {
        guard histories[org] == nil,
              let data = try? Data(contentsOf: Self.fileURL(org)),
              let history = try? Self.decoder.decode(WorkLogHistory.self, from: data) else {
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

/// PRs fetched so far by each parallel search, summed for the progress bar.
private final class Tally {
    private var counts: [Int: Int] = [:]
    private let report: (Int, Int?) -> Void

    init(report: @escaping (Int, Int?) -> Void) {
        self.report = report
    }

    func set(_ index: Int, _ fetched: Int) {
        counts[index] = fetched
        report(counts.values.reduce(0, +), nil)
    }
}
