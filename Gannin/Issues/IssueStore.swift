import Foundation
import Observation

/// Issue history per org for the Issues page, persisted as JSON in
/// Application Support. Only fetched once the page has been opened.
@Observable
final class IssueStore {
    private static let maxAge: TimeInterval = 10 * 60
    /// Open issues are refetched in full this often (see `openFetchedAt`).
    private static let openMaxAge: TimeInterval = 60 * 60
    private static let overlap: TimeInterval = 5 * 60
    private static let concurrency = 4

    private(set) var histories: [String: IssueHistory] = [:]
    private(set) var syncing: Set<String> = []
    private(set) var errors: [String: String] = [:]

    private let auth: AuthStore
    private let activity: SyncActivity

    init(auth: AuthStore, activity: SyncActivity) {
        self.auth = auth
        self.activity = activity
    }

    func history(for org: String) -> IssueHistory? { histories[org] }

    func isTracking(_ org: String) -> Bool { histories[org] != nil }

    /// Backfills closed issues to the window's starting Monday a week at a
    /// time (in parallel), refetches open issues when due, and otherwise
    /// only fetches what changed.
    func sync(_ org: String, windowDays: Int, force: Bool = false) async {
        loadCached(org)
        guard let api = auth.api, !syncing.contains(org) else { return }
        let now = Date.now
        let start = MetricsStore.coverageStart(windowDays: windowDays, now: now)
        let history = histories[org]
        let scope = "org:\(org) archived:false is:issue"

        var searches: [(key: String, query: String)] = []
        if let history {
            if start < history.coveredFrom {
                searches += Self.weeks(from: start, to: history.coveredFrom).map { ("closed", "\(scope) closed:\(Self.stamp($0.0))..\(Self.stamp($0.1))") }
            }
            let due = now.timeIntervalSince(history.syncedAt) >= Self.maxAge
            if force || (due && !auth.shouldHoldOff) {
                searches.append(("changed", "\(scope) updated:>=\(Self.stamp(history.syncedAt.addingTimeInterval(-Self.overlap)))"))
            }
            if force || now.timeIntervalSince(history.openFetchedAt) >= Self.openMaxAge {
                searches.append(("open", "\(scope) is:open"))
            }
        } else {
            searches += Self.weeks(from: start, to: now).map { ("closed", "\(scope) closed:\(Self.stamp($0.0))..\(Self.stamp($0.1))") }
            searches.append(("open", "\(scope) is:open"))
        }
        guard !searches.isEmpty else { return }

        syncing.insert(org)
        defer { syncing.remove(org) }
        let run = activity.begin(.issues, org: org)
        run.add("issues", title: "Issues", detail: searches.count == 1 ? "1 search" : "\(searches.count) searches")
        let keyed = Dictionary(uniqueKeysWithValues: searches.enumerated().map { ("s\($0.offset)", $0.element.query) })
        if let counts = try? await run.overhead({ try await api.counts(searches: keyed) }) {
            run.setTotal(counts.values.map { min($0, 1000) }.reduce(0, +), for: "issues")
        }
        do {
            let queries = searches.map(\.query)
            let records = try await run.track("issues", count: \.count) { progress in
                try await Self.fetch(queries, api: api, progress: progress)
            }
            let refetchedOpen = searches.contains { $0.key == "open" }
            var updated = history ?? IssueHistory(orgLogin: org, coveredFrom: start, syncedAt: now, openFetchedAt: now, issues: [:])
            if refetchedOpen {
                // Open issues missing from a full refetch were closed or moved
                // away; drop them unless they were refetched as closed.
                let fetched = Set(records.map(\.id))
                updated.issues = updated.issues.filter { !$0.value.isOpen || fetched.contains($0.key) }
                updated.openFetchedAt = now
            }
            for record in records { updated.issues[record.id] = record }
            updated.coveredFrom = min(updated.coveredFrom, start)
            updated.syncedAt = now
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

    private static func fetch(_ queries: [String], api: GitHubAPI, progress: @escaping (Int, Int?) -> Void) async throws -> [IssueRecord] {
        let tally = IssueTally(report: progress)
        func task(_ index: Int) -> @MainActor @Sendable () async throws -> [IssueRecord] {
            let query = queries[index]
            return { try await api.issueRecords(query: query) { fetched, _ in tally.set(index, fetched) } }
        }
        return try await withThrowingTaskGroup(of: [IssueRecord].self) { group in
            var next = 0
            while next < min(concurrency, queries.count) {
                group.addTask(operation: task(next))
                next += 1
            }
            var results: [IssueRecord] = []
            while let batch = try await group.next() {
                results += batch
                if next < queries.count {
                    group.addTask(operation: task(next))
                    next += 1
                }
            }
            return results
        }
    }

    private static func stamp(_ date: Date) -> String {
        date.formatted(.iso8601).replacingOccurrences(of: "Z", with: "+00:00")
    }

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

    /// Records a status change saved from the app, so metrics move at once
    /// rather than at the next open-issue fetch, which confirms it.
    func recordStatusChange(org: String, issueID: String, status: String, projectNumber: Int?, projectTitle: String?) {
        guard var history = histories[org], var record = history.issues[issueID] else { return }
        record.statusChanges.append(IssueStatusChange(at: .now, status: status, projectNumber: projectNumber, projectTitle: projectTitle))
        history.issues[issueID] = record
        histories[org] = history
        save(history)
    }

    /// Records a board field saved from the app (nil clears it), so ordering
    /// by that field updates at once.
    func recordFieldValue(org: String, issueID: String, projectNumber: Int, projectTitle: String, field: String, value: IssueFieldValue?) {
        guard var history = histories[org], var record = history.issues[issueID] else { return }
        if let index = record.projectFields.firstIndex(where: { $0.projectNumber == projectNumber }) {
            record.projectFields[index].values[field] = value
        } else {
            record.projectFields.append(IssueProjectFields(projectNumber: projectNumber, projectTitle: projectTitle, values: value.map { [field: $0] } ?? [:]))
        }
        history.issues[issueID] = record
        histories[org] = history
        save(history)
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
              let history = try? Self.decoder.decode(IssueHistory.self, from: data) else {
            return
        }
        histories[org] = history
    }

    private func save(_ history: IssueHistory) {
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
        URL.applicationSupportDirectory.appending(path: "Issues", directoryHint: .isDirectory)
    }

    private static func fileURL(_ org: String) -> URL {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "\(org).json")
    }
}

/// Issues fetched so far by each parallel search, summed for progress.
private final class IssueTally {
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
