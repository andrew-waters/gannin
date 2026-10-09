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
    @State private var releases: ReleaseStore
    @State private var orgConfigs: OrgConfigStore
    @State private var peopleDates: PeopleDatesStore
    @State private var bankHolidays = BankHolidayStore()
    @State private var fieldNotes: FieldNotesStore
    @State private var activity: SyncActivity
    @State private var harness: HarnessStore
    @State private var team: HarnessTeamStore
    @State private var sessions: SessionStore
    @NSApplicationDelegateAdaptor private var appDelegate: GanninAppDelegate
    @AppStorage(EngineerWatch.menuBarKey) private var showsMenuBar = true

    init() {
        // Before anything reads preferences, the keychain or the store.
        BundleMove.run()
        SyncSettings.migrate()
        let auth = AuthStore()
        let activity = SyncActivity()
        _auth = State(initialValue: auth)
        _activity = State(initialValue: activity)
        let database = UserDatabase()
        _database = State(initialValue: database)
        let hidden = HiddenStore(database: database)
        _hidden = State(initialValue: hidden)
        let orgConfigs = OrgConfigStore(database: database)
        let peopleDates = PeopleDatesStore(database: database)
        _orgConfigs = State(initialValue: orgConfigs)
        _peopleDates = State(initialValue: peopleDates)
        let orgs = OrgStore(auth: auth, activity: activity, database: database)
        _orgs = State(initialValue: orgs)
        _details = State(initialValue: DetailStore(auth: auth))
        let metrics = MetricsStore(auth: auth, activity: activity)
        _metrics = State(initialValue: metrics)
        _workLog = State(initialValue: WorkLogStore(auth: auth, activity: activity))
        let issues = IssueStore(auth: auth, activity: activity)
        _issues = State(initialValue: issues)
        _projects = State(initialValue: ProjectStore(auth: auth, activity: activity))
        _actions = State(initialValue: ActionsStore(auth: auth, activity: activity))
        _releases = State(initialValue: ReleaseStore(auth: auth, activity: activity))
        let harness = HarnessStore(auth: auth)
        _harness = State(initialValue: harness)
        // Team data from the harness, for orgs that have one.
        let team = HarnessTeamStore(harness: harness)
        team.harnesses = { [weak orgConfigs] org in orgConfigs?.harnesses(for: org) ?? [] }
        orgConfigs.team = team
        peopleDates.team = team
        let fieldNotes = FieldNotesStore()
        fieldNotes.team = team
        _fieldNotes = State(initialValue: fieldNotes)
        _team = State(initialValue: team)
        // Checkouts set when an org had one harness, now that it can have several.
        for (org, config) in orgConfigs.configs {
            if let primary = config.harness { SessionStore.migrateHarnessPaths(org: org, primary: primary.repo) }
        }
        // Harnesses the old list of projects named become projects.
        orgConfigs.adoptProjects()
        let sessions = SessionStore(harness: harness)
        _sessions = State(initialValue: sessions)
        GanninAppDelegate.sessions = sessions
        sessions.api = { [weak auth] in auth?.api }
        sessions.viewerLogin = { [weak auth] in auth?.viewer?.login }
        sessions.holdsOff = { [weak auth] in auth?.shouldHoldOff ?? false }
        // An Ask's org data, written when it starts or resumes.
        sessions.orgContext = { [weak orgs, weak metrics, weak issues, weak orgConfigs, weak harness, weak peopleDates, weak hidden] org, repo in
            guard let orgs, let metrics, let issues, let orgConfigs, let harness, let peopleDates, let hidden else { return [:] }
            return OrgContext.files(org: org, harnessRepo: repo, orgs: orgs, metrics: metrics, issues: issues, configs: orgConfigs,
                                    harness: harness, peopleDates: peopleDates, hidden: hidden)
        }
        sessions.watchPullRequests()
        // Sparkle starts checking now, not when a menu is first built.
        _ = Updater.shared
        let watch = EngineerWatch.shared
        watch.api = { [weak auth] in auth?.api }
        // Review with Claude from the menu bar or a notification: in the
        // harness of the project with the PR's repo, else the PR on GitHub.
        watch.startReview = { [weak sessions, weak orgConfigs] reference in
            guard let sessions, let setup = orgConfigs?.baseConfig(for: reference.org).harness(covering: [reference.repo]),
                  let path = SessionStore.harnessPath(org: reference.org, repo: setup.repo) else {
                NSWorkspace.shared.open(reference.url)
                return
            }
            Task {
                let session = await sessions.startReview(of: reference, harness: setup, harnessPath: path)
                if let openWindow = GanninAppDelegate.openWindow { sessions.show(session.id, with: openWindow) }
            }
        }
        // Auto review: a request found starts a review in the background, in
        // the harness of the project with the PR's repo, when it's on for
        // that org.
        watch.autoReview = { [weak sessions, weak orgConfigs] reference in
            guard AutoReview.isOn(for: reference.org), let sessions,
                  let setup = orgConfigs?.baseConfig(for: reference.org).harness(covering: [reference.repo]),
                  let path = SessionStore.harnessPath(org: reference.org, repo: setup.repo) else { return false }
            if await sessions.reviewConfig(org: reference.org, harness: setup, repo: reference.repo).resolved.skips(title: reference.title) { return nil }
            return await sessions.startAutomaticReview(of: reference, harness: setup, harnessPath: path)
        }
        watch.checkWatched = { [weak sessions] in await sessions?.checkWatchedReviews() }
        watch.holdsOff = { [weak auth] in auth?.shouldHoldOff ?? false }
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
                .environment(releases)
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
            // ⌘N is New Issue; New Window moves to ⌥⌘N, as Mail's does.
            CommandGroup(replacing: .newItem) {
                NewIssueCommand()
                NewWindowCommand()
                NewTabCommand()
                RenameTabCommand()
            }
            CommandGroup(before: .sidebar) {
                CommandPaletteCommand()
                Divider()
            }
            SessionCommands(sessions: sessions)
        }

        // A PR opened from the work log; one window per PR.
        WindowGroup("Pull Request", for: PullRequestReference.self) { $reference in
            if let reference {
                PullRequestWindow(reference: reference)
                    .commandPaletteOpeningInMainWindow()
                    .environment(sessions)
                    .environment(actions)
                    .environment(releases)
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

        // Claude's explanation of a PR, a window of its own so it can sit
        // beside the PR while reading it.
        WindowGroup(id: ExplainPullRequestButton.windowID, for: ExplainPullRequestRequest.self) { $request in
            if let request {
                ExplainPullRequestWindow(reference: request.reference, walkthrough: request.walkthrough)
                    .commandPaletteOpeningInMainWindow()
            }
        }
        .defaultSize(width: 640, height: 480)

        // An issue opened from the issue metrics; one window per issue, the
        // issue on the left and its board fields on the right.
        WindowGroup("Issue", for: IssueReference.self) { $reference in
            if let reference {
                IssueWindow(reference: reference)
                    .commandPaletteOpeningInMainWindow()
                    .environment(actions)
                    .environment(releases)
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
                .commandPaletteOpeningInMainWindow()
                .capturesOpenWindow()
                .environment(sessions)
                .environment(metrics)
                .environment(workLog)
                .environment(actions)
                .environment(releases)
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
                .environment(releases)
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
    @Environment(ReleaseStore.self) private var releases
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
                releases.clear()
                harness.clear()
            }
        }
    }
}
