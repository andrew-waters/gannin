import SwiftUI

/// The Storage pane of the app's settings: what's kept on this device, in
/// two kinds. Caches of what's fetched from GitHub (and bank holidays) can be
/// cleared and are fetched again. What you've entered in Gannin (people's
/// dates and time off, org settings, hidden items, stars) exists only here,
/// so deleting it asks first.
struct StorageSettings: View {
    @Environment(AuthStore.self) private var auth
    @Environment(OrgStore.self) private var orgs
    @Environment(MetricsStore.self) private var metrics
    @Environment(IssueStore.self) private var issues
    @Environment(WorkLogStore.self) private var workLog
    @Environment(ProjectStore.self) private var projects
    @Environment(DetailStore.self) private var details
    @Environment(BankHolidayStore.self) private var bankHolidays
    @Environment(PeopleDatesStore.self) private var peopleDates
    @Environment(OrgConfigStore.self) private var configs
    @Environment(HiddenStore.self) private var hidden
    @Environment(UserDatabase.self) private var database

    /// Bytes on disk per cache, measured when the pane opens and after a clear.
    @State private var sizes: [Cache: Int] = [:]
    @State private var confirming: Confirmation?

    enum Cache: String, CaseIterable, Identifiable {
        case snapshots = "Workload snapshots"
        case metrics = "Merged PR history"
        case issues = "Issue history"
        case workLog = "Work log"
        case projects = "Project boards"
        case details = "PR and issue details"
        case bankHolidays = "Bank holidays"

        var id: Self { self }

        var help: String {
            switch self {
            case .snapshots: "Members, teams, open and recently merged PRs, and open issues, per org"
            case .metrics: "Merged PRs with their review timings, behind the delivery and people stats"
            case .issues: "Issues with their board history, behind the issue metrics and investments"
            case .workLog: "PRs with their commits and reviews, behind Activity"
            case .projects: "Project board definitions and items"
            case .details: "Bodies, comments and checks of items you've opened"
            case .bankHolidays: "Public holidays by country and year, from date.nager.at"
            }
        }

        var location: URL {
            switch self {
            case .snapshots: OrgStore.cacheDirectory
            case .metrics: MetricsStore.cacheDirectory
            case .issues: IssueStore.cacheDirectory
            case .workLog: WorkLogStore.cacheDirectory
            case .projects: ProjectStore.cacheDirectory
            case .details: DetailStore.cacheFile
            case .bankHolidays: BankHolidayStore.cacheDirectory
            }
        }
    }

    enum Confirmation: Identifiable {
        case caches
        case yourData
        case everything

        var id: Self { self }
    }

    var body: some View {
        Form {
            Section {
                ForEach(Cache.allCases) { cache in
                    LabeledContent {
                        HStack(spacing: 10) {
                            Text(Self.size(sizes[cache] ?? 0))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            Button("Clear") { clear(cache) }
                                .disabled((sizes[cache] ?? 0) == 0)
                        }
                    } label: {
                        Text(cache.rawValue)
                        Text(cache.help)
                    }
                }
                LabeledContent("Total") {
                    Text(Self.size(sizes.values.reduce(0, +)))
                        .monospacedDigit()
                        .fontWeight(.semibold)
                }
                Button("Clear All Caches") { confirming = .caches }
                    .disabled(sizes.values.reduce(0, +) == 0)
            } header: {
                Text("Fetched from GitHub")
            } footer: {
                Text("Kept so pages open warm. Cleared data is fetched again when a page next needs it or on Refresh (⌘R); a large org's history can take a few minutes.")
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("People's dates and time off") {
                    Text(peopleSummary).foregroundStyle(.secondary)
                }
                LabeledContent("Org settings") {
                    Text(configs.configs.isEmpty ? "Defaults" : "\(configs.configs.count) \(configs.configs.count == 1 ? "org" : "orgs")")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Hidden items") {
                    Text("\(hidden.keys.count)").monospacedDigit().foregroundStyle(.secondary)
                }
                LabeledContent("Starred orgs") {
                    Text("\(orgs.starred.count)").monospacedDigit().foregroundStyle(.secondary)
                }
                LabeledContent("Stored") {
                    Text(Self.size(database.storedBytes)).monospacedDigit().foregroundStyle(.secondary)
                }
                LabeledContent("Sync") {
                    Label(database.isSyncing ? "iCloud" : "This device only", systemImage: database.isSyncing ? "icloud" : "icloud.slash")
                        .foregroundStyle(.secondary)
                }
                Button("Delete Your Data", role: .destructive) { confirming = .yourData }
                    .disabled(!hasYourData)
            } header: {
                Text("Entered in Gannin")
            } footer: {
                Text(database.isSyncing
                     ? "Synced through your private iCloud, so your other devices signed into the same Apple Account share it. Nothing is sent anywhere else. Deleting it removes it from every device and can't be undone."
                     : "Stored only on this device (iCloud isn't available to this build) and never sent anywhere. Deleting it can't be undone.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Erase Everything and Sign Out", role: .destructive) { confirming = .everything }
            } footer: {
                Text("Clears every cache and everything you've entered, removes your GitHub token from the keychain, and signs you out.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { measure() }
        .confirmationDialog(title(confirming), isPresented: Binding { confirming != nil } set: { if !$0 { confirming = nil } }, presenting: confirming) { confirmation in
            switch confirmation {
            case .caches:
                Button("Clear All Caches", role: .destructive) { clearCaches() }
            case .yourData:
                Button("Delete Your Data", role: .destructive) { deleteYourData() }
            case .everything:
                Button("Erase Everything", role: .destructive) { eraseEverything() }
            }
            Button("Cancel", role: .cancel) {}
        } message: { confirmation in
            switch confirmation {
            case .caches:
                Text("Everything fetched from GitHub is fetched again as it's needed.")
            case .yourData:
                Text("Removes \(peopleSummary.lowercased()), every org's settings, \(hidden.keys.count) hidden items and \(orgs.starred.count) stars. This can't be undone.")
            case .everything:
                Text("Removes every cache and everything you've entered, and signs you out. This can't be undone.")
            }
        }
    }

    // MARK: Your data

    private var peopleSummary: String {
        let people = peopleDates.dates.values.reduce(0) { $0 + $1.count }
        let entries = peopleDates.dates.values.flatMap(\.values).map(\.absences.count).reduce(0, +)
        guard people > 0 else { return "None" }
        return "\(people) \(people == 1 ? "person" : "people"), \(entries) time off \(entries == 1 ? "entry" : "entries")"
    }

    private var hasYourData: Bool {
        !peopleDates.dates.isEmpty || !configs.configs.isEmpty || !hidden.keys.isEmpty || !orgs.starred.isEmpty
    }

    private func title(_ confirmation: Confirmation?) -> String {
        switch confirmation {
        case .caches: "Clear all caches?"
        case .yourData: "Delete everything you've entered?"
        case .everything: "Erase everything and sign out?"
        case nil: ""
        }
    }

    // MARK: Clearing

    private func clear(_ cache: Cache) {
        switch cache {
        case .snapshots: orgs.clearSnapshots()
        case .metrics: metrics.clear()
        case .issues: issues.clear()
        case .workLog: workLog.clear()
        case .projects: projects.clear()
        case .details: details.clear()
        case .bankHolidays: bankHolidays.clear()
        }
        measure()
    }

    private func clearCaches() {
        Cache.allCases.forEach(clear)
    }

    private func deleteYourData() {
        peopleDates.clear()
        configs.clear()
        hidden.clear()
        orgs.clearStars()
    }

    private func eraseEverything() {
        clearCaches()
        deleteYourData()
        auth.signOut()
        orgs.clear()
        measure()
    }

    // MARK: Measuring

    private func measure() {
        sizes = Dictionary(uniqueKeysWithValues: Cache.allCases.map { ($0, Self.bytes(at: $0.location)) })
    }

    /// A file's size, or everything under a directory.
    private static func bytes(at url: URL) -> Int {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        if let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true {
            return values.totalFileAllocatedSize ?? 0
        }
        guard let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total = 0
        for case let file as URL in files {
            if let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true {
                total += values.totalFileAllocatedSize ?? 0
            }
        }
        return total
    }

    static func size(_ bytes: Int) -> String {
        bytes == 0 ? "Empty" : bytes.formatted(.byteCount(style: .file))
    }
}
