import Foundation
import Observation

/// Each org's milestones and GitHub Releases, persisted as JSON in
/// Application Support and fetched again after 10 minutes. Only fetched
/// once the Releases page has been opened for an org; Refresh includes it
/// from then on.
@Observable
final class ReleaseStore {
    private static let maxAge: TimeInterval = 10 * 60
    /// Repos not pushed to for this long are left out.
    private static let quietReach: TimeInterval = 365 * 24 * 60 * 60

    private(set) var histories: [String: ReleaseHistory] = [:]
    private(set) var syncing: Set<String> = []
    private(set) var errors: [String: String] = [:]

    private let auth: AuthStore
    private let activity: SyncActivity

    init(auth: AuthStore, activity: SyncActivity) {
        self.auth = auth
        self.activity = activity
    }

    func history(for org: String) -> ReleaseHistory? { histories[org] }

    /// Whether this org's milestones have been loaded, so Refresh includes them.
    func isTracking(_ org: String) -> Bool { histories[org] != nil }

    /// Fetches the org's milestones and releases when stale or forced.
    /// `excluding` repos are left out.
    func sync(_ org: String, excluding excluded: Set<String> = [], force: Bool = false) async {
        loadCached(org)
        guard let api = auth.api, !syncing.contains(org) else { return }
        let now = Date.now
        if !force, let history = histories[org], now.timeIntervalSince(history.syncedAt) < Self.maxAge { return }
        // Wait out a low budget unless asked, as long as there's something to show.
        if !force && auth.shouldHoldOff && histories[org] != nil { return }

        syncing.insert(org)
        defer { syncing.remove(org) }
        let run = activity.begin(.releases, org: org)
        run.add("repos", title: "Milestones and releases", detail: "Repositories pushed to in the last year")

        do {
            let fetched = try await run.track("repos", count: { $0.milestones.count + $0.releases.count }) { progress in
                try await api.milestonesAndReleases(org: org, pushedSince: now.addingTimeInterval(-Self.quietReach), onPage: progress)
            }
            let history = ReleaseHistory(
                version: ReleaseHistory.currentVersion,
                orgLogin: org,
                syncedAt: now,
                milestones: fetched.milestones.filter { !excluded.contains($0.repo) },
                releases: fetched.releases.filter { !excluded.contains($0.repo) }
            )
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

    // MARK: Disk

    static var cacheDirectory: URL { directory }

    func clear() {
        histories = [:]
        errors = [:]
        try? FileManager.default.removeItem(at: Self.directory)
    }

    private func loadCached(_ org: String) {
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

    private static func fileURL(_ org: String) -> URL {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "\(org).json")
    }
}
