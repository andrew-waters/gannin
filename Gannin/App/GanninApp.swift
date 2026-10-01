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
    @State private var fieldNotes = FieldNotesStore()
    @State private var activity: SyncActivity
    @State private var harness: HarnessStore
    @State private var team: HarnessTeamStore
    #if os(macOS)
    @State private var sessions: SessionStore
    @NSApplicationDelegateAdaptor private var appDelegate: GanninAppDelegate
    #endif

    init() {
        let auth = AuthStore()
        let activity = SyncActivity()
        _auth = State(initialValue: auth)
        _activity = State(initialValue: activity)
        let database = UserDatabase()
        _database = State(initialValue: database)
        _hidden = State(initialValue: HiddenStore(database: database))
        let orgConfigs = OrgConfigStore(database: database)
        let peopleDates = PeopleDatesStore(database: database)
        _orgConfigs = State(initialValue: orgConfigs)
        _peopleDates = State(initialValue: peopleDates)
        _orgs = State(initialValue: OrgStore(auth: auth, activity: activity, database: database))
        _details = State(initialValue: DetailStore(auth: auth))
        _metrics = State(initialValue: MetricsStore(auth: auth, activity: activity))
        _workLog = State(initialValue: WorkLogStore(auth: auth, activity: activity))
        _issues = State(initialValue: IssueStore(auth: auth, activity: activity))
        _projects = State(initialValue: ProjectStore(auth: auth, activity: activity))
        _actions = State(initialValue: ActionsStore(auth: auth, activity: activity))
        let harness = HarnessStore(auth: auth)
        _harness = State(initialValue: harness)
        // Team data from the harness, for orgs that keep it there.
        let team = HarnessTeamStore(harness: harness)
        team.setup = { [weak orgConfigs] org in orgConfigs?.harness(for: org) }
        orgConfigs.team = team
        peopleDates.team = team
        _team = State(initialValue: team)
        #if os(macOS)
        let sessions = SessionStore(harness: harness)
        _sessions = State(initialValue: sessions)
        GanninAppDelegate.sessions = sessions
        sessions.api = { [weak auth] in auth?.api }
        sessions.watchPullRequests()
        TabMenuRename.shared.install()
        #endif
    }

    var body: some Scene {
        // The main window. Each window (or tab) keeps its own org, section and
        // window of days in scene storage, so they're independent.
        WindowGroup(id: "main") {
            RootView()
                .joinsRequestedTab()
                #if os(macOS)
                .capturesOpenWindow()
                #endif
                .environment(fieldNotes)
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
                .environment(team)
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
            #if os(macOS)
            SessionCommands(sessions: sessions)
            #endif
        }

        // A PR opened from the work log; one window per PR.
        WindowGroup("Pull Request", for: PullRequestReference.self) { $reference in
            if let reference {
                PullRequestWindow(reference: reference)
                    #if os(macOS)
                    .environment(sessions)
                    #endif
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
                    .environment(team)
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
                    .environment(team)
                    .environment(activity)
                    #if os(macOS)
                    .environment(sessions)
                    #endif
            }
        }
        .defaultSize(width: 1080, height: 960)
        .windowResizability(.contentMinSize)

        #if os(macOS)
        // Claude Code sessions, a tab each: the terminal, and the issue's
        // board fields or the worktrees' changes beside it. The terminals
        // outlive their tabs and the window.
        Window("Claude Code", id: SessionStore.windowID) {
            SessionsWindow()
                .capturesOpenWindow()
                .environment(sessions)
                .environment(orgs)
                .environment(auth)
                .environment(issues)
                .environment(details)
                .environment(orgConfigs)
                .environment(harness)
                .environment(team)
                .environment(projects)
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
                .environment(team)
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
