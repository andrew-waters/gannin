import SwiftUI
import AppKit

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
    @State private var sessions: SessionStore
    @NSApplicationDelegateAdaptor private var appDelegate: GanninAppDelegate
    @AppStorage(EngineerWatch.menuBarKey) private var showsMenuBar = true

    init() {
        // Before anything reads preferences, the keychain or the store.
        BundleMove.run()
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
        // Checkouts set when an org had one harness, now that it can have several.
        for (org, config) in orgConfigs.configs {
            if let primary = config.harness { SessionStore.migrateHarnessPaths(org: org, primary: primary.repo) }
        }
        // Harnesses beside the org's become projects with harnesses.
        orgConfigs.moveHarnessesToProjects()
        let sessions = SessionStore(harness: harness)
        _sessions = State(initialValue: sessions)
        GanninAppDelegate.sessions = sessions
        sessions.api = { [weak auth] in auth?.api }
        sessions.watchPullRequests()
        // Sparkle starts checking now, not when a menu is first built.
        _ = Updater.shared
        let watch = EngineerWatch.shared
        watch.api = { [weak auth] in auth?.api }
        // Review with Claude from the menu bar or a notification: in the
        // PR's org's harness, else the PR on GitHub.
        watch.startReview = { [weak sessions, weak orgConfigs] reference in
            guard let sessions, let setup = orgConfigs?.config(for: reference.org).harness(covering: [reference.repo]),
                  let path = SessionStore.harnessPath(org: reference.org, repo: setup.repo) else {
                NSWorkspace.shared.open(reference.url)
                return
            }
            let session = sessions.startReview(of: reference, harness: setup, harnessPath: path)
            if let openWindow = GanninAppDelegate.openWindow { sessions.show(session.id, with: openWindow) }
        }
        watch.start()
        TabMenuRename.shared.install()
    }

    var body: some Scene {
        // The main window. Each window (or tab) keeps its own org, section and
        // window of days in scene storage, so they're independent.
        WindowGroup(id: "main") {
            RootView()
                .joinsRequestedTab()
                .capturesOpenWindow()
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
                .environment(sessions)
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesCommand()
            }
            CommandGroup(after: .newItem) {
                NewTabCommand()
                RenameTabCommand()
            }
            SessionCommands(sessions: sessions)
        }

        // A PR opened from the work log; one window per PR.
        WindowGroup("Pull Request", for: PullRequestReference.self) { $reference in
            if let reference {
                PullRequestWindow(reference: reference)
                    .environment(sessions)
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
                    .environment(sessions)
            }
        }
        .defaultSize(width: 1080, height: 960)
        .windowResizability(.contentMinSize)

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

        // What you need to act on, from the menu bar.
        MenuBarExtra(isInserted: $showsMenuBar) {
            EngineerMenu()
                .environment(sessions)
                .environment(orgConfigs)
        } label: {
            MenuBarLabel(sessions: sessions)
        }
        .menuBarExtraStyle(.window)

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
