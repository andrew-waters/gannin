import Foundation

/// An org's snapshot on disk: its own file, which lists the PRs' IDs, with
/// the PRs themselves in `PullRequestStore`.
struct OrgSnapshotCache {
    static let defaultDirectory = URL.applicationSupportDirectory.appending(path: "Snapshots", directoryHint: .isDirectory)

    let directory: URL
    let pullRequests: PullRequestStore

    init(directory: URL = Self.defaultDirectory, pullRequests: PullRequestStore = .shared) {
        self.directory = directory
        self.pullRequests = pullRequests
    }

    /// The saved snapshot with its PRs, or nil when there's none or the store
    /// no longer holds the PRs it lists, which a refresh then fetches again.
    /// A snapshot from before PRs moved to the store brings its PRs along.
    func load(_ login: String) -> OrgSnapshot? {
        guard let data = try? Data(contentsOf: fileURL(login)),
              var snapshot = try? Self.decoder.decode(OrgSnapshot.self, from: data) else {
            return nil
        }
        if let legacy = try? Self.decoder.decode(OrgSnapshot.Legacy.self, from: data) {
            pullRequests.merge((legacy.openPullRequests + legacy.mergedPullRequests).map { StoredPullRequest(workload: $0) }, org: login)
            snapshot.storedOpenIDs = legacy.openPullRequests.map(\.id)
            snapshot.storedMergedIDs = legacy.mergedPullRequests.map(\.id)
            guard let hydrated = hydrated(snapshot, org: login) else { return nil }
            write(hydrated)
            return hydrated
        }
        return hydrated(snapshot, org: login)
    }

    /// Writes the snapshot, its PRs going to the store first: a file listing
    /// PRs the store doesn't have would be dropped on the next load. PRs that
    /// have left the snapshot lose the workload's part of the store.
    func save(_ snapshot: OrgSnapshot) {
        let all = snapshot.openPullRequests + snapshot.mergedPullRequests
        pullRequests.merge(all.map { StoredPullRequest(workload: $0) }, org: snapshot.orgLogin)
        pullRequests.prune(.workload, org: snapshot.orgLogin, keeping: Set(all.map(\.id)))
        write(snapshot)
    }

    /// A change to a PR made after a write to GitHub, saved once a burst of
    /// them ends.
    func update(_ pr: PullRequest, org: String) {
        pullRequests.merge([StoredPullRequest(workload: pr)], org: org, delayed: true)
    }

    func clear() {
        try? FileManager.default.removeItem(at: directory)
        pullRequests.clear(.workload)
    }

    private func hydrated(_ snapshot: OrgSnapshot, org: String) -> OrgSnapshot? {
        guard let openIDs = snapshot.storedOpenIDs, let mergedIDs = snapshot.storedMergedIDs else { return nil }
        let held = pullRequests.pullRequests(org: org)
        let open = openIDs.compactMap { held[$0]?.workloadPullRequest }
        let merged = mergedIDs.compactMap { held[$0]?.workloadPullRequest }
        guard open.count == openIDs.count, merged.count == mergedIDs.count else { return nil }
        var snapshot = snapshot
        snapshot.openPullRequests = open
        snapshot.mergedPullRequests = merged
        return snapshot
    }

    private func write(_ snapshot: OrgSnapshot) {
        var saved = snapshot
        saved.storedOpenIDs = snapshot.openPullRequests.map(\.id)
        saved.storedMergedIDs = snapshot.mergedPullRequests.map(\.id)
        guard let data = try? Self.encoder.encode(saved) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL(snapshot.orgLogin), options: .atomic)
    }

    private func fileURL(_ login: String) -> URL {
        directory.appending(path: "\(login).json")
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
}
