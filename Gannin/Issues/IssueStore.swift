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
    /// Orgs whose descriptions and comments are being fetched.
    private(set) var deepSyncing: Set<String> = []
    private(set) var syncing: Set<String> = []
    private(set) var errors: [String: String] = [:]
    private var earliest: [String: Date] = [:]

    private let auth: AuthStore
    private let activity: SyncActivity

    init(auth: AuthStore, activity: SyncActivity) {
        self.auth = auth
        self.activity = activity
    }

    func history(for org: String) -> IssueHistory? { histories[org] }

    /// When the org's first issue was opened, for All time; kept once found.
    func earliestIssue(_ org: String) -> Date? {
        if let known = earliest[org] { return known }
        let stored = UserDefaults.standard.double(forKey: "earliestIssue.\(org)")
        return stored > 0 ? Date(timeIntervalSince1970: stored) : nil
    }

    func loadEarliestIssue(_ org: String) async {
        guard earliestIssue(org) == nil, let api = auth.api,
              let date = try? await api.earliestIssue(org: org) else { return }
        earliest[org] = date
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: "earliestIssue.\(org)")
    }

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
        let scope = "\(GitHubAccounts.scope(org)) archived:false is:issue"

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
            // Then, in the background, their descriptions and comments.
            Task { await self.deepSync(org) }
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

    /// Labels written from the app, shown before the next fetch.
    func recordLabels(org: String, issueID: String, labels: [String]) {
        guard var history = histories[org], history.issues[issueID] != nil else { return }
        history.issues[issueID]?.labels = labels
        histories[org] = history
        save(history)
    }

    /// An issue added to a board from the app, shown before the next fetch.
    func recordAddedToBoard(org: String, issueID: String, projectNumber: Int, projectTitle: String) {
        guard var history = histories[org], var record = history.issues[issueID],
              record.fields(onProject: projectNumber) == nil else { return }
        record.projectFields.append(IssueProjectFields(projectNumber: projectNumber, projectTitle: projectTitle, values: [:]))
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

    /// Changes every stored issue's values on one board at once, after the
    /// board's fields change (a rename, an option renamed or removed).
    func rewriteFieldValues(org: String, projectNumber: Int, _ change: (inout [String: IssueFieldValue]) -> Void) {
        guard var history = histories[org] else { return }
        for (id, var record) in history.issues {
            guard let index = record.projectFields.firstIndex(where: { $0.projectNumber == projectNumber }) else { continue }
            change(&record.projectFields[index].values)
            history.issues[id] = record
        }
        histories[org] = history
        save(history)
    }

    static var cacheDirectory: URL { directory }

    func clear() {
        histories = [:]
        errors = [:]
        try? FileManager.default.removeItem(at: Self.directory)
    }

    // MARK: Disk cache

    /// Pulls the history saved by a previous launch into memory.
    func loadCached(_ org: String) {
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

// MARK: - Deep sync

extension IssueStore {
    /// After the issues: their descriptions and last 20 comments, into the
    /// search index (`IssueTextIndex`). The first time, every issue in the
    /// history not yet indexed; after that, those updated since (a comment
    /// bumps an issue's `updatedAt`), found with one cheap search. Fifty
    /// issues a query; it stops when the budget runs low and carries on
    /// next time.
    func deepSync(_ org: String) async {
        guard let api = auth.api, let history = histories[org], !deepSyncing.contains(org), !auth.shouldHoldOff else { return }
        deepSyncing.insert(org)
        defer { deepSyncing.remove(org) }
        let index = IssueTextIndex.shared
        let started = Date.now
        let indexed = await index.indexed(org: org)
        var ids = Set(history.issues.keys).subtracting(indexed)
        if let last = await index.lastSync(org: org) {
            let since = Self.stamp(last.addingTimeInterval(-Self.overlap))
            if let changed: [Lossy<ChangedIssue>] = try? await api.search("\(GitHubAccounts.scope(org)) archived:false is:issue updated:>=\(since)", fields: "... on Issue { id }") {
                ids.formUnion(changed.compactMap { $0.value?.id }.filter { history.issues[$0] != nil })
            }
        }
        guard !ids.isEmpty else {
            await index.setLastSync(org: org, started)
            return
        }
        let run = activity.begin(.issueText, org: org)
        run.add("text", title: "Descriptions and comments", detail: ids.count == 1 ? "1 issue" : "\(ids.count) issues")
        run.setTotal(ids.count, for: "text")
        let all = Array(ids)
        do {
            let finished = try await run.track("text", count: { $0.done }) { progress in
                var done = 0
                for start in stride(from: 0, to: all.count, by: 50) {
                    try Task.checkCancellation()
                    if auth.rateLimit?.isLow == true { return (done: done, complete: false) }
                    let batch = Array(all[start..<min(start + 50, all.count)])
                    let texts = try await api.issueTexts(ids: batch)
                    let rows = texts.compactMap { text -> IssueText? in
                        guard let record = history.issues[text.id] else { return nil }
                        return IssueText(id: text.id, org: org, repo: record.repo, number: record.number, title: record.title,
                                         body: text.body, comments: text.comments, updatedAt: text.updatedAt)
                    }
                    await index.upsert(rows)
                    done += batch.count
                    progress(done, all.count)
                }
                return (done: done, complete: true)
            }
            // Only once everything changed is in, else the next run would
            // skip what this one didn't get to.
            if finished.complete { await index.setLastSync(org: org, started) }
            run.finish()
        } catch {
            run.finish(error: error)
        }
    }
}

private struct ChangedIssue: Decodable { let id: String }

extension GitHubAPI {
    /// Issues' descriptions and last 20 comments, by node ID.
    func issueTexts(ids: [String]) async throws -> [(id: String, body: String, comments: String, updatedAt: Date)] {
        struct Comment: Decodable {
            struct Author: Decodable { let login: String }
            let author: Author?
            let body: String
        }
        struct Node: Decodable {
            let id: String
            let updatedAt: Date
            let body: String
            let comments: Connection<Comment>
        }
        struct Response: Decodable { let nodes: [Lossy<Node>] }
        let response: Response = try await query("""
            query($ids: [ID!]!) {
              nodes(ids: $ids) { ... on Issue { id updatedAt body comments(last: 20) { nodes { author { login } body } } } }
            }
            """, values: ["ids": ids])
        return response.nodes.compactMap(\.value).map { node in
            (node.id, node.body, node.comments.nodes.map { "@\($0.author?.login ?? "someone"): \($0.body)" }.joined(separator: "\n\n"), node.updatedAt)
        }
    }
}
