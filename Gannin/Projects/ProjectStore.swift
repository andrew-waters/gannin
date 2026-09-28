import Foundation
import Observation

/// Project boards per org: the list of boards, each board's fields and views,
/// and each view's items (fetched with the view's own filter), on disk.
@Observable
final class ProjectStore {
    private static let maxAge: TimeInterval = 10 * 60

    private(set) var boardLists: [String: [OrgProject]] = [:]
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

    func items(org: String, number: Int, filter: String) -> BoardItems? {
        caches[Self.key(org, number)]?.items[filter]
    }

    func isLoading(org: String, number: Int) -> Bool { loading.contains(Self.key(org, number)) }

    /// The org's open boards: from disk at once, then fetched again.
    func loadBoards(org: String) async {
        loadCachedBoards(org)
        guard let api = auth.api else { return }
        if let projects = try? await api.orgProjects(org: org) {
            boardLists[org] = projects
            if let data = try? Self.encoder.encode(projects) {
                try? data.write(to: Self.boardListURL(org), options: .atomic)
            }
        }
    }

    private func loadCachedBoards(_ org: String) {
        guard boardLists[org] == nil,
              let data = try? Data(contentsOf: Self.boardListURL(org)),
              let projects = try? Self.decoder.decode([OrgProject].self, from: data) else { return }
        boardLists[org] = projects
    }

    /// Part of Refresh: the board list, and the definitions of boards the
    /// org's settings depend on (the tracked investments board).
    func refresh(org: String, definitions: [Int]) async {
        await loadBoards(org: org)
        for number in definitions where number != 0 {
            await loadDefinition(org: org, number: number, force: true)
        }
    }

    /// Just the board's fields and views (no items), for settings that pick a
    /// board field; from cache when fresh enough.
    func loadDefinition(org: String, number: Int, force: Bool = false) async {
        let key = Self.key(org, number)
        loadCached(key)
        guard let api = auth.api, !loading.contains(key) else { return }
        if !force, let cached = caches[key], Date.now.timeIntervalSince(cached.fetchedAt) < Self.maxAge { return }
        guard let board = try? await api.board(org: org, number: number) else { return }
        var cache = caches[key] ?? BoardCache(board: board, fetchedAt: .now)
        cache.board = board
        cache.fetchedAt = .now
        caches[key] = cache
        save(cache, key: key)
    }

    /// The board's definition and the items for `filter`, from cache when
    /// fresh enough.
    func sync(org: String, number: Int, filter: String, force: Bool = false) async {
        let key = Self.key(org, number)
        loadCached(key)
        guard let api = auth.api, !loading.contains(key) else { return }
        let now = Date.now
        let cached = caches[key]
        let boardStale = cached.map { now.timeIntervalSince($0.fetchedAt) >= Self.maxAge } ?? true
        let itemsStale = cached?.items[filter].map { now.timeIntervalSince($0.fetchedAt) >= Self.maxAge } ?? true
        guard force || boardStale || itemsStale else { return }
        if cached?.items[filter] != nil, !force, auth.shouldHoldOff { return }

        loading.insert(key)
        defer { loading.remove(key) }
        let run = activity.begin(.projects, org: org)
        if force || boardStale { run.add("board", title: "Board and views") }
        run.add("items", title: "Items", detail: filter.isEmpty ? "Everything" : filter)
        do {
            var cache = cached
            if force || boardStale || cache == nil {
                if let board = try await run.track("board", count: { $0.map { $0.views.count } }, { _ in try await api.board(org: org, number: number) }) {
                    if cache == nil {
                        cache = BoardCache(board: board, fetchedAt: now)
                    } else {
                        cache?.board = board
                        cache?.fetchedAt = now
                    }
                }
            }
            guard var cache else {
                run.finish()
                errors[key] = "Couldn't find project \(number)."
                return
            }
            let items = try await run.track("items", count: \.count) {
                try await api.boardItems(org: org, number: number, filter: filter, onPage: $0)
            }
            cache.items[filter] = BoardItems(fetchedAt: now, items: items)
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
        boardLists = [:]
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

    private static func fileURL(_ key: String) -> URL {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "\(key.replacingOccurrences(of: "#", with: "-")).json")
    }
}
