import Foundation
import Observation

/// Each org's milestones and GitHub Releases (every release of each repo,
/// with its assets' downloads, and the stars of repos with releases),
/// persisted as JSON in Application Support and fetched again after its
/// interval (Settings › Sync). Only fetched once the Releases page has been opened for an org;
/// Refresh includes it from then on. Each sync records the day's download
/// totals (`DownloadHistory`), kept apart from the cache.
@Observable
final class ReleaseStore {
    /// Repos not pushed to for this long are left out.
    private static let quietReach: TimeInterval = 365 * 24 * 60 * 60
    /// A star history's backfill stops after this many stars, the older ones
    /// counted at its start.
    static let starReach = 10_000
    private static let concurrency = 4

    private(set) var histories: [String: ReleaseHistory] = [:]
    private(set) var downloadHistories: [String: DownloadHistory] = [:]
    private(set) var syncing: Set<String> = []
    private(set) var errors: [String: String] = [:]

    private let auth: AuthStore
    private let activity: SyncActivity

    init(auth: AuthStore, activity: SyncActivity) {
        self.auth = auth
        self.activity = activity
    }

    func history(for org: String) -> ReleaseHistory? { histories[org] }

    func downloadHistory(for org: String) -> DownloadHistory? { downloadHistories[org] }

    /// Whether this org's milestones have been loaded, so Refresh includes them.
    func isTracking(_ org: String) -> Bool { histories[org] != nil }

    /// Fetches the org's milestones and releases when stale or forced.
    /// `excluding` repos are left out.
    func sync(_ org: String, excluding excluded: Set<String> = [], force: Bool = false) async {
        loadCached(org)
        guard let api = auth.api, !syncing.contains(org), SyncSettings.isOn(.releases) else { return }
        let now = Date.now
        if !force, let history = histories[org], !SyncSettings.isDue(.releases, since: history.syncedAt, now: now) { return }
        // Wait out a low budget unless asked, as long as there's something to show.
        if !force && auth.shouldHoldOff && histories[org] != nil { return }

        syncing.insert(org)
        defer { syncing.remove(org) }
        let run = activity.begin(.releases, org: org)
        run.add("repos", title: "Milestones and releases", detail: "Repositories pushed to in the last year")
        run.add("more", title: "Older releases", detail: "Repositories with more than 25")
        run.add("stars", title: "Stars", detail: "When each stargazer starred a repository with releases")

        do {
            var fetched = try await run.track("repos", count: { $0.milestones.count + $0.releases.count }) { progress in
                try await api.milestonesAndReleases(org: org, pushedSince: now.addingTimeInterval(-Self.quietReach), onPage: progress)
            }
            fetched.moreReleases = fetched.moreReleases.filter { !excluded.contains($0.key) }
            fetched.repositories.removeAll { excluded.contains($0.name) }

            let pending = fetched.moreReleases.sorted { $0.key < $1.key }
            run.setTotal(pending.count, for: "more")
            let older = try await run.track("more", count: { _ in pending.count }) { progress in
                try await Self.eachRepo(pending, progress: progress) { repo in
                    try await api.releases(repo: repo.key, after: repo.value)
                }
            }
            fetched.releases += older.flatMap { $0 }

            let previous = histories[org]?.stars ?? [:]
            let starred = fetched.repositories
            run.setTotal(starred.count, for: "stars")
            let stars = try await run.track("stars", count: { $0.count }) { progress in
                let histories = try await Self.eachRepo(starred, progress: progress) { (repo: ReleaseRepository) -> StarHistory? in
                    // A repo whose stars can't be read keeps what it had,
                    // rather than failing the releases with it.
                    do {
                        return try await Self.stars(repo, after: previous[repo.name], api: api)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch APIError.unauthorized {
                        throw APIError.unauthorized
                    } catch {
                        return previous[repo.name]
                    }
                }
                return Dictionary(zip(starred.map(\.name), histories).compactMap { name, history in history.map { (name, $0) } }) { a, _ in a }
            }

            let history = ReleaseHistory(
                version: ReleaseHistory.currentVersion,
                orgLogin: org,
                syncedAt: now,
                milestones: fetched.milestones.filter { !excluded.contains($0.repo) },
                releases: fetched.releases.filter { !excluded.contains($0.repo) },
                repositories: fetched.repositories,
                stars: stars
            )
            histories[org] = history
            errors[org] = nil
            save(history)
            recordDownloads(history, at: now)
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

    /// Runs `work` for each repo, several at once, results in `repos`' order.
    private static func eachRepo<Repo: Sendable, T: Sendable>(
        _ repos: [Repo],
        progress: @escaping (Int, Int?) -> Void,
        _ work: @escaping @MainActor (Repo) async throws -> T
    ) async throws -> [T] {
        guard !repos.isEmpty else { return [] }
        return try await withThrowingTaskGroup(of: (Int, T).self) { group in
            func task(_ index: Int) -> @MainActor @Sendable () async throws -> (Int, T) {
                let repo = repos[index]
                return { (index, try await work(repo)) }
            }
            var next = 0
            while next < min(concurrency, repos.count) {
                group.addTask(operation: task(next))
                next += 1
            }
            var results: [Int: T] = [:]
            while let (index, result) = try await group.next() {
                results[index] = result
                progress(results.count, repos.count)
                if next < repos.count {
                    group.addTask(operation: task(next))
                    next += 1
                }
            }
            return repos.indices.compactMap { results[$0] }
        }
    }

    /// A repo's star history: new stars on top of `previous`, else a
    /// backfill to its first star or `starReach`, with the stars beyond
    /// counted at the start.
    private static func stars(_ repo: ReleaseRepository, after previous: StarHistory?, api: GitHubAPI) async throws -> StarHistory {
        if var history = previous, history.newest != nil {
            history.add(try await api.starDates(repo: repo.name, since: history.newest, limit: starReach).dates)
            return history
        }
        let fetched = try await api.starDates(repo: repo.name, since: nil, limit: starReach)
        var history = StarHistory(days: [], newest: nil, before: 0)
        history.add(fetched.dates)
        if !fetched.reachedEnd { history.before = max(repo.stars - fetched.dates.count, 0) }
        return history
    }

    // MARK: Disk

    static var cacheDirectory: URL { directory }

    /// The cache only: the download history can't be fetched again, so it stays.
    func clear() {
        histories = [:]
        errors = [:]
        try? FileManager.default.removeItem(at: Self.directory)
    }

    /// The download history too, for Erase Everything.
    func erase() {
        clear()
        downloadHistories = [:]
        try? FileManager.default.removeItem(at: Self.downloadsDirectory)
    }

    /// Records today's downloads per repo.
    private func recordDownloads(_ history: ReleaseHistory, at date: Date) {
        var downloads = downloadHistories[history.orgLogin]
            ?? DownloadHistory(version: DownloadHistory.currentVersion, orgLogin: history.orgLogin, snapshots: [])
        let totals = Dictionary(history.releases.map { ($0.repo, $0.downloads) }, uniquingKeysWith: +)
        downloads.record(totals, at: date)
        downloadHistories[history.orgLogin] = downloads
        if let data = try? Self.encoder.encode(downloads) {
            try? data.write(to: Self.fileURL(history.orgLogin, in: Self.downloadsDirectory), options: .atomic)
        }
    }

    private func loadCached(_ org: String) {
        if downloadHistories[org] == nil,
           let data = try? Data(contentsOf: Self.fileURL(org, in: Self.downloadsDirectory)),
           let downloads = try? Self.decoder.decode(DownloadHistory.self, from: data),
           downloads.version == DownloadHistory.currentVersion {
            downloadHistories[org] = downloads
        }
        guard histories[org] == nil,
              let data = try? Data(contentsOf: Self.fileURL(org)),
              let history = try? Self.decoder.decode(ReleaseHistory.self, from: data),
              history.version == ReleaseHistory.currentVersion
        else { return }
        histories[org] = history
    }

    private func save(_ history: ReleaseHistory) {
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
        URL.applicationSupportDirectory.appending(path: "Releases", directoryHint: .isDirectory)
    }

    private static var downloadsDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "ReleaseDownloads", directoryHint: .isDirectory)
    }

    private static func fileURL(_ org: String, in directory: URL = directory) -> URL {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "\(org).json")
    }
}
