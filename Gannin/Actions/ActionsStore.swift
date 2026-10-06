import Foundation
import Observation

/// GitHub Actions runs per org, backfilled to the Monday before twice the
/// window (so each number can be compared with the period before) and
/// topped up on each sync, persisted as JSON in Application Support. Only
/// fetched once the Actions page has been opened for an org; jobs are
/// fetched when a workflow is opened.
@Observable
final class ActionsStore {
    /// Top-ups reach back this far, for re-runs and runs that were still
    /// going at the last sync.
    private static let overlap: TimeInterval = 24 * 60 * 60
    /// Repos pushed to this long before the window are still checked, since
    /// scheduled workflows run without pushes (GitHub turns them off after 60
    /// quiet days).
    private static let quietReach: TimeInterval = 60 * 24 * 60 * 60
    /// Runs older than this are dropped from the cache: two of the longest
    /// window, and a little over.
    private static let keptDays = 190
    /// Settings: the most runs per workflow whose jobs are fetched when
    /// it's opened; 0 means every run in the window.
    static let jobRunLimitKey = "actionsJobRunLimit"
    static let jobRunLimitOptions = [0, 500, 200, 100, 50, 20]
    /// Jobs are fetched and saved this many runs at a time, so progress
    /// shows and survives leaving the page.
    private static let jobBatch = 40
    /// A job fetch stops when the REST budget gets this low, leaving the
    /// rest for after the reset.
    private static let jobBudgetFloor = 300
    /// Requests at once, to stay clear of GitHub's secondary rate limits.
    private static let concurrency = 4

    private(set) var histories: [String: ActionsHistory] = [:]
    private(set) var syncing: Set<String> = []
    private(set) var errors: [String: String] = [:]
    /// Workflow keys whose jobs are being fetched.
    private(set) var loadingJobs: Set<String> = []
    /// Runs done and to do, per key being fetched.
    private(set) var jobProgress: [String: (done: Int, of: Int)] = [:]
    /// Why a workflow's jobs stopped short (the REST budget), by key.
    private(set) var jobNotices: [String: String] = [:]

    /// The runs whose jobs are fetched for a workflow, from Settings.
    static var jobRunLimit: Int { UserDefaults.standard.integer(forKey: jobRunLimitKey) }

    /// The start of the stored range: the previous period's start, so both
    /// it and the window are complete.
    static func coverageStart(windowDays: Int, now: Date = .now) -> Date {
        MetricsStore.coverageStart(windowDays: windowDays * 2, now: now)
    }

    private let auth: AuthStore
    private let activity: SyncActivity

    init(auth: AuthStore, activity: SyncActivity) {
        self.auth = auth
        self.activity = activity
    }

    func history(for org: String) -> ActionsHistory? { histories[org] }

    /// Whether this org's runs have been loaded, so Refresh includes them.
    func isTracking(_ org: String) -> Bool { histories[org] != nil }

    /// Brings the org's runs up to date for the window. Each repo is
    /// backfilled to the window's start and topped up since its last sync.
    /// `excluding` repos aren't fetched.
    func sync(_ org: String, windowDays: Int, excluding excluded: Set<String> = [], force: Bool = false) async {
        loadCached(org)
        guard let api = auth.api, !syncing.contains(org), SyncSettings.isOn(.actions) else { return }

        let now = Date.now
        let start = Self.coverageStart(windowDays: windowDays, now: now)
        var history = histories[org] ?? ActionsHistory(
            version: ActionsHistory.currentVersion,
            orgLogin: org,
            syncedAt: .distantPast,
            repositories: [:],
            runs: [:],
            jobs: [:],
            jobsAttempt: [:]
        )
        let isFresh = !SyncSettings.isDue(.actions, since: history.syncedAt, now: now)
        let covered = history.repositories.values.allSatisfy { $0.coveredFrom <= start }
        if !force && isFresh && covered && !history.repositories.isEmpty { return }
        // Wait out a low budget unless asked, as long as there's history to show.
        if !force && (auth.shouldHoldOffREST || auth.shouldHoldOff) && histories[org] != nil { return }

        syncing.insert(org)
        defer { syncing.remove(org) }
        let run = activity.begin(.actions, org: org)
        run.add("repos", title: "Repositories")
        run.add("runs", title: "Workflow runs", detail: "Created since \(start.formatted(date: .abbreviated, time: .omitted)), the window and the one before")

        do {
            let listed = try await run.track("repos", count: \.count) { _ in
                try await api.actionsRepositories(org: org, pushedSince: start.addingTimeInterval(-Self.quietReach))
            }
            .filter { !excluded.contains($0.name) }

            // What each repo still needs: older weeks when the window has
            // grown, and what's changed since its last sync.
            var plans: [(repo: ActionsRepository, ranges: [(Date, Date)])] = []
            for var repo in listed {
                let stored = history.repositories[repo.name]
                repo.coveredFrom = stored?.coveredFrom ?? .distantFuture
                repo.syncedAt = stored?.syncedAt ?? .distantPast
                var ranges: [(Date, Date)] = []
                if let stored, stored.coveredFrom < .distantFuture {
                    if start < stored.coveredFrom { ranges.append((start, stored.coveredFrom)) }
                    let unfinished = history.runs.values
                        .filter { $0.repo == repo.name && !$0.isCompleted }
                        .map(\.createdAt)
                        .min()
                    let topUp = min(stored.syncedAt.addingTimeInterval(-Self.overlap), unfinished ?? .distantFuture)
                    ranges.append((max(topUp, start), now))
                } else {
                    ranges.append((start, now))
                }
                plans.append((repo, ranges))
            }

            let results = try await run.track("runs", count: { $0.reduce(0) { $0 + $1.runs.count } }) { progress in
                try await Self.fetch(plans, api: api, auth: auth, onProgress: { done, fetched in
                    run.setParts(done, of: plans.count, for: "runs")
                    progress(fetched, nil)
                })
            }

            for result in results {
                for workflowRun in result.runs { history.runs[workflowRun.id] = workflowRun }
                var repo = result.repo
                repo.coveredFrom = min(repo.coveredFrom, start)
                repo.syncedAt = now
                history.repositories[repo.name] = repo
            }
            prune(&history, now: now)
            history.syncedAt = now
            histories[org] = history
            errors[org] = nil
            save(history)
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

    private struct RepoResult {
        let repo: ActionsRepository
        let runs: [WorkflowRun]
    }

    /// Fetches each repo's ranges, several repos at once. `onProgress` gets
    /// repos done and runs fetched so far.
    private static func fetch(
        _ plans: [(repo: ActionsRepository, ranges: [(Date, Date)])],
        api: GitHubAPI,
        auth: AuthStore,
        onProgress: @escaping (Int, Int) -> Void
    ) async throws -> [RepoResult] {
        var fetched: [Int: Int] = [:]
        var done = 0
        func task(_ index: Int) -> @MainActor @Sendable () async throws -> RepoResult {
            let plan = plans[index]
            return {
                var runs: [WorkflowRun] = []
                do {
                    for (from, to) in plan.ranges where from < to {
                        let before = runs.count
                        runs += try await api.workflowRuns(repo: plan.repo.name, from: from, to: to) { count in
                            fetched[index] = before + count
                            onProgress(done, fetched.values.reduce(0, +))
                        }
                    }
                } catch APIError.http(let status, let body) where Self.isUnavailable(status: status, body: body, auth: auth) {
                    // Actions turned off, or the repo hidden from this token:
                    // nothing to show, and not worth failing the sync for.
                    runs = []
                }
                return RepoResult(repo: plan.repo, runs: runs)
            }
        }
        return try await withThrowingTaskGroup(of: RepoResult.self) { group in
            var next = 0
            while next < min(concurrency, plans.count) {
                group.addTask(operation: task(next))
                next += 1
            }
            var results: [RepoResult] = []
            while let result = try await group.next() {
                results.append(result)
                done += 1
                onProgress(done, fetched.values.reduce(0, +))
                if next < plans.count {
                    group.addTask(operation: task(next))
                    next += 1
                }
            }
            return results
        }
    }

    /// A repo whose runs can't be read, as opposed to a budget running out.
    private static func isUnavailable(status: Int, body: String, auth: AuthStore) -> Bool {
        switch status {
        case 404, 410, 451: return true
        case 403: return !body.localizedCaseInsensitiveContains("rate limit") && (auth.restRateLimit?.remaining ?? 1) > 0
        default: return false
        }
    }

    private func prune(_ history: inout ActionsHistory, now: Date) {
        let cutoff = Calendar.metrics.date(byAdding: .day, value: -Self.keptDays, to: now) ?? now
        let old = history.runs.values.filter { $0.createdAt < cutoff }.map(\.id)
        for id in old {
            history.runs[id] = nil
            history.jobs[id] = nil
            history.jobsAttempt[id] = nil
        }
        for name in history.repositories.keys {
            if let from = history.repositories[name]?.coveredFrom, from < cutoff {
                history.repositories[name]?.coveredFrom = cutoff
            }
        }
    }

    // MARK: Jobs

    /// Fetches jobs for the workflow's completed runs in the window that
    /// don't have them yet, or were re-run since: all of them, or the most
    /// recent up to the limit in Settings.
    func loadJobs(org: String, workflowKey: String, since windowStart: Date) async {
        guard let history = histories[org] else { return }
        var runs = history.runs.values
            .filter { $0.workflowKey == workflowKey && $0.isCompleted && $0.outcome != .skipped && $0.createdAt >= windowStart }
            .sorted { $0.createdAt > $1.createdAt }
        let limit = Self.jobRunLimit
        if limit > 0 { runs = Array(runs.prefix(limit)) }
        await chargingTo(.actions) { await loadJobs(org: org, runs: runs, key: workflowKey) }
    }

    /// Fetches one run's jobs, when it hasn't got them for its latest
    /// attempt or is still going.
    func loadJobs(org: String, run: WorkflowRun) async {
        await chargingTo(.actions) { await loadJobs(org: org, runs: [run], key: Self.jobsKey(run)) }
    }

    static func jobsKey(_ run: WorkflowRun) -> String { "run-\(run.id)" }

    private func loadJobs(org: String, runs: [WorkflowRun], key: String) async {
        guard let api = auth.api, let stored = histories[org], !loadingJobs.contains(key), SyncSettings.isOn(.actions) else { return }
        // A finished run's jobs never change until it's re-run.
        let pending = runs.filter { !$0.isCompleted || stored.jobsAttempt[$0.id] != $0.attempt }
        guard !pending.isEmpty else { return }

        loadingJobs.insert(key)
        jobNotices[key] = nil
        jobProgress[key] = (0, pending.count)
        var done = 0
        var unsaved = 0
        defer {
            loadingJobs.remove(key)
            jobProgress[key] = nil
            // Whatever's fetched is kept, finished or not.
            if unsaved > 0, let history = histories[org] { save(history) }
        }
        do {
            for start in stride(from: 0, to: pending.count, by: Self.jobBatch) {
                if let budget = auth.restRateLimit, (budget.remaining < Self.jobBudgetFloor), (budget.resetAt > .now) {
                    jobNotices[key] = "Stopped at \(done) of \(pending.count) runs to save the GitHub API budget; the rest are fetched after it resets at \(budget.resetAt.formatted(date: .omitted, time: .shortened))."
                    break
                }
                let batch = Array(pending[start..<min(start + Self.jobBatch, pending.count)])
                let fetched = try await Self.fetchJobs(batch, api: api)
                // The store may have synced meanwhile; merge onto the latest.
                guard var history = histories[org] else { return }
                for (run, jobs) in fetched {
                    history.jobs[run.id] = jobs
                    if run.isCompleted { history.jobsAttempt[run.id] = run.attempt }
                }
                histories[org] = history
                done += batch.count
                unsaved += batch.count
                jobProgress[key] = (done, pending.count)
                // A big history is slow to write, so every few batches.
                if unsaved >= Self.jobBatch * 5 {
                    save(history)
                    unsaved = 0
                }
            }
        } catch is CancellationError {
            // Left the page; what's fetched so far is saved.
        } catch APIError.unauthorized {
            auth.signOut()
        } catch {
            errors[org] = error.localizedDescription
        }
    }

    /// One batch of runs' jobs, several at once.
    private static func fetchJobs(_ runs: [WorkflowRun], api: GitHubAPI) async throws -> [(WorkflowRun, [WorkflowJob])] {
        try await withThrowingTaskGroup(of: (WorkflowRun, [WorkflowJob]).self) { group in
            var next = 0
            func add() {
                let run = runs[next]
                group.addTask { (run, try await api.workflowJobs(repo: run.repo, runID: run.id)) }
                next += 1
            }
            while next < min(concurrency, runs.count) { add() }
            var results: [(WorkflowRun, [WorkflowJob])] = []
            while let result = try await group.next() {
                results.append(result)
                if next < runs.count { add() }
            }
            return results
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
              let history = try? Self.decoder.decode(ActionsHistory.self, from: data),
              history.version == ActionsHistory.currentVersion else {
            return
        }
        histories[org] = history
    }

    private func save(_ history: ActionsHistory) {
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
        URL.applicationSupportDirectory.appending(path: "Actions", directoryHint: .isDirectory)
    }

    private static func fileURL(_ org: String) -> URL {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "\(org).json")
    }
}
