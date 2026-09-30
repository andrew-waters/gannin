import SwiftUI

@main
struct GanninApp: App {
    @State private var auth: AuthStore
    @State private var orgs: OrgStore
    @State private var details: DetailStore
    @State private var database: UserDatabase
    @State private var hidden: HiddenStore
    @State private var metrics: MetricsStore
    @State private var workLog: WorkLogStore
    @State private var issues: IssueStore
    @State private var projects: ProjectStore
    @State private var actions: ActionsStore
    @State private var orgConfigs: OrgConfigStore
    @State private var peopleDates: PeopleDatesStore
    @State private var bankHolidays = BankHolidayStore()
    @State private var activity: SyncActivity
    @State private var harness: HarnessStore
    #if os(macOS)
    @State private var sessions: SessionStore
    #endif

    init() {
        let auth = AuthStore()
        let activity = SyncActivity()
        _auth = State(initialValue: auth)
        _activity = State(initialValue: activity)
        let database = UserDatabase()
        _database = State(initialValue: database)
        _hidden = State(initialValue: HiddenStore(database: database))
        _orgConfigs = State(initialValue: OrgConfigStore(database: database))
        _peopleDates = State(initialValue: PeopleDatesStore(database: database))
        _orgs = State(initialValue: OrgStore(auth: auth, activity: activity, database: database))
        _details = State(initialValue: DetailStore(auth: auth))
        _metrics = State(initialValue: MetricsStore(auth: auth, activity: activity))
        _workLog = State(initialValue: WorkLogStore(auth: auth, activity: activity))
        _issues = State(initialValue: IssueStore(auth: auth, activity: activity))
        _projects = State(initialValue: ProjectStore(auth: auth, activity: activity))
        _actions = State(initialValue: ActionsStore(auth: auth, activity: activity))
        let harness = HarnessStore(auth: auth)
        _harness = State(initialValue: harness)
        #if os(macOS)
        _sessions = State(initialValue: SessionStore(harness: harness))
        TabMenuRename.shared.install()
        #endif
    }

    var body: some Scene {
        // The main window. Each window (or tab) keeps its own org, section and
        // window of days in scene storage, so they're independent.
        WindowGroup(id: "main") {
            RootView()
                .joinsRequestedTab()
                .environment(actions)
                .environment(auth)
                .environment(orgs)
                .environment(details)
                .environment(hidden)
                .environment(metrics)
                .environment(workLog)
                .environment(issues)
                .environment(projects)
                .environment(orgConfigs)
                .environment(harness)
                .environment(peopleDates)
                .environment(bankHolidays)
                .environment(activity)
                .environment(database)
                #if os(macOS)
                .environment(sessions)
                #endif
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(after: .newItem) {
                #if os(macOS)
                NewTabCommand()
                #endif
                RenameTabCommand()
            }
        }

        // A PR opened from the work log; one window per PR.
        WindowGroup("Pull Request", for: PullRequestReference.self) { $reference in
            if let reference {
                PullRequestWindow(reference: reference)
                    .environment(auth)
                    .environment(orgs)
                    .environment(details)
                    .environment(hidden)
                    .environment(metrics)
                    .environment(workLog)
                    .environment(issues)
                    .environment(projects)
                    .environment(orgConfigs)
                    .environment(harness)
                    .environment(activity)
            }
        }
        .defaultSize(width: 560, height: 720)

        // An issue opened from the issue metrics; one window per issue, the
        // issue on the left and its board fields on the right.
        WindowGroup("Issue", for: IssueReference.self) { $reference in
            if let reference {
                IssueWindow(reference: reference)
                    .environment(auth)
                    .environment(orgs)
                    .environment(details)
                    .environment(hidden)
                    .environment(metrics)
                    .environment(workLog)
                    .environment(issues)
                    .environment(projects)
                    .environment(orgConfigs)
                    .environment(harness)
                    .environment(activity)
                    #if os(macOS)
                    .environment(sessions)
                    #endif
            }
        }
        .defaultSize(width: 1080, height: 960)
        .windowResizability(.contentMinSize)

        #if os(macOS)
        // A Claude Code session on an issue: its terminal, and the issue's
        // board fields beside it. The terminal outlives the window.
        WindowGroup("Session", for: SessionWindowID.self) { $window in
            if let window {
                SessionWindow(id: window.id)
                    .environment(sessions)
                    .environment(auth)
                    .environment(issues)
                    .environment(details)
                    .environment(orgConfigs)
                    .environment(harness)
                    .environment(projects)
            }
        }
        .defaultSize(width: 1280, height: 820)
        #endif

        #if os(macOS)
        Settings {
            SettingsView()
                .environment(actions)
                .environment(auth)
                .environment(orgs)
                .environment(metrics)
                .environment(issues)
                .environment(workLog)
                .environment(projects)
                .environment(details)
                .environment(bankHolidays)
                .environment(peopleDates)
                .environment(orgConfigs)
                .environment(harness)
                .environment(hidden)
                .environment(database)
        }
        #endif
    }
}

struct RootView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(DetailStore.self) private var details
    @Environment(WorkLogStore.self) private var workLog
    @Environment(IssueStore.self) private var issues
    @Environment(ProjectStore.self) private var projects
    @Environment(ActionsStore.self) private var actions
    @Environment(HarnessStore.self) private var harness

    var body: some View {
        Group {
            if auth.isSignedIn {
                MainView()
            } else {
                SignInView()
            }
        }
        .task { await auth.validate() }
        .onChange(of: auth.isSignedIn) {
            if !auth.isSignedIn {
                details.clear()
                workLog.clear()
                issues.clear()
                projects.clear()
                actions.clear()
                harness.clear()
            }
        }
    }
}
