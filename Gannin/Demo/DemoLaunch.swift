import Foundation

/// The demo build's start: before any store is made, it empties the demo's
/// own folder and preferences, so every launch (and every capture) begins
/// from the fixture alone, and lays the fixture down for the stores to load.
enum DemoLaunch {
    static func prepare() {
        precondition(NetworkGate.isSealed, "DemoLaunch runs only in the demo build")
        let folder = AppPaths.support
        // Never the shared Application Support: only the demo's own folder.
        precondition(folder.path.contains("dev.andon.gannin.demo"), "The demo build's folder must be its own")
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let defaults = UserDefaults.standard
        if let identifier = Bundle.main.bundleIdentifier { defaults.removePersistentDomain(forName: identifier) }
        // No windows or tabs restored from the last run.
        defaults.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        defaults.set(true, forKey: "ApplePersistenceIgnoreState")
        // No second Gannin icon in the menu bar beside the real one.
        defaults.set(false, forKey: EngineerWatch.menuBarKey)
        seed(defaults)
    }

    /// The fixture, laid down through each store's own cache, so the stores
    /// load it as they would a previous launch's.
    private static func seed(_ defaults: UserDefaults) {
        let org = DemoFixture.org
        if let data = try? JSONEncoder().encode([DemoFixture.personal, DemoFixture.organisation]) {
            defaults.set(data, forKey: "orgs")
        }
        defaults.set(org, forKey: "lastOrg")
        OrgSnapshotCache().save(DemoFixture.snapshot)
        let history = DemoFixture.metricsHistory
        PullRequestStore.shared.merge(history.pullRequests.values.map { StoredPullRequest(metrics: $0) }, org: org)
        MetricsStore.defaultCache.save(history, org: org)
        DetailStore.writeCache(DemoFixture.details)
    }
}
