import Foundation
import Observation

/// Merged-PR history per org, backfilled to the metrics window and topped
/// up incrementally, persisted as JSON in Application Support.
@Observable
final class MetricsStore {
    static let windowKey = "metricsWindowDays"
    static let defaultWindowDays = 30
    static let windowOptions = [7, 14, 30, 90]

    private(set) var histories: [String: MetricsHistory] = [:]
    private(set) var syncing: Set<String> = []
    private(set) var errors: [String: String] = [:]

    private let auth: AuthStore
    private let activity: SyncActivity
    private let pullRequestStore: PullRequestStore
    private let cache: OrgJSONCache

    init(auth: AuthStore, activity: SyncActivity, pullRequestStore: PullRequestStore = .shared, cache: OrgJSONCache = MetricsStore.defaultCache) {
        self.auth = auth
        self.activity = activity
        self.pullRequestStore = pullRequestStore
        self.cache = cache
    }

    func history(for org: String) -> MetricsHistory? { histories[org] }

    /// Start of the stored range for a window: the Monday on or before
    /// `now - windowDays`, so every weekly bucket in view is complete.
    static func coverageStart(windowDays: Int, now: Date = .now) -> Date {
        let windowStart = Calendar.metrics.date(byAdding: .day, value: -windowDays, to: now) ?? now
        return Calendar.metrics.startOfWeek(for: windowStart)
    }

    func sync(_ org: String, windowDays: Int, force: Bool = false) async {
        loadCached(org)
        guard let api = auth.api, !syncing.contains(org), SyncSettings.isOn(.metrics) else { return }

        let now = Date.now
        let start = Self.coverageStart(windowDays: windowDays, now: now)
        var history = histories[org] ?? MetricsHistory(
            formatVersion: MetricsHistory.currentFormat,
            orgLogin: org,
            coveredFrom: now,
            syncedAt: .distantPast,
            pullRequests: [:],
            openedPerWeek: [:]
        )
        let isFresh = !SyncSettings.isDue(.metrics, since: history.syncedAt, now: now)
        let lackingFiles = history.lackingChangedFiles
        if !force && isFresh && history.coveredFrom <= start && lackingFiles.isEmpty { return }
        // Wait out a low rate limit unless asked, as long as there's history to show.
        if auth.shouldWaitForBudget(force: force, hasData: histories[org] != nil) { return }

        // Backfill anything older than we hold, then top up since the last
        // sync with a day of overlap, a week per search.
        let backfill = history.coveredFrom > start ? GitHubAPI.weeklyChunks(from: start, to: history.coveredFrom) : []
        // The first top-up search starts at `topUpSince` itself, not its day.
        let topUpSince = history.syncedAt.addingTimeInterval(-24 * 60 * 60)
        let topUp = history.syncedAt != .distantPast ? GitHubAPI.weeklyChunks(from: topUpSince, to: now) : []
        // Opened counts are cheap: fetch missing weeks and refresh the last
        // two, which may still be changing.
        let recent = Calendar.metrics.date(byAdding: .day, value: -7, to: Calendar.metrics.startOfWeek(for: now)) ?? now
        let weeks = Self.weeks(from: start, to: now).filter { history.openedPerWeek[$0] == nil || $0 >= recent }

        let run = activity.begin(.metrics, org: org)
        let chunks = backfill + topUp
        if !chunks.isEmpty {
            run.add("merged", title: "Merged PRs", detail: Self.mergedDetail(backfill: backfill.count, topUp: topUp.count))
        }
        if !weeks.isEmpty {
            run.add("opened", title: "Opened per week", detail: weeks.count == 1 ? "1 week" : "\(weeks.count) weeks")
            run.setTotal(weeks.count, for: "opened")
        }
        if !lackingFiles.isEmpty {
            run.add("files", title: "Files changed", detail: "PRs stored before it was fetched")
            run.setTotal(lackingFiles.count, for: "files")
        }

        syncing.insert(org)
        defer { syncing.remove(org) }

        // How many merged PRs the weeks hold, in one cheap request, so
        // progress is by PRs rather than weeks. Progress only, so a failure
        // is ignored.
        var searches: [String: String] = [:]
        if let first = backfill.first, let last = backfill.last {
            searches["backfill"] = GitHubAPI.mergedSearch(org: org, from: first.0, to: last.1)
        }
        if let first = topUp.first, let last = topUp.last {
            searches["topUp"] = GitHubAPI.mergedSearch(org: org, from: first.0, to: last.1, since: topUpSince)
        }
        if !searches.isEmpty, let counts = try? await run.overhead({ try await api.counts(searches: searches) }) {
            run.setTotal(counts.values.reduce(0, +), for: "merged")
        }

        // PRs fetched since the last save, so a save writes only those to the store.
        var unsaved: [String: MetricPullRequest] = [:]
        func saveHistory() {
            save(history, merging: Array(unsaved.values))
            unsaved = [:]
        }
        do {
            if !chunks.isEmpty {
                // Newest first, the history reaching back a week at a time
                // and saved every few, so a long backfill (all time) shows
                // as it goes and keeps what it got if it stops.
                let ordered = topUp + backfill.reversed()
                _ = try await run.track("merged", count: { $0 }) { progress in
                    var fetched = 0
                    for (index, (from, to)) in ordered.enumerated() {
                        run.setParts(index, of: ordered.count, for: "merged")
                        let before = fetched
                        let since = index == 0 && !topUp.isEmpty ? topUpSince : nil
                        let prs = try await api.metricPullRequests(org: org, from: from, to: to, since: since) { page, _ in
                            progress(before + page, nil)
                        }
                        fetched += prs.count
                        for pr in prs {
                            history.pullRequests[pr.id] = pr
                            unsaved[pr.id] = pr
                        }
                        if index >= topUp.count {
                            history.coveredFrom = min(history.coveredFrom, from)
                            if (index - topUp.count) % 8 == 7 {
                                histories[org] = history
                                saveHistory()
                            }
                        }
                    }
                    return fetched
                }
                if !backfill.isEmpty { history.coveredFrom = min(history.coveredFrom, start) }
            }
            if !weeks.isEmpty {
                let counts = try await run.track("opened", count: \.count) { progress in
                    try await api.openedCounts(org: org, weeks: weeks) { progress($0, weeks.count) }
                }
                for (week, count) in counts { history.openedPerWeek[week] = count }
            }
            if !lackingFiles.isEmpty {
                // Saved as it goes, so a sync that stops carries on from
                // there next time.
                var batches = 0
                _ = try await run.track("files", count: { $0 }) { progress in
                    try await api.changedFiles(ids: lackingFiles) { files, done in
                        for (id, count) in files {
                            history.pullRequests[id]?.changedFiles = count
                            unsaved[id] = history.pullRequests[id]
                        }
                        progress(done, lackingFiles.count)
                        batches += 1
                        if batches % 20 == 0 {
                            histories[org] = history
                            saveHistory()
                        }
                    }
                    return lackingFiles.count
                }
                history.filledChangedFiles = true
            }

            history.syncedAt = now
            histories[org] = history
            errors[org] = nil
            saveHistory()
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

    private static func mergedDetail(backfill: Int, topUp: Int) -> String {
        func weeks(_ count: Int) -> String { count == 1 ? "1 week" : "\(count) weeks" }
        var parts: [String] = []
        if backfill > 0 { parts.append("\(weeks(backfill)) of history") }
        if topUp > 0 { parts.append("\(weeks(topUp)) since the last sync") }
        return parts.joined(separator: ", ")
    }

    static func weeks(from start: Date, to end: Date) -> [Date] {
        var weeks: [Date] = []
        var week = Calendar.metrics.startOfWeek(for: start)
        while week <= end {
            weeks.append(week)
            guard let next = Calendar.metrics.date(byAdding: .day, value: 7, to: week) else { break }
            week = next
        }
        return weeks
    }

    static var cacheDirectory: URL { defaultCache.directory }

    /// Also removes the metrics' part of every stored PR: the history is
    /// rebuilt from it, so a history kept after its PRs are gone would claim
    /// a coverage it no longer has.
    func clear() {
        histories = [:]
        errors = [:]
        activity.clear()
        cache.clear()
        pullRequestStore.clear(.metrics)
    }

    // MARK: Disk cache

    static let defaultCache = OrgJSONCache(folder: "Metrics")

    func loadCached(_ org: String) {
        guard histories[org] == nil else { return }
        // A history from before PRs were kept in the shared store brings its
        // PRs along, so the upgrade doesn't fetch them again.
        if let legacy = cache.load(MetricsHistory.Legacy.self, org: org), legacy.formatVersion == MetricsHistory.Legacy.format,
           var history = cache.load(MetricsHistory.self, org: org) {
            pullRequestStore.merge(legacy.pullRequests.values.map { StoredPullRequest(metrics: $0) }, org: org)
            history.formatVersion = MetricsHistory.currentFormat
            history.pullRequests = legacy.pullRequests
            save(history, merging: [])
            histories[org] = history
            return
        }
        guard var history = cache.load(MetricsHistory.self, org: org),
              history.formatVersion == MetricsHistory.currentFormat else {
            return
        }
        history.pullRequests = Dictionary(uniqueKeysWithValues: pullRequestStore.pullRequests(org: org).values.compactMap { stored in
            stored.metricPullRequest.map { ($0.id, $0) }
        })
        guard history.pullRequests.count >= (history.storedCount ?? 0) else { return }
        histories[org] = history
    }

    /// The PRs go to the store first: a history saved without them would
    /// claim a coverage the store doesn't have.
    private func save(_ history: MetricsHistory, merging fetched: [MetricPullRequest]) {
        pullRequestStore.merge(fetched.map { StoredPullRequest(metrics: $0) }, org: history.orgLogin)
        var saved = history
        saved.storedCount = history.pullRequests.count
        cache.save(saved, org: history.orgLogin)
    }
}
