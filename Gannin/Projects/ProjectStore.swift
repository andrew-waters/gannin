import AppKit
import Foundation
import Observation
import os

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
    /// When Refresh was last asked for, by org: an open `ProjectBoardView`
    /// watches its own org's entry to force its own items fetch, since
    /// `refresh` itself only reaches the board list and tracked definitions,
    /// not whichever board and filter happens to be open.
    private(set) var refreshRequested: [String: Date] = [:]

    private let auth: AuthStore
    private let activity: SyncActivity

    // State for `save`, touched on the main actor only and not observed, since
    // no view reads it.

    /// The newest cache snapshot per board key that hasn't been handed to the
    /// writer yet. A later save for the same key replaces it, so only the
    /// latest state is ever written.
    @ObservationIgnored private var pendingSaves: [String: BoardCache] = [:]
    /// The snapshot being written now for each key, kept until its write
    /// returns so a quit mid-write can write it again (`flushPendingSaves`).
    @ObservationIgnored private var inFlight: [String: BoardCache] = [:]
    /// Board keys with a write loop running. While a key is in here, `save`
    /// only updates `pendingSaves`, so one board never has two writes at once.
    @ObservationIgnored private var writingKeys: Set<String> = []
    /// Encodes, decodes and writes the cache files off the main actor, and
    /// stops a write landing after `clear` has deleted the folder.
    @ObservationIgnored private let files = BoardCacheFiles()

    init(auth: AuthStore, activity: SyncActivity) {
        self.auth = auth
        self.activity = activity
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushPendingSaves() }
        }
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

    /// Records an issue closing or reopening from the app, by its content
    /// ID (what closes it doesn't know its item ID on this board). A no-op
    /// if the board or item isn't cached yet.
    func recordClosed(org: String, number: Int, contentID: String, closed: Bool) {
        let key = Self.key(org, number)
        guard var cache = caches[key] else { return }
        let matching = cache.itemsByID.values.filter { $0.contentID == contentID }.map(\.id)
        guard !matching.isEmpty else { return }
        for id in matching { cache.itemsByID[id]?.state = closed ? "CLOSED" : "OPEN" }
        caches[key] = cache
        save(cache, key: key)
    }

    /// Takes an item off the board's cache, by its own ID, once it's been
    /// removed from the board on GitHub.
    func recordRemoved(org: String, number: Int, itemID: String) {
        let key = Self.key(org, number)
        guard caches[key]?.itemsByID[itemID] != nil else { return }
        caches[key]?.itemsByID[itemID] = nil
        if let cache = caches[key] { save(cache, key: key) }
    }

    /// Records labels changed on an issue from the app, on every board
    /// that has it cached: labels show as a built-in column on any board,
    /// not just the one an investment category might be tracked on. A new
    /// label borrows a colour already seen on this org's cached boards,
    /// grey when none is, until the next fetch corrects it.
    func recordLabels(org: String, contentID: String, labels: [String]) {
        let prefix = "\(org)#"
        var knownColors: [String: String] = [:]
        for (key, cache) in caches where key.hasPrefix(prefix) {
            for item in cache.itemsByID.values {
                for label in item.labels where knownColors[label.name] == nil {
                    knownColors[label.name] = label.color
                }
            }
        }
        let resolved = labels.map { IssueLabel(name: $0, color: knownColors[$0] ?? "ededed") }
        for key in caches.keys where key.hasPrefix(prefix) {
            guard var cache = caches[key] else { continue }
            let matching = cache.itemsByID.values.filter { $0.contentID == contentID }.map(\.id)
            guard !matching.isEmpty else { continue }
            for id in matching { cache.itemsByID[id]?.labels = resolved }
            caches[key] = cache
            save(cache, key: key)
        }
    }

    /// The logins assigned to an issue on a cached board, for an issue the
    /// issue history doesn't hold; nil when no cached board has it.
    func assignees(org: String, contentID: String) -> [String]? {
        let prefix = "\(org)#"
        for (key, cache) in caches where key.hasPrefix(prefix) {
            if let item = cache.itemsByID.values.first(where: { $0.contentID == contentID }) {
                return item.assignees.map(\.login)
            }
        }
        return nil
    }

    /// Records assignees changed on an issue from the app, on every board
    /// that has it cached.
    func recordAssignees(org: String, contentID: String, assignees: [Person]) {
        let prefix = "\(org)#"
        for key in caches.keys where key.hasPrefix(prefix) {
            guard var cache = caches[key] else { continue }
            let matching = cache.itemsByID.values.filter { $0.contentID == contentID }.map(\.id)
            guard !matching.isEmpty else { continue }
            for id in matching { cache.itemsByID[id]?.assignees = assignees }
            caches[key] = cache
            save(cache, key: key)
        }
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
        guard auth.shouldFetch(.boards, since: listFetchedAt[org], force: force, hasData: allBoardLists[org] != nil) else { return }
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
        guard auth.shouldFetch(.boards, since: listFetchedAt[key], force: force, hasData: allRepoBoardLists[repo] != nil) else { return }
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
        refreshRequested[org] = .now
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
                await loadCached(key)
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
        await loadCached(key)
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
        await loadCached(key)
        guard let api = auth.api, !loading.contains(loadKey), SyncSettings.isOn(.boards) else { return }
        let now = Date.now
        let cached = caches[key]
        let boardStale = cached.map { now.timeIntervalSince($0.fetchedAt) >= Self.maxAge } ?? true
        let itemsStale = cached?.items[filter].map { now.timeIntervalSince($0.fetchedAt) >= Self.maxAge } ?? true
        guard force || boardStale || itemsStale else { return }
        if auth.shouldWaitForBudget(force: force, hasData: cached?.items[filter] != nil) { return }

        loading.insert(loadKey)
        defer { loading.remove(loadKey) }
        let run = activity.begin(.projects, org: org)
        if force || boardStale { run.add("board", title: "Board and views") }
        run.add("items", title: "Items", detail: filter.isEmpty ? "Everything" : filter)
        do {
            let needsBoard = force || boardStale || cached == nil
            // Started together: the items fetch doesn't depend on the
            // board's fields or views, so there's no need to wait for one
            // before starting the other.
            async let boardTask: Board? = needsBoard
                ? try await run.track("board", count: { $0.map { $0.views.count } }, { _ in try await api.board(org: org, number: number) })
                : nil
            async let itemsTask = run.track("items", count: \.count) {
                try await api.boardItems(org: org, number: number, filter: filter, onPage: $0)
            }
            if let board = try await boardTask {
                // Written as soon as it's fetched, so the board's tabs can
                // show while its items are still loading.
                var cache = caches[key] ?? BoardCache(board: board, fetchedAt: now)
                cache.board = board
                cache.fetchedAt = now
                caches[key] = cache
                save(cache, key: key)
            }
            guard caches[key] != nil else {
                run.finish()
                errors[key] = "Couldn't find project \(number)."
                return
            }
            let items = try await itemsTask
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
        // Writes still waiting or in flight belong to the folder removed here.
        pendingSaves = [:]
        inFlight = [:]
        writingKeys = []
        files.reset(removing: Self.directory)
    }

    // MARK: Disk cache

    /// Reads and decodes the saved cache off the main actor. What it read is
    /// dropped if a cache arrived in memory meanwhile, or `clear` ran.
    private func loadCached(_ key: String) async {
        guard caches[key] == nil else { return }
        let url = Self.fileURL(key)
        let generation = files.generation
        let cache = await Task.detached { BoardCacheFiles.read(url) }.value
        guard let cache, caches[key] == nil, files.generation == generation else { return }
        caches[key] = cache
    }

    /// Writes the cache off the main actor, newest snapshot last. A save made
    /// while one for the same board is still writing replaces the waiting
    /// snapshot, so a board never has two writes racing and bursts of saves
    /// cost one more write, not one each.
    private func save(_ cache: BoardCache, key: String) {
        pendingSaves[key] = cache
        guard writingKeys.insert(key).inserted else { return }
        let generation = files.generation
        let url = Self.fileURL(key)
        Task {
            while files.generation == generation, let snapshot = pendingSaves.removeValue(forKey: key) {
                inFlight[key] = snapshot
                let files = files
                await Task.detached { files.write(snapshot, to: url, generation: generation) }.value
                if files.generation == generation { inFlight[key] = nil }
            }
            // After a `clear`, `writingKeys` is already empty and may hold a
            // newer loop for this key, which isn't this one's to remove.
            if files.generation == generation { writingKeys.remove(key) }
        }
    }

    /// Writes what's still waiting or mid-write, on the main actor, so a quit
    /// right after a sync doesn't lose it. A waiting snapshot is newer than
    /// the one mid-write for its board, so it's the one written.
    private func flushPendingSaves() {
        for (key, cache) in inFlight.merging(pendingSaves, uniquingKeysWith: { _, pending in pending }) {
            files.write(cache, to: Self.fileURL(key), generation: files.generation)
        }
        pendingSaves = [:]
        inFlight = [:]
    }

    private static let encoder = BoardCacheFiles.makeEncoder()
    private static let decoder = BoardCacheFiles.makeDecoder()

    private static var directory: URL {
        AppPaths.support.appending(path: "Projects", directoryHint: .isDirectory)
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

/// The board cache files' encoding, and the generation that keeps a write
/// from landing after `ProjectStore.clear` has deleted the folder. Nothing
/// here is main-actor, so the encode, decode and write run off it.
nonisolated final class BoardCacheFiles: Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: 0)

    /// Counts the times the folder has been cleared.
    var generation: Int { lock.withLock { $0 } }

    /// Starts a new generation and deletes `directory`. Held under the lock
    /// that `write` checks and writes under, so a write of an older
    /// generation either finished before this or is skipped.
    func reset(removing directory: URL) {
        lock.withLock { generation in
            generation += 1
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// Encodes `cache` and writes it, unless the folder was cleared since
    /// `generation`.
    func write(_ cache: BoardCache, to url: URL, generation expected: Int) {
        guard let data = try? Self.makeEncoder().encode(cache) else { return }
        lock.withLock { generation in
            guard generation == expected else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    static func read(_ url: URL) -> BoardCache? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? makeDecoder().decode(BoardCache.self, from: data)
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
