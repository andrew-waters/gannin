import Foundation
import Observation

/// Issue and PR detail keyed by GraphQL node ID, kept on disk so reopening
/// an item only hits GitHub when it has changed. Each org's entries are in
/// their own file, under the org the item was opened in.
@Observable
final class DetailStore {
    /// The most entries kept in each org's file.
    private static let maxEntries = 500
    /// Without an `updatedAt` to compare (merged PRs from the metrics
    /// history), cached detail is trusted this long.
    private static let maxAgeWithoutUpdatedAt: TimeInterval = 24 * 60 * 60
    /// Check state changes without bumping `updatedAt`, so pending checks
    /// are fetched again after this long.
    private static let maxAgeWhileChecksPending: TimeInterval = 2 * 60

    private(set) var details: [String: ItemDetail] = [:]
    private(set) var errors: [String: String] = [:]
    private var fetchedAt: [String: Date] = [:]
    /// The org whose file each entry is saved in: the one it was last fetched for.
    private var orgs: [String: String] = [:]
    private var loading: Set<String> = []

    private let auth: AuthStore

    init(auth: AuthStore) {
        self.auth = auth
        // `Details.json` holds every org's entries with no org recorded, so
        // they can't be split into org files. Deleting it means those items
        // are fetched again. Once it's gone this is a no-op.
        try? FileManager.default.removeItem(at: AppPaths.support.appending(path: "Details.json"))
        for org in Self.cache.orgs() {
            guard let cached = Self.cache.load([String: Cached].self, org: org) else { continue }
            // An item fetched for more than one org keeps the newest copy.
            for (id, entry) in cached where entry.fetchedAt > fetchedAt[id] ?? .distantPast {
                details[id] = entry.detail
                fetchedAt[id] = entry.fetchedAt
                orgs[id] = org
            }
        }
    }

    func detail(for id: String) -> ItemDetail? { details[id] }

    /// Fetches detail unless the cached copy is still current. `org` is the
    /// org the item is open in, and picks the file the detail is saved to.
    /// `updatedAt` is the item's as the list knows it; newer than the cache
    /// means refetch.
    func load(_ id: String, org: String, updatedAt: Date? = nil, force: Bool = false) async {
        guard let api = auth.api, !loading.contains(id), force || !isCurrent(id, updatedAt: updatedAt) else { return }
        // Recorded before the fetch, so `retry` knows the org after a failure.
        orgs[id] = org
        loading.insert(id)
        defer { loading.remove(id) }
        do {
            if let detail = try await chargingTo(.details, { try await RequestLimiter.interactive { try await api.itemDetail(id: id) } }) {
                details[id] = detail
                fetchedAt[id] = .now
                saver.request()
            }
            errors[id] = nil
        } catch is CancellationError {
        } catch APIError.unauthorized {
            auth.signOut()
        } catch {
            errors[id] = error.localizedDescription
        }
    }

    /// Fetches `id` again for the org it was last loaded for. Does nothing
    /// when it was never loaded.
    func retry(_ id: String) async {
        guard let org = orgs[id] else { return }
        await load(id, org: org, force: true)
    }

    private func isCurrent(_ id: String, updatedAt: Date?) -> Bool {
        guard let detail = details[id], let fetched = fetchedAt[id] else { return false }
        let age = -fetched.timeIntervalSinceNow
        if detail.checks == .pending || detail.checks == .expected {
            return age < Self.maxAgeWhileChecksPending
        }
        if let updatedAt, let known = detail.updatedAt {
            return known >= updatedAt
        }
        return age < Self.maxAgeWithoutUpdatedAt
    }

    static var cacheDirectory: URL { cache.directory }

    /// Forgets every entry and deletes every org's file.
    func clear() {
        details = [:]
        errors = [:]
        fetchedAt = [:]
        orgs = [:]
        saver.cancel()
        Self.cache.clear()
    }

    // MARK: Disk cache

    private struct Cached: Codable {
        let detail: ItemDetail
        let fetchedAt: Date
    }

    /// Items opened one after another share one write of the files. The write
    /// is delayed up to a second, so a crash or force-quit in that window
    /// loses the latest fetched details; a normal quit writes them.
    @ObservationIgnored private lazy var saver = SaveCoalescer { [weak self] in self?.save() }

    /// Writes each org's file with its most recently fetched entries,
    /// dropping the rest. Entries with no org aren't written.
    private func save() {
        var byOrg: [String: [(id: String, date: Date)]] = [:]
        for (id, date) in fetchedAt {
            if let org = orgs[id] { byOrg[org, default: []].append((id: id, date: date)) }
        }
        for (org, entries) in byOrg {
            let kept = entries.sorted { $0.date > $1.date }.prefix(Self.maxEntries)
            var cached: [String: Cached] = [:]
            for (id, date) in kept {
                if let detail = details[id] { cached[id] = Cached(detail: detail, fetchedAt: date) }
            }
            Self.cache.save(cached, org: org)
        }
    }

    /// Writes `details` as `org`'s cache, which a launch loads, for the demo
    /// build's fixture (`DemoLaunch`).
    static func writeCache(_ details: [String: ItemDetail], org: String, fetchedAt: Date = .now) {
        cache.save(details.mapValues { Cached(detail: $0, fetchedAt: fetchedAt) }, org: org)
    }

    private static let cache = OrgJSONCache(folder: "Details")
}
