import Foundation
import Observation

/// The signed-in user's orgs, which of them are starred, and the most recent
/// snapshot of work for each.
@Observable
final class OrgStore {
    static let lookbackDaysKey = "lookbackDays"
    static let defaultLookbackDays = 14
    private static let orgsKey = "orgs"

    private(set) var orgs: [Organisation] = []
    private(set) var starred: Set<String>
    private(set) var snapshots: [String: OrgSnapshot] = [:]
    private(set) var refreshing: Set<String> = []
    private(set) var errors: [String: String] = [:]
    private(set) var isLoadingOrgs = false

    private let auth: AuthStore
    private let activity: SyncActivity
    @ObservationIgnored private let database: UserDatabase

    /// Stars are kept in the synced `UserDatabase`.
    init(auth: AuthStore, activity: SyncActivity, database: UserDatabase) {
        self.auth = auth
        self.activity = activity
        self.database = database
        starred = database.loadStars()
        database.onRemoteChange { [weak self] in
            guard let self else { return }
            let loaded = database.loadStars()
            if loaded != starred { starred = loaded }
        }
        if let data = UserDefaults.standard.data(forKey: Self.orgsKey),
           let cached = try? JSONDecoder().decode([Organisation].self, from: data) {
            orgs = cached
            GitHubAccounts.setUsers(Set(cached.filter(\.isPersonal).map(\.login)))
        }
    }

    var starredOrgs: [Organisation] { orgs.filter { starred.contains($0.login) } }

    var lookbackDays: Int {
        let stored = UserDefaults.standard.integer(forKey: Self.lookbackDaysKey)
        return stored > 0 ? stored : Self.defaultLookbackDays
    }

    func org(login: String) -> Organisation? {
        orgs.first { $0.login == login }
    }

    // MARK: Starring

    func isStarred(_ org: Organisation) -> Bool { starred.contains(org.login) }

    func toggleStar(_ org: Organisation) {
        let star = !starred.contains(org.login)
        if star { starred.insert(org.login) } else { starred.remove(org.login) }
        database.setStar(org.login, star)
    }

    func clearStars() {
        starred = []
        database.deleteAllStars()
    }

    /// Drops the cached snapshots but keeps the org list; each org is
    /// fetched again when next shown or refreshed.
    func clearSnapshots() {
        snapshots = [:]
        errors = [:]
        try? FileManager.default.removeItem(at: Self.snapshotsDirectory)
    }

    static var cacheDirectory: URL { snapshotsDirectory }

    // MARK: Loading

    func loadOrgs() async {
        guard let api = auth.api else { return }
        isLoadingOrgs = true
        defer { isLoadingOrgs = false }
        do {
            // Your own account first, then the orgs.
            let viewer = try await api.viewer()
            let personal = Organisation(id: "user:\(viewer.login)", login: viewer.login, name: viewer.name, avatarUrl: viewer.avatarUrl, description: "Your personal account", isUser: true)
            orgs = [personal] + (try await api.organisations())
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            GitHubAccounts.setUsers([viewer.login])
            errors["orgs"] = nil
            if let data = try? JSONEncoder().encode(orgs) {
                UserDefaults.standard.set(data, forKey: Self.orgsKey)
            }
        } catch {
            handle(error, key: "orgs")
        }
    }

    func snapshot(for login: String) -> OrgSnapshot? { snapshots[login] }

    /// Pulls the snapshot saved by a previous launch into memory.
    private func loadCached(_ login: String) {
        guard snapshots[login] == nil,
              let data = try? Data(contentsOf: Self.snapshotURL(login)),
              let snapshot = try? Self.decoder.decode(OrgSnapshot.self, from: data) else {
            return
        }
        snapshots[login] = snapshot
    }

    enum RefreshMode {
        /// Opening an org: members and teams only when stale.
        case automatic
        /// The Refresh button: members and teams too.
        case manual
        /// Everything searched again from scratch.
        case full
    }

    private static let peopleMaxAge: TimeInterval = 60 * 60
    private static let fullMaxAge: TimeInterval = 24 * 60 * 60
    /// Overlap on the changes search, so an update landing while the
    /// previous refresh ran isn't missed.
    private static let changesOverlap: TimeInterval = 5 * 60

    func refresh(_ login: String, mode: RefreshMode = .manual) async {
        loadCached(login)
        guard let api = auth.api, !refreshing.contains(login) else { return }
        refreshing.insert(login)
        defer { refreshing.remove(login) }

        let previous = snapshots[login]
        var plan = GitHubAPI.SnapshotPlan()
        if let previous, mode != .full {
            plan.people = mode == .manual || previous.peopleFetchedAt.map { -$0.timeIntervalSinceNow > Self.peopleMaxAge } ?? true
            // Changes only while the last full search is recent and for the
            // same lookback; otherwise search everything again.
            if let full = previous.fullFetchedAt,
               -full.timeIntervalSinceNow < Self.fullMaxAge,
               previous.lookbackDays == lookbackDays {
                plan.changesSince = previous.fetchedAt.addingTimeInterval(-Self.changesOverlap)
            }
        }

        let run = activity.begin(.workload, org: login)
        do {
            let snapshot = try await api.snapshot(
                org: login,
                lookbackDays: lookbackDays,
                previous: previous,
                plan: plan,
                run: run
            )
            snapshots[login] = snapshot
            errors[login] = nil
            if let data = try? Self.encoder.encode(snapshot) {
                try? data.write(to: Self.snapshotURL(login), options: .atomic)
            }
            run.finish()
        } catch is CancellationError {
            run.finish()
        } catch {
            run.finish(error: error)
            handle(error, key: login)
        }
    }

    /// Shows the cached snapshot straight away, then refreshes when there is
    /// none or it is older than `maxAge`. With a cached snapshot, waits out a
    /// low rate limit rather than spending the last of it.
    func refreshIfStale(_ login: String, maxAge: TimeInterval = 5 * 60) async {
        loadCached(login)
        if let snapshot = snapshots[login] {
            if snapshot.fetchedAt.timeIntervalSinceNow > -maxAge || auth.shouldHoldOff { return }
        }
        await refresh(login, mode: .automatic)
    }

    func clear() {
        snapshots = [:]
        orgs = []
        errors = [:]
        activity.clear()
        UserDefaults.standard.removeObject(forKey: Self.orgsKey)
        try? FileManager.default.removeItem(at: Self.snapshotsDirectory)
    }

    private func handle(_ error: Error, key: String) {
        if case APIError.unauthorized = error {
            auth.signOut()
            clear()
            return
        }
        errors[key] = error.localizedDescription
    }

    // MARK: Disk cache

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

    private static var snapshotsDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Snapshots", directoryHint: .isDirectory)
    }

    private static func snapshotURL(_ login: String) -> URL {
        try? FileManager.default.createDirectory(at: snapshotsDirectory, withIntermediateDirectories: true)
        return snapshotsDirectory.appending(path: "\(login).json")
    }
}
