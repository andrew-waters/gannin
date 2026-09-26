import Foundation
import Observation

/// Issue and PR detail keyed by GraphQL node ID, kept on disk so reopening
/// an item only hits GitHub when it has changed.
@Observable
final class DetailStore {
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
    private var loading: Set<String> = []

    private let auth: AuthStore

    init(auth: AuthStore) {
        self.auth = auth
        if let data = try? Data(contentsOf: Self.fileURL),
           let cached = try? Self.decoder.decode([String: Cached].self, from: data) {
            details = cached.mapValues(\.detail)
            fetchedAt = cached.mapValues(\.fetchedAt)
        }
    }

    func detail(for id: String) -> ItemDetail? { details[id] }

    /// Fetches detail unless the cached copy is still current. `updatedAt`
    /// is the item's as the list knows it; newer than the cache means refetch.
    func load(_ id: String, updatedAt: Date? = nil, force: Bool = false) async {
        guard let api = auth.api, !loading.contains(id), force || !isCurrent(id, updatedAt: updatedAt) else { return }
        loading.insert(id)
        defer { loading.remove(id) }
        do {
            if let detail = try await api.itemDetail(id: id) {
                details[id] = detail
                fetchedAt[id] = .now
                save()
            }
            errors[id] = nil
        } catch is CancellationError {
        } catch APIError.unauthorized {
            auth.signOut()
        } catch {
            errors[id] = error.localizedDescription
        }
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

    func clear() {
        details = [:]
        errors = [:]
        fetchedAt = [:]
        try? FileManager.default.removeItem(at: Self.fileURL)
    }

    // MARK: Disk cache

    private struct Cached: Codable {
        let detail: ItemDetail
        let fetchedAt: Date
    }

    /// Writes the most recently fetched entries, dropping the rest.
    private func save() {
        let kept = fetchedAt.sorted { $0.value > $1.value }.prefix(Self.maxEntries)
        var cached: [String: Cached] = [:]
        for (id, date) in kept {
            if let detail = details[id] { cached[id] = Cached(detail: detail, fetchedAt: date) }
        }
        if let data = try? Self.encoder.encode(cached) {
            try? data.write(to: Self.fileURL, options: .atomic)
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

    private static var fileURL: URL {
        try? FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
        return URL.applicationSupportDirectory.appending(path: "Details.json")
    }
}
