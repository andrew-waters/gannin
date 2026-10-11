import Foundation
import Observation

/// Issue history per org for the Issues page, persisted as JSON in
/// Application Support. Only fetched once the page has been opened.
@Observable
final class IssueStore {
    private static let overlap: TimeInterval = 5 * 60
    /// The most results GitHub returns for one search.
    private static let searchCap = 1000

    private(set) var histories: [String: IssueHistory] = [:]
    /// Orgs whose descriptions and comments are being fetched.
    private(set) var deepSyncing: Set<String> = []
    private(set) var syncing: Set<String> = []
    private(set) var errors: [String: String] = [:]
    private var earliest: [String: Date] = [:]

    private let auth: AuthStore
    private let activity: SyncActivity
    /// The account's outside repos (set by `GanninApp`, from
    /// `OrgConfigStore`'s root store, so the history is the same whichever
    /// project a window has), as `OrgStore.outsideRepos` is.
    @ObservationIgnored var outsideRepos: (_ org: String) -> Set<String> = { _ in [] }
    /// Which of them the workload snapshot has found unreadable (set by
    /// `GanninApp` from `OrgStore`'s own check), so this store doesn't run
    /// a second aliased readability query for the same repos.
    @ObservationIgnored var unreadableOutsideRepos: (_ org: String) -> [String: String] = { _ in [:] }

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

    /// One of `sync`'s searches: `repos` is the outside batch it covers,
    /// nil for the account's own scope (andrew-waters/gannin#205).
    struct IssueSearch: Equatable {
        enum Kind { case closed, changed, open }
        let kind: Kind
        let query: String
        let repos: Set<String>?
    }

    /// Backfills closed issues to the window's starting Monday a week at a
    /// time (in parallel), refetches open issues when due, and otherwise
    /// only fetches what changed. `refetchOpen` refetches every open issue
    /// now (Full Refresh) rather than when `.openIssues` is due.
    ///
    /// Outside repos (a project's own, `outsideRepos(org)`) join in as
    /// their own `repo:`-qualified searches, batched to stay under
    /// GitHub's query length: a brand new one gets the same full backfill
    /// as a brand new org, a known one trusts a changes search as the
    /// account's own repos do (andrew-waters/gannin#205).
    func sync(_ org: String, windowDays: Int, force: Bool = false, refetchOpen: Bool = false) async {
        loadCached(org)
        guard let api = auth.api, !syncing.contains(org), SyncSettings.isOn(.issues) else { return }
        let now = Date.now
        let start = MetricsStore.coverageStart(windowDays: windowDays, now: now)
        let history = histories[org]
        let scope = "\(GitHubAccounts.scope(org)) archived:false is:issue"

        let outside = outsideRepos(org)
        // The workload snapshot already runs the aliased readability query
        // for these repos (hourly, or on adding one); reading its answer
        // here avoids asking GitHub the same thing twice.
        let unreadable = unreadableOutsideRepos(org)
        let (searchableOutside, newOutside, knownOutside) = GitHubAPI.outsideRepoCohorts(
            outside, priorFetched: history?.outsideReposFetched ?? [], priorUnreadable: Set(unreadable.keys)
        )
        let newBatches = GitHubAPI.outsideRepoBatches(newOutside)
        let knownBatches = GitHubAPI.outsideRepoBatches(knownOutside)

        let changedSince: Date? = history.flatMap { auth.shouldFetch(.issues, since: $0.syncedAt, now: now, force: force) ? $0.syncedAt.addingTimeInterval(-Self.overlap) : nil }
        // Open issues in full every so often (see `openFetchedAt`).
        let openDue = history.map { auth.shouldFetch(.openIssues, since: $0.openFetchedAt, now: now, force: refetchOpen) } ?? true

        let searches = Self.plannedSearches(
            accountScope: scope, start: start, now: now, history: history,
            changedSince: changedSince, openDue: openDue, newBatches: newBatches, knownBatches: knownBatches
        )
        guard !searches.isEmpty else { return }

        syncing.insert(org)
        defer { syncing.remove(org) }
        let run = activity.begin(.issues, org: org)
        run.add("issues", title: "Issues", detail: searches.count == 1 ? "1 search" : "\(searches.count) searches")
        let keyed = Dictionary(uniqueKeysWithValues: searches.enumerated().map { ("s\($0.offset)", $0.element.query) })
        let counts = try? await run.overhead({ try await api.counts(searches: keyed) })
        if let counts { run.setTotal(counts.values.map { min($0, 1000) }.reduce(0, +), for: "issues") }

        do {
            let queries = searches.map(\.query)
            let records = try await run.track("issues", count: \.count) { progress in
                try await Self.fetch(queries, api: api, progress: progress)
            }

            var updated = history ?? IssueHistory(orgLogin: org, coveredFrom: start, syncedAt: now, openFetchedAt: now, issues: [:])
            let fetchedIDs = Set(records.map(\.id))
            // GitHub returns at most 1000 results per search, so past that
            // a refetch is a partial list; open issues missing from an
            // uncapped one were closed or moved away and are dropped,
            // scoped to the repos that search actually covers so a batch
            // not due this round doesn't lose its last known issues.
            for (index, entry) in searches.enumerated() where entry.kind == .open {
                let capped = Self.isCapped(count: counts?["s\(index)"], repoScoped: entry.repos != nil, totalRecords: records.count, cap: Self.searchCap)
                guard !capped else { continue }
                updated.issues = Self.pruneStaleOpenIssues(updated.issues, fetchedIDs: fetchedIDs, scope: entry.repos, outside: outside)
            }
            if searches.contains(where: { $0.kind == .open && $0.repos == nil }) {
                updated.openFetchedAt = now
            }
            for record in records { updated.issues[record.id] = record }
            updated.coveredFrom = min(updated.coveredFrom, start)
            updated.syncedAt = now
            // Every readable outside repo now has a full baseline: new ones
            // from this cycle's own full search, known ones carried over,
            // kept current by their own changes search.
            updated.outsideReposFetched = searchableOutside
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

    /// Every search `sync` needs to run, in order: the account's own
    /// (closed backfill, changes, a full open refetch) exactly as before
    /// outside repos existed, then known outside batches' own versions of
    /// the same, then new outside batches' full backfill and open search
    /// regardless of what's due, since they have no baseline to build on.
    /// With no outside repos, this is exactly today's search list (R7).
    static func plannedSearches(
        accountScope: String, start: Date, now: Date, history: IssueHistory?,
        changedSince: Date?, openDue: Bool, newBatches: [[String]], knownBatches: [[String]]
    ) -> [IssueSearch] {
        func batchScope(_ batch: [String]) -> String { "\(batch.map { "repo:\($0)" }.joined(separator: " ")) archived:false is:issue" }
        func closed(_ scope: String, repos: Set<String>?, from: Date, to: Date) -> [IssueSearch] {
            ParallelSearches.weeks(from: from, to: to).map { IssueSearch(kind: .closed, query: "\(scope) closed:\(stamp($0.0))..\(stamp($0.1))", repos: repos) }
        }

        var searches: [IssueSearch] = []
        if let history {
            if start < history.coveredFrom {
                searches += closed(accountScope, repos: nil, from: start, to: history.coveredFrom)
                for batch in knownBatches { searches += closed(batchScope(batch), repos: Set(batch), from: start, to: history.coveredFrom) }
            }
            if let changedSince {
                searches.append(IssueSearch(kind: .changed, query: "\(accountScope) updated:>=\(stamp(changedSince))", repos: nil))
                for batch in knownBatches {
                    searches.append(IssueSearch(kind: .changed, query: "\(batchScope(batch)) updated:>=\(stamp(changedSince))", repos: Set(batch)))
                }
            }
            if openDue {
                searches.append(IssueSearch(kind: .open, query: "\(accountScope) is:open", repos: nil))
                for batch in knownBatches { searches.append(IssueSearch(kind: .open, query: "\(batchScope(batch)) is:open", repos: Set(batch))) }
            }
        } else {
            searches += closed(accountScope, repos: nil, from: start, to: now)
            searches.append(IssueSearch(kind: .open, query: "\(accountScope) is:open", repos: nil))
        }
        // The history's own coverage may already reach further back than
        // this window's start (a longer window, or All time, asked for it
        // since); a new batch's first backfill has to match that, or its
        // repos would claim coverage the search never actually ran.
        let newBackfillFrom = history.map { min(start, $0.coveredFrom) } ?? start
        for batch in newBatches {
            searches += closed(batchScope(batch), repos: Set(batch), from: newBackfillFrom, to: now)
            searches.append(IssueSearch(kind: .open, query: "\(batchScope(batch)) is:open", repos: Set(batch)))
        }
        return searches
    }

    /// Whether an `is:open` search's result is GitHub's 1000-result cap
    /// rather than every open issue: `count` from the counts preflight when
    /// it succeeded, else a fallback. An outside batch with no count can't
    /// be checked against its own repos, so it's treated as capped rather
    /// than risking a wrongly dropped issue; the account's own search falls
    /// back to the whole round's record count, as it always has.
    static func isCapped(count: Int?, repoScoped: Bool, totalRecords: Int, cap: Int) -> Bool {
        if let count { return count > cap }
        return repoScoped ? true : totalRecords >= cap
    }

    /// Drops issues still marked open in `issues` whose repo this round's
    /// full `is:open` search covers (`scope`: a batch's repos, or nil for
    /// every repo but the outside ones) but didn't return, since search
    /// found them closed or moved away; `fetchedIDs` is every issue any of
    /// this round's searches returned, so one refetched as closed stays.
    static func pruneStaleOpenIssues(_ issues: [String: IssueRecord], fetchedIDs: Set<String>, scope repos: Set<String>?, outside: Set<String>) -> [String: IssueRecord] {
        issues.filter { element in
            guard element.value.isOpen else { return true }
            let inScope = repos.map { $0.contains(element.value.repo) } ?? !outside.contains(element.value.repo)
            return !inScope || fetchedIDs.contains(element.key)
        }
    }

    private static func fetch(_ queries: [String], api: GitHubAPI, progress: @escaping (Int, Int?) -> Void) async throws -> [IssueRecord] {
        try await ParallelSearches.run(count: queries.count, progress: progress) { index, fetched in
            try await api.issueRecords(query: queries[index]) { count, _ in fetched(count) }
        }
    }

    private static func stamp(_ date: Date) -> String {
        date.formatted(.iso8601).replacingOccurrences(of: "Z", with: "+00:00")
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
              let history = try? Self.decoder.decode(IssueHistory.self, from: data),
              history.version == IssueHistory.currentVersion else {
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

// MARK: - Deep sync

extension IssueStore {
    /// After the issues: their descriptions and last 20 comments, into the
    /// search index (`IssueTextIndex`). The first time, every issue in the
    /// history not yet indexed; after that, those updated since (a comment
    /// bumps an issue's `updatedAt`), found with one cheap search. Fifty
    /// issues a query; it stops when the budget runs low and carries on
    /// next time.
    /// Issues not yet indexed every time; the search for changed ones only
    /// once its interval (Settings › Sync) has passed since the last.
    func deepSync(_ org: String) async {
        guard let api = auth.api, let history = histories[org], !deepSyncing.contains(org), !auth.shouldWaitForBudget(),
              SyncSettings.isOn(.issueText) else { return }
        deepSyncing.insert(org)
        defer { deepSyncing.remove(org) }
        await chargingTo(.issueText) { await deepSync(org, history: history, api: api) }
    }

    private func deepSync(_ org: String, history: IssueHistory, api: GitHubAPI) async {
        let index = IssueTextIndex.shared
        let started = Date.now
        let indexed = await index.indexed(org: org)
        var ids = Set(history.issues.keys).subtracting(indexed)
        let last = await index.lastSync(org: org)
        let due = SyncSettings.isDue(.issueText, since: last, now: started)
        if let last, due {
            let since = Self.stamp(last.addingTimeInterval(-Self.overlap))
            // The account's own scope, then outside repos batched the same
            // way sync's searches are: without this, an outside issue's
            // text is only ever fetched once, the first time it's indexed,
            // and a later edit or comment never catches up.
            var scopes = ["\(GitHubAccounts.scope(org)) archived:false is:issue"]
            scopes += GitHubAPI.outsideRepoBatches(outsideRepos(org)).map { batch in
                "\(batch.map { "repo:\($0)" }.joined(separator: " ")) archived:false is:issue"
            }
            for scope in scopes {
                if let changed: [Lossy<ChangedIssue>] = try? await api.search("\(scope) updated:>=\(since)", fields: "... on Issue { id }") {
                    ids.formUnion(changed.compactMap { $0.value?.id }.filter { history.issues[$0] != nil })
                }
            }
        }
        guard !ids.isEmpty else {
            if due { await index.setLastSync(org: org, started) }
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
            if finished.complete && due { await index.setLastSync(org: org, started) }
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
