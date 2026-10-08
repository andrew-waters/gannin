import Foundation
import Observation

/// Project boards per org: the list of boards, each board's fields and views,
/// and each view's items (fetched with the view's own filter), on disk.
@Observable
final class ProjectStore {
    private static var maxAge: TimeInterval { SyncSettings.interval(.boards) }

    /// Every board each org has, closed ones too.
    private(set) var allBoardLists: [String: [OrgProject]] = [:]
    /// Boards linked to a repo, by `owner/name`, closed ones too, for a
    /// project that takes its boards from one (`RepoProject.boardsRepo`).
    private(set) var allRepoBoardLists: [String: [OrgProject]] = [:]

    /// Each org's open boards: what everything but the Boards page lists.
    var boardLists: [String: [OrgProject]] { allBoardLists.mapValues { $0.filter { !$0.closed } } }
    private(set) var caches: [String: BoardCache] = [:]
    private(set) var loading: Set<String> = []
    private(set) var errors: [String: String] = [:]

    private let auth: AuthStore
    private let activity: SyncActivity

    init(auth: AuthStore, activity: SyncActivity) {
        self.auth = auth
        self.activity = activity
    }

    static func key(_ org: String, _ number: Int) -> String { "\(org)#\(number)" }

    func cache(org: String, number: Int) -> BoardCache? { caches[Self.key(org, number)] }

    func items(org: String, number: Int, filter: String) -> [BoardItem]? {
        caches[Self.key(org, number)]?.resolvedItems(for: filter)
    }

    /// Records a board field saved from the app (nil clears it) onto the
    /// item's cached copy, shared between every view's filter, so an open
    /// board shows it before the next fetch. A no-op if the board or item
    /// isn't cached yet.
    func recordFieldValue(org: String, number: Int, itemID: String, field: String, value: IssueFieldValue?) {
        let key = Self.key(org, number)
        guard caches[key]?.itemsByID[itemID] != nil else { return }
        caches[key]?.itemsByID[itemID]?.values[field] = value
        if let cache = caches[key] { save(cache, key: key) }
    }

    func isLoading(org: String, number: Int) -> Bool {
        let key = Self.key(org, number)
        return loading.contains { $0 == key || $0.hasPrefix(key + "|") }
    }

    /// When each org's board list, and each repo's, was last fetched this
    /// launch, so pages opening don't fetch it again within the interval.
    @ObservationIgnored private var listFetchedAt: [String: Date] = [:]

    /// The org's open boards: from disk at once, then fetched again when
    /// older than the boards' interval (Settings › Sync), or `force`d after
    /// a change.
    func loadBoards(org: String, force: Bool = false) async {
        loadCachedBoards(org)
        guard let api = auth.api, SyncSettings.isOn(.boards) else { return }
        guard force || (SyncSettings.isDue(.boards, since: listFetchedAt[org]) && !(auth.shouldHoldOff && allBoardLists[org] != nil)) else { return }
        listFetchedAt[org] = .now
        if let projects = try? await chargingTo(.boards, { try await api.orgProjects(org: org) }) {
            allBoardLists[org] = projects
            if let data = try? Self.encoder.encode(projects) {
                try? data.write(to: Self.boardListURL(org), options: .atomic)
            }
        }
    }

    /// The boards a window lists: a repo's, for a project that takes its
    /// boards from one, else every one the org has.
    func boards(org: String, repo: String?) -> [OrgProject] {
        allBoards(org: org, repo: repo).filter { !$0.closed }
    }

    /// Those boards closed ones too, for the Boards page.
    func allBoards(org: String, repo: String?) -> [OrgProject] {
        guard let repo else { return allBoardLists[org] ?? [] }
        return allRepoBoardLists[repo] ?? []
    }

    /// The boards linked to a repo: from disk at once, then fetched again
    /// as `loadBoards` is.
    func loadRepoBoards(org: String, repo: String, force: Bool = false) async {
        if allRepoBoardLists[repo] == nil,
           let data = try? Data(contentsOf: Self.repoBoardListURL(repo)),
           let projects = try? Self.decoder.decode([OrgProject].self, from: data) {
            allRepoBoardLists[repo] = projects
        }
        guard let api = auth.api, SyncSettings.isOn(.boards) else { return }
        let key = "repo:\(repo)"
        guard force || (SyncSettings.isDue(.boards, since: listFetchedAt[key]) && !(auth.shouldHoldOff && allRepoBoardLists[repo] != nil)) else { return }
        listFetchedAt[key] = .now
        if let projects = try? await chargingTo(.boards, { try await api.repoProjects(org: org, repo: repo) }) {
            allRepoBoardLists[repo] = projects
            if let data = try? Self.encoder.encode(projects) {
                try? data.write(to: Self.repoBoardListURL(repo), options: .atomic)
            }
        }
    }

    /// Pulls the board list saved by a previous launch into memory.
    func loadCachedBoards(_ org: String) {
        guard allBoardLists[org] == nil,
              let data = try? Data(contentsOf: Self.boardListURL(org)),
              let projects = try? Self.decoder.decode([OrgProject].self, from: data) else { return }
        allBoardLists[org] = projects
    }

    /// Part of Refresh: the board list, and the definitions of boards the
    /// org's settings depend on (the tracked investments board).
    func refresh(org: String, definitions: [Int]) async {
        guard let api = auth.api, SyncSettings.isOn(.boards) else { return }
        loadCachedBoards(org)
        listFetchedAt[org] = .now
        let tracked = definitions.filter { $0 != 0 }
        let run = activity.begin(.projects, org: org)
        run.add("boards", title: "Boards")
        if !tracked.isEmpty { run.add("fields", title: "Investment board fields") }
        do {
            let projects = try await run.track("boards", count: { $0.count }) { _ in try await api.orgProjects(org: org) }
            allBoardLists[org] = projects
            if let data = try? Self.encoder.encode(projects) {
                try? data.write(to: Self.boardListURL(org), options: .atomic)
            }
            for number in tracked {
                let key = Self.key(org, number)
                loadCached(key)
                let board = try await run.track("fields", count: { $0?.fields.count }) { _ in try await api.board(org: org, number: number) }
                guard let board else { continue }
                var cache = caches[key] ?? BoardCache(board: board, fetchedAt: .now)
                cache.board = board
                cache.fetchedAt = .now
                caches[key] = cache
                save(cache, key: key)
            }
            run.finish()
        } catch is CancellationError {
            run.finish()
        } catch {
            run.finish(error: error)
        }
    }

    /// Just the board's fields and views (no items), for settings that pick a
    /// board field; from cache when fresh enough.
    func loadDefinition(org: String, number: Int, force: Bool = false) async {
        let key = Self.key(org, number)
        loadCached(key)
        guard let api = auth.api else { return }
        if !force, let cached = caches[key], Date.now.timeIntervalSince(cached.fetchedAt) < Self.maxAge { return }
        guard SyncSettings.isOn(.boards) else { return }
        do {
            guard let board = try await chargingTo(.boards, { try await api.board(org: org, number: number) }) else {
                errors[key] = "Couldn't find project \(number)."
                return
            }
            var cache = caches[key] ?? BoardCache(board: board, fetchedAt: .now)
            cache.board = board
            cache.fetchedAt = .now
            caches[key] = cache
            errors[key] = nil
            save(cache, key: key)
        } catch is CancellationError {
        } catch {
            errors[key] = error.localizedDescription
        }
    }

    /// The board's definition and the items for `filter`, from cache when
    /// fresh enough.
    func sync(org: String, number: Int, filter: String, force: Bool = false) async {
        let key = Self.key(org, number)
        let loadKey = "\(key)|\(filter)"
        loadCached(key)
        guard let api = auth.api, !loading.contains(loadKey), SyncSettings.isOn(.boards) else { return }
        let now = Date.now
        let cached = caches[key]
        let boardStale = cached.map { now.timeIntervalSince($0.fetchedAt) >= Self.maxAge } ?? true
        let itemsStale = cached?.items[filter].map { now.timeIntervalSince($0.fetchedAt) >= Self.maxAge } ?? true
        guard force || boardStale || itemsStale else { return }
        if cached?.items[filter] != nil, !force, auth.shouldHoldOff { return }

        loading.insert(loadKey)
        defer { loading.remove(loadKey) }
        let run = activity.begin(.projects, org: org)
        if force || boardStale { run.add("board", title: "Board and views") }
        run.add("items", title: "Items", detail: filter.isEmpty ? "Everything" : filter)
        do {
            if force || boardStale || cached == nil {
                if let board = try await run.track("board", count: { $0.map { $0.views.count } }, { _ in try await api.board(org: org, number: number) }) {
                    // Written as soon as it's fetched, ahead of the (often
                    // slower) items fetch below, so the board's tabs can
                    // show while its items are still loading.
                    var cache = caches[key] ?? BoardCache(board: board, fetchedAt: now)
                    cache.board = board
                    cache.fetchedAt = now
                    caches[key] = cache
                    save(cache, key: key)
                }
            }
            guard caches[key] != nil else {
                run.finish()
                errors[key] = "Couldn't find project \(number)."
                return
            }
            let items = try await run.track("items", count: \.count) {
                try await api.boardItems(org: org, number: number, filter: filter, onPage: $0)
            }
            // A sync for another filter (switching view tabs) can finish
            // while this one awaited, so merge onto the cache as it is now
            // rather than the snapshot taken before those awaits, or its
            // write would be lost.
            guard var cache = caches[key] else {
                run.finish()
                return
            }
            cache.merge(items, for: filter, at: now)
            caches[key] = cache
            errors[key] = nil
            save(cache, key: key)
            run.finish()
        } catch is CancellationError {
            run.finish()
        } catch {
            run.finish(error: error)
            errors[key] = error.localizedDescription
        }
    }

    static var cacheDirectory: URL { directory }

    func clear() {
        allBoardLists = [:]
        allRepoBoardLists = [:]
        caches = [:]
        errors = [:]
        try? FileManager.default.removeItem(at: Self.directory)
    }

    // MARK: Disk cache

    private func loadCached(_ key: String) {
        guard caches[key] == nil,
              let data = try? Data(contentsOf: Self.fileURL(key)),
              let cache = try? Self.decoder.decode(BoardCache.self, from: data) else {
            return
        }
        caches[key] = cache
    }

    private func save(_ cache: BoardCache, key: String) {
        if let data = try? Self.encoder.encode(cache) {
            try? data.write(to: Self.fileURL(key), options: .atomic)
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
        URL.applicationSupportDirectory.appending(path: "Projects", directoryHint: .isDirectory)
    }

    private static func boardListURL(_ org: String) -> URL {
        fileURL("boards-\(org)")
    }

    private static func repoBoardListURL(_ repo: String) -> URL {
        fileURL("repo-boards-\(repo.replacingOccurrences(of: "/", with: "~"))")
    }

    private static func fileURL(_ key: String) -> URL {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "\(key.replacingOccurrences(of: "#", with: "-")).json")
    }
}
