import Foundation
import Observation

/// The signed-in user's orgs, which of them are starred, and the most recent
/// snapshot of work for each.
@Observable
final class OrgStore {
    static let lookbackDaysKey = "lookbackDays"
    static let defaultLookbackDays = 14
    private static let starredKey = "starredOrgs"
    private static let orgsKey = "orgs"

    private(set) var orgs: [Organisation] = []
    private(set) var starred: Set<String>
    private(set) var snapshots: [String: OrgSnapshot] = [:]
    private(set) var refreshing: Set<String> = []
    private(set) var errors: [String: String] = [:]
    private(set) var isLoadingOrgs = false

    private let auth: AuthStore

    init(auth: AuthStore) {
        self.auth = auth
        starred = Set(UserDefaults.standard.stringArray(forKey: Self.starredKey) ?? [])
        if let data = UserDefaults.standard.data(forKey: Self.orgsKey),
           let cached = try? JSONDecoder().decode([Organisation].self, from: data) {
            orgs = cached
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
        if starred.contains(org.login) {
            starred.remove(org.login)
        } else {
            starred.insert(org.login)
        }
        UserDefaults.standard.set(starred.sorted(), forKey: Self.starredKey)
    }

    // MARK: Loading

    func loadOrgs() async {
        guard let api = auth.api else { return }
        isLoadingOrgs = true
        defer { isLoadingOrgs = false }
        do {
            orgs = try await api.organisations()
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
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

    func refresh(_ login: String) async {
        guard let api = auth.api, !refreshing.contains(login) else { return }
        refreshing.insert(login)
        defer { refreshing.remove(login) }
        do {
            let snapshot = try await api.snapshot(org: login, lookbackDays: lookbackDays)
            snapshots[login] = snapshot
            errors[login] = nil
            if let data = try? Self.encoder.encode(snapshot) {
                try? data.write(to: Self.snapshotURL(login), options: .atomic)
            }
        } catch is CancellationError {
        } catch {
            handle(error, key: login)
        }
    }

    /// Shows the cached snapshot straight away, then refreshes when there is
    /// none or it is older than `maxAge`.
    func refreshIfStale(_ login: String, maxAge: TimeInterval = 5 * 60) async {
        loadCached(login)
        if let snapshot = snapshots[login], snapshot.fetchedAt.timeIntervalSinceNow > -maxAge { return }
        await refresh(login)
    }

    func clear() {
        snapshots = [:]
        orgs = []
        errors = [:]
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
