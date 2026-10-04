import SwiftUI

/// A page pushed onto a main window's trail.
enum DetailSelection: Hashable {
    case person(String)
    case pullRequest(String)
    case issue(String)
    case repository(String)
    case metric(MetricDrill)
    /// A PR that may be in no store here (from the work log or a board).
    case pullRequestReference(PullRequestReference)
    /// An issue from the issue history, with its board fields.
    case issueReference(IssueReference)
    /// A repo's GitHub Actions workflows, by `owner/name`.
    case actionsRepository(String)
    /// A GitHub Actions workflow, by `WorkflowRun.workflowKey`.
    case workflow(String)
    case workflowRun(Int)
    /// A job across a workflow's runs, by its name without matrix values.
    case workflowJob(workflow: String, name: String)
    /// A document in the org's harness, by path.
    case harnessDocument(String)
}

/// The sidebar's sections, in sidebar order.
enum WorkloadTab: String, CaseIterable, Identifiable {
    case inbox = "Inbox"
    case dashboard = "Dashboard"
    case issues = "Issues"
    case pullRequests = "Pull Requests"
    case people = "People"
    case repositories = "Repositories"
    case actions = "Actions"
    case investments = "Investments"
    case projects = "Projects"
    case harness = "Harness"
    case views = "Views"
    /// The morning session with CS, under Meetings.
    case prioritisation = "Prioritisation"
    /// What the team closed over its period, under Rituals.
    case recap = "Recap"
    /// The goals period by period, under Delivery.
    case scorecard = "Scorecard"
    /// What the Claude Code agents want from you.
    case agents = "Agents"
    /// Questions about the org, answered by Claude from Gannin's data.
    case ask = "Ask"
    case epics = "Epics"
    case hygiene = "Board Hygiene"
    /// The Dashboard's delivery half: PR metrics for the window.
    case delivery = "PR flow"
    /// Issue metrics; the Issues row is the lists.
    case issueFlow = "Issue flow"
    case settings = "Settings"

    var id: Self { self }

    /// As the sidebar and the window's title name it. Raw values stay as
    /// they were, since windows keep the tab they show by them.
    var title: String {
        switch self {
        case .dashboard: "Overview"
        case .projects: "Boards"
        case .actions: "CI"
        case .agents: "Waiting on You"
        default: rawValue
        }
    }

    var systemImage: String {
        switch self {
        case .inbox: "tray"
        case .dashboard: "square.grid.2x2"
        case .issues: "smallcircle.filled.circle"
        case .pullRequests: "arrow.triangle.pull"
        case .people: "person.2"
        case .repositories: "folder"
        case .actions: "play.circle"
        case .investments: "chart.pie"
        case .projects: "rectangle.split.3x1"
        case .harness: "text.book.closed"
        case .views: "square.grid.3x3"
        case .prioritisation: "list.number"
        case .recap: "calendar.badge.checkmark"
        case .scorecard: "target"
        case .agents: "questionmark.bubble"
        case .ask: "sparkle.magnifyingglass"
        case .epics: "square.stack.3d.up"
        case .hygiene: "wand.and.sparkles"
        case .delivery: "chart.line.uptrend.xyaxis"
        case .issueFlow: "chart.bar.doc.horizontal"
        case .settings: "gearshape"
        }
    }
}

/// A sidebar row: a section, a person listed under People, or a repo listed
/// under Repositories.
enum SidebarItem: Hashable {
    case tab(WorkloadTab)
    case person(String)
    case peopleView(PeopleView)
    case repository(String)
    case issueList(IssueList)
    /// Plans, requirements, findings or skills, under Harness.
    case harnessKind(HarnessKind)
    case project(Int)
    /// A saved field view, by ID.
    case fieldView(UUID)
}

/// Opens a person's view in this window, as picking them in the sidebar
/// does. Sheets and deep views use it to link to someone.
struct ShowPersonAction {
    let perform: (String) -> Void

    func callAsFunction(_ login: String) { perform(login) }
}

extension EnvironmentValues {
    @Entry var showPerson: ShowPersonAction?
}

/// The issue lists under Issues in the sidebar.
enum IssueList: String, CaseIterable {
    /// Open or closed, assigned or not, with filters for which.
    case all = "All"
    case notOnBoard = "Not on a board"

    var systemImage: String {
        switch self {
        case .all: "list.bullet"
        case .notOnBoard: "rectangle.dashed"
        }
    }

    var title: String {
        switch self {
        case .all: "All issues"
        case .notOnBoard: "Issues not on a board"
        }
    }
}

struct MainView: View {
    @Environment(OrgStore.self) private var orgs
    @Environment(HiddenStore.self) private var hidden
    @Environment(MetricsStore.self) private var metricsStore
    @Environment(OrgConfigStore.self) private var rootConfigs
    @SceneStorage(MetricsStore.windowKey) private var windowDays = MetricsStore.defaultWindowDays
    @AppStorage("excludeDrafts") private var excludeDrafts = false
    @AppStorage("showHidden") private var showHidden = false

    @SceneStorage("selectedOrg") private var selectedOrg: String?
    /// The project the window's narrowed to, by ID; empty for All. Not
    /// `selectedProject`, which is a board.
    @SceneStorage("workspace") private var workspaceID = ""
    private var workspace: UUID? {
        get { UUID(uuidString: workspaceID) }
        nonmutating set { workspaceID = newValue?.uuidString ?? "" }
    }

    /// The last org picked in any window, for a window that opens with
    /// none (macOS doesn't always restore windows, and scene storage with them).
    @AppStorage("lastOrg") private var lastOrg = ""

    /// The last project picked for an org in any window, on this Mac.
    private static func lastWorkspace(for org: String) -> UUID? {
        UserDefaults.standard.string(forKey: "lastWorkspace.\(org)").flatMap(UUID.init(uuidString:))
    }

    /// The settings as this window sees them, its project laid over them.
    private var orgConfigs: OrgConfigStore { rootConfigs.scoped(workspace) }
    /// A title chosen with Rename Tab; empty means the automatic one.
    @SceneStorage("customTitle") private var customTitle = ""
    @State private var isRenaming = false
    @State private var draftTitle = ""
    @State private var windowID = UUID()
    @Environment(ProjectStore.self) private var projectStore
    @Environment(ActionsStore.self) private var actionsStore
    @Environment(HarnessStore.self) private var harnessStore
    @Environment(\.openWindow) private var openWindow
    @State private var teamID: String?
    @SceneStorage("selectedTab") private var tab: WorkloadTab = .dashboard
    /// The drill-down trail: each entry a page pushed over the one before,
    /// the last one showing.
    @State private var path: [DetailSelection] = []
    /// A new window or tab's request, applied once its org is selected.
    @State private var request: NavigationRequest?
    /// The person picked under People in the sidebar, shown as the main view.
    @State private var person: String?
    /// The work log, threads or punchcards, picked under People.
    @State private var peopleView: PeopleView?
    /// The repo picked under Repositories in the sidebar, shown as the main view.
    @State private var repository: String?
    /// The issue list picked under Issues; nil shows the issue metrics.
    @State private var issueList: IssueList?
    /// Which of the harness's documents the Harness page lists, picked under
    /// it in the sidebar; the page reads the same scene storage.
    @SceneStorage("harnessKind") private var harnessKind: HarnessKind = .plans
    /// The board picked under Projects, by number.
    /// Kept with the window, so a relaunch comes back to the same board.
    @SceneStorage("selectedProject") private var projectNumber = 0
    private var project: Int? {
        get { projectNumber == 0 ? nil : projectNumber }
        nonmutating set { projectNumber = newValue ?? 0 }
    }
    /// The field view picked under Views.
    /// Kept with the window, so a relaunch comes back to the same view.
    @SceneStorage("selectedFieldView") private var fieldViewID = ""
    private var fieldView: UUID? {
        get { UUID(uuidString: fieldViewID) }
        nonmutating set { fieldViewID = newValue?.uuidString ?? "" }
    }
    /// No search field for now; the list filtering is kept for when it returns.
    @State private var searchText = ""

    var body: some View {
        NavigationSplitView {
            OrgSidebar(selectedOrg: $selectedOrg, workspace: Binding(get: { workspace }, set: { workspace = $0 }), selection: sidebarSelection, workload: workload)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
                .environment(\.openElsewhere, sidebarOpenElsewhere)
        } detail: {
            if let selectedOrg {
                PageStack(
                    org: selectedOrg,
                    workload: workload,
                    metrics: metrics,
                    teamID: $teamID,
                    tab: $tab,
                    person: person,
                    peopleView: peopleView,
                    repository: repository,
                    issueList: issueList,
                    project: Binding(get: { project }, set: { project = $0 }),
                    fieldView: Binding(get: { fieldView }, set: { fieldView = $0 }),
                    path: $path,
                    sidebar: sidebarSelection.wrappedValue ?? .tab(tab),
                    rootTitle: rootTitle,
                    titles: titles,
                    searchText: searchText
                )
                // Pages start again on another project.
                .id("\(selectedOrg)|\(workspaceID)")
            } else {
                ContentUnavailableView(
                    "Pick an organisation",
                    systemImage: "building.2",
                    description: Text("Choose one with the switcher at the bottom of the sidebar.")
                )
            }
        }
        // The title (and so the tab) names what the window shows; the org
        // sits underneath as the subtitle.
        .navigationTitle(customTitle.isEmpty ? automaticTitle : customTitle)
        .windowSubtitle(selectedOrg.map { orgs.org(login: $0)?.displayName ?? $0 } ?? "")
        .focusedSceneValue(\.renameTab, RenameTabAction(window: windowID, perform: startRenaming))
        .investmentPrompt()
        .environment(orgConfigs)
        .environment(\.showPerson, ShowPersonAction { login in sidebarSelection.wrappedValue = .person(login) })
        .environment(\.showSidebarItem, ShowSidebarAction { item in sidebarSelection.wrappedValue = item })
        .background(WindowAccessor { window in
            TabMenuRename.shared.register(window, action: startRenaming)
        })
        .alert("Rename Tab", isPresented: $isRenaming) {
            TextField("Title", text: $draftTitle)
            Button("Rename") { customTitle = draftTitle.trimmingCharacters(in: .whitespaces) }
                .keyboardShortcut(.defaultAction)
            Button("Use Automatic Title") { customTitle = "" }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Leave it empty to name the tab after what it shows.")
        }
        .task { await orgs.loadOrgs() }
        .onAppear(perform: claimRequest)
        .onChange(of: selectedOrg) {
            // The project last picked for this org, until a request says otherwise.
            workspace = selectedOrg.flatMap(Self.lastWorkspace(for:))
            if let selectedOrg { lastOrg = selectedOrg }
            teamID = nil
            person = nil
            peopleView = nil
            repository = nil
            issueList = nil
            project = nil
            fieldView = nil
            path = []
            if let request, request.org == selectedOrg { apply(request) }
        }
        .onChange(of: orgs.orgs, initial: true) {
            if selectedOrg == nil {
                // The last one picked, else an org before your own account,
                // unless that's starred.
                selectedOrg = (orgs.orgs.first { $0.login == lastOrg } ?? orgs.starredOrgs.first ?? orgs.orgs.first { !$0.isPersonal } ?? orgs.orgs.first)?.login
            }
        }
        .onChange(of: workspaceID) {
            if let selectedOrg { UserDefaults.standard.set(workspaceID, forKey: "lastWorkspace.\(selectedOrg)") }
        }
    }

    /// Takes the request this window was opened for, if any: its org, then
    /// (once that's selected) its sidebar item and trail.
    private func claimRequest() {
        guard let pending = WindowRequest.pending else { return }
        WindowRequest.pending = nil
        if selectedOrg == pending.org {
            apply(pending)
        } else {
            request = pending
            selectedOrg = pending.org
        }
    }

    private func apply(_ pending: NavigationRequest) {
        request = nil
        workspace = pending.workspace
        sidebarSelection.wrappedValue = pending.sidebar
        path = pending.path
    }

    /// Sidebar rows open in a new tab or window on the same org.
    private var sidebarOpenElsewhere: OpenElsewhereAction? {
        guard let selectedOrg else { return nil }
        return OpenElsewhereAction(
            open: { destination, placement in
                WindowRequest.open(NavigationRequest(org: selectedOrg, sidebar: .tab(tab), path: [destination], workspace: workspace), placement: placement, openWindow: openWindow)
            },
            openSidebar: { item, placement in
                WindowRequest.open(NavigationRequest(org: selectedOrg, sidebar: item, path: [], workspace: workspace), placement: placement, openWindow: openWindow)
            }
        )
    }

    private func startRenaming() {
        draftTitle = customTitle.isEmpty ? automaticTitle : customTitle
        isRenaming = true
    }

    /// What the window shows: the page on top of the trail, else the
    /// section or what's picked beneath it in the sidebar.
    private var automaticTitle: String {
        guard selectedOrg != nil else { return "Gannin" }
        if let last = path.last { return titles.title(last) }
        return rootTitle
    }

    private var titles: PageTitles {
        PageTitles(
            workload: workload,
            metrics: metrics,
            actions: selectedOrg.flatMap(actionsStore.history(for:)),
            harness: selectedOrg.flatMap { org in harnessStore.combined(org: org, orgConfigs.config(for: org).harnesses) }
        )
    }

    /// The section, or the person, repo, issue list or board picked beneath it.
    private var rootTitle: String {
        guard let selectedOrg else { return "Gannin" }
        switch tab {
        case .people:
            return person.map { login in workload?.load(for: login)?.person.displayName ?? login } ?? peopleView?.rawValue ?? "People"
        case .repositories:
            return repository.map { $0.split(separator: "/").last.map(String.init) ?? $0 } ?? "Repositories"
        case .issues:
            return issueList?.title ?? "Issues"
        case .harness:
            return harnessKind.rawValue
        case .projects:
            return project.map { number in projectStore.boardLists[selectedOrg]?.first { $0.number == number }?.title ?? "Project \(number)" } ?? "Projects"
        case .views:
            return fieldView.flatMap { orgConfigs.fieldView($0, in: selectedOrg)?.name } ?? "Views"
        default:
            return tab.title
        }
    }

    /// The section, or the person or repo picked beneath it.
    private var sidebarSelection: Binding<SidebarItem?> {
        Binding {
            if tab == .people, let person { return .person(person) }
            if tab == .people, let peopleView { return .peopleView(peopleView) }
            if tab == .repositories, let repository { return .repository(repository) }
            if tab == .issues, let issueList { return .issueList(issueList) }
            // The Harness row has no page of its own: it's one of its kinds.
            if tab == .harness { return .harnessKind(harnessKind) }
            if tab == .projects, let project { return .project(project) }
            if tab == .views, let fieldView { return .fieldView(fieldView) }
            return .tab(tab)
        } set: { item in
            guard let item else { return }
            person = nil
            peopleView = nil
            repository = nil
            issueList = nil
            project = nil
            fieldView = nil
            path = []
            switch item {
            case .tab(let newTab):
                tab = newTab
            case .person(let login):
                tab = .people
                person = login
            case .peopleView(let view):
                tab = .people
                peopleView = view
            case .repository(let name):
                tab = .repositories
                repository = name
            case .issueList(let list):
                tab = .issues
                issueList = list
            case .harnessKind(let kind):
                tab = .harness
                harnessKind = kind
            case .project(let number):
                tab = .projects
                project = number
            case .fieldView(let id):
                tab = .views
                fieldView = id
            }
        }
    }

    private var workload: Workload? {
        guard let selectedOrg, let snapshot = orgs.snapshot(for: selectedOrg) else { return nil }
        let team = teamID.flatMap { id in snapshot.teams.first { $0.id == id } }
        let options = Workload.Options(
            excludeDrafts: excludeDrafts,
            hidden: hidden.keys,
            showHidden: showHidden,
            config: config(for: selectedOrg)
        )
        return Workload(snapshot: snapshot, team: team, options: options)
    }

    /// The org's exclusions plus anyone hidden with the old per-person Hide,
    /// so the workload and the stats leave out the same people.
    private func config(for org: String) -> OrgConfig {
        var config = orgConfigs.config(for: org)
        let prefix = HiddenStore.personKey("")
        for key in hidden.keys where key.hasPrefix(prefix) {
            config.excludedAuthors.insert(String(key.dropFirst(prefix.count)))
        }
        return config
    }

    private var metrics: OrgMetrics? {
        guard let selectedOrg, let history = metricsStore.history(for: selectedOrg) else { return nil }
        let snapshot = orgs.snapshot(for: selectedOrg)
        let team = teamID.flatMap { id in snapshot?.teams.first { $0.id == id } }
        return OrgMetrics(
            history: history,
            window: MetricsWindow(code: windowDays),
            team: team,
            members: snapshot?.members ?? [],
            hidden: showHidden ? [] : hidden.keys,
            config: config(for: selectedOrg),
            openPullRequests: workload?.openPullRequests ?? []
        )
    }
}

// MARK: - Page stack

/// Page names, for the window title and the breadcrumbs.
struct PageTitles {
    let workload: Workload?
    let metrics: OrgMetrics?
    let actions: ActionsHistory?
    let harness: HarnessIndex?

    func title(_ item: DetailSelection) -> String {
        switch item {
        case .person(let login):
            return workload?.load(for: login)?.person.displayName ?? login
        case .pullRequest(let id):
            if let pr = workload?.pullRequest(id: id) { return "\(pr.repo)#\(pr.number)" }
            if let pr = metrics?.pullRequest(id: id) { return "\(pr.repo)#\(pr.number)" }
            return "Pull request"
        case .issue(let id):
            return workload?.issue(id: id).map { "\($0.repo)#\($0.number)" } ?? "Issue"
        case .pullRequestReference(let reference):
            return "\(reference.repo)#\(reference.number)"
        case .issueReference(let reference):
            return "\(reference.repo)#\(reference.number)"
        case .repository(let name):
            return name.split(separator: "/").last.map(String.init) ?? name
        case .metric(let drill):
            if case .personStats(let login) = drill,
               let person = metrics?.people.first(where: { $0.id == login })?.person
                ?? metrics?.reviewers.first(where: { $0.id == login })?.person {
                return person.displayName
            }
            return drill.title
        case .actionsRepository(let repo):
            return repo.split(separator: "/").last.map(String.init) ?? repo
        case .workflow(let key):
            return actions?.runs.values.first { $0.workflowKey == key }?.name ?? "Workflow"
        case .workflowRun(let id):
            return actions?.runs[id].map { "\($0.name) #\($0.runNumber)" } ?? "Run"
        case .workflowJob(_, let name):
            return name
        case .harnessDocument(let path):
            return harness?.document(at: path)?.title ?? path.split(separator: "/").last.map(String.init) ?? path
        }
    }
}

/// The sidebar's page with the trail pushed over it: only the last page
/// shows, full width, under breadcrumbs back to each level, with Back in
/// the toolbar (⌘[, Esc). Each level can push onto the trail, and open
/// what it links to in a new tab or window with the trail that led there.
private struct PageStack: View {
    @Environment(ActionsStore.self) private var actionsStore
    @Environment(OrgConfigStore.self) private var configs
    @Environment(IssueStore.self) private var issueStore
    @Environment(\.openWindow) private var openWindow
    @SceneStorage(MetricsStore.windowKey) private var windowDays = MetricsStore.defaultWindowDays

    let org: String
    let workload: Workload?
    let metrics: OrgMetrics?
    @Binding var teamID: String?
    @Binding var tab: WorkloadTab
    let person: String?
    let peopleView: PeopleView?
    let repository: String?
    let issueList: IssueList?
    @Binding var project: Int?
    @Binding var fieldView: UUID?
    @Binding var path: [DetailSelection]
    /// What the sidebar has picked, for new windows opened from here.
    let sidebar: SidebarItem
    let rootTitle: String
    let titles: PageTitles
    let searchText: String

    /// The PRs, issues and harness documents open in drawers over the
    /// page, the top one last. A link in a drawer opens another on top.
    @State private var drawers: [DetailSelection] = []
    /// New Issue, while its sheet is open.
    @State private var newIssue: NewIssueContext?
    @State private var stackID = UUID()

    var body: some View {
        Group {
            if let last = path.last {
                VStack(spacing: 0) {
                    breadcrumbs
                    Divider()
                    page(for: last, index: path.count - 1)
                        .id(last)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .environment(\.navigate, navigate(at: path.count))
                        .environment(\.openAsPage, push(at: path.count))
                        .environment(\.openElsewhere, openElsewhere(trail: path))
                }
            } else {
                OrgWorkloadView(
                    org: org,
                    workload: workload,
                    metrics: metrics,
                    teamID: $teamID,
                    tab: $tab,
                    person: person,
                    peopleView: peopleView,
                    repository: repository,
                    issueList: issueList,
                    project: $project,
                    fieldView: $fieldView,
                    selection: selection(at: 0),
                    searchText: searchText
                )
                .environment(\.navigate, navigate(at: 0))
                .environment(\.openAsPage, push(at: 0))
                .environment(\.openElsewhere, openElsewhere(trail: []))
            }
        }
        .overlay(alignment: .trailing) { drawerOverlay }
        .environment(\.newIssue, newIssueAction)
        .focusedSceneValue(\.newIssue, newIssueAction)
        .sheet(item: $newIssue) { context in
            NewIssueSheet(context: context) { created in
                // The new issue, in a drawer over the page.
                if let created { navigate(at: path.count)(.issueReference(created)) }
            }
        }
        .animation(.snappy(duration: 0.25), value: drawers)
        .onChange(of: path) { drawers = [] }
        .toolbar {
            if !path.isEmpty {
                ToolbarItem(placement: .navigation) { backButton }
                if usesWindow(path.last) {
                    ToolbarItem { windowPicker }
                }
            }
        }
        .onEscape {
            if !drawers.isEmpty {
                drawers.removeLast()
            } else if !path.isEmpty {
                path.removeLast()
            }
        }
        .environment(\.currentOrg, org)
    }

    /// New Issue from anywhere in the window: what's asked for, else the
    /// board the page shows.
    private var newIssueAction: NewIssueAction {
        NewIssueAction(window: stackID) { context in
            newIssue = context ?? NewIssueContext(org: org, board: path.isEmpty && tab == .projects ? project : nil)
        }
    }

    // MARK: Chrome

    private var backButton: some View {
        Button {
            path.removeLast()
        } label: {
            Label("Back", systemImage: "chevron.left")
        }
        .keyboardShortcut("[", modifiers: .command)
        .help("Back to \(path.count > 1 ? titles.title(path[path.count - 2]) : rootTitle) (⌘[)")
    }

    /// Root › page › page, each a link back to its level.
    private var breadcrumbs: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                Button(rootTitle) { path = [] }.linkButton()
                ForEach(Array(path.enumerated()), id: \.offset) { index, item in
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                    if index == path.count - 1 {
                        Text(titles.title(item)).foregroundStyle(.secondary)
                    } else {
                        Button(titles.title(item)) { path = Array(path.prefix(through: index)) }.linkButton()
                    }
                }
            }
            .font(.callout)
            .lineLimit(1)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
        .scrollIndicators(.never)
    }

    /// Pages whose numbers follow the metrics window keep its picker.
    private func usesWindow(_ item: DetailSelection?) -> Bool {
        switch item {
        case .metric, .actionsRepository, .workflow, .workflowJob: true
        default: false
        }
    }

    private var windowPicker: some View {
        MetricsWindowPicker(code: $windowDays)
    }

    // MARK: Navigation

    /// The page selected from the level at `depth`: reading gives the page
    /// pushed over it, writing replaces everything above it.
    private func selection(at depth: Int) -> Binding<DetailSelection?> {
        Binding {
            path.indices.contains(depth) ? path[depth] : nil
        } set: { newValue in
            guard let newValue else {
                path = Array(path.prefix(depth))
                return
            }
            navigate(at: depth)(newValue)
        }
    }

    /// Pushes from the level at `depth`; a page already in the trail below
    /// is gone back to instead.
    /// PRs, issues and harness documents open in a drawer, everywhere in
    /// the app; anything else is pushed from `depth` (closing the drawers).
    private func navigate(at depth: Int) -> NavigateAction {
        NavigateAction { destination in
            if Self.opensInDrawer(destination) {
                drawers = [destination]
            } else {
                drawers = []
                push(at: depth)(destination)
            }
        }
    }

    /// From the drawer at `level`: another drawer on top of it (or back to
    /// one below, if it's already open there); a page closes them all.
    private func navigateInDrawer(at level: Int) -> NavigateAction {
        NavigateAction { destination in
            if Self.opensInDrawer(destination) {
                if let open = drawers.prefix(level + 1).firstIndex(of: destination) {
                    drawers = Array(drawers.prefix(through: open))
                } else {
                    drawers = Array(drawers.prefix(level + 1)) + [destination]
                }
            } else {
                drawers = []
                push(at: path.count)(destination)
            }
        }
    }

    static func opensInDrawer(_ destination: DetailSelection) -> Bool {
        switch destination {
        case .issue, .issueReference, .pullRequest, .pullRequestReference, .harnessDocument: true
        default: false
        }
    }

    /// Pushes from the level at `depth`; a page already in the trail below
    /// is gone back to instead.
    private func push(at depth: Int) -> NavigateAction {
        NavigateAction { destination in
            if let index = path.prefix(depth).firstIndex(of: destination) {
                path = Array(path.prefix(through: index))
            } else {
                path = Array(path.prefix(depth)) + [destination]
            }
        }
    }

    /// Opens elsewhere from the level whose trail is `trail`. A PR or issue
    /// in a new window gets its own window; anything else is a main window
    /// (or tab) on the same trail plus the page.
    private func openElsewhere(trail: [DetailSelection]) -> OpenElsewhereAction {
        OpenElsewhereAction(
            open: { destination, placement in
                if placement == .window, openOwnWindow(destination) { return }
                WindowRequest.open(NavigationRequest(org: org, sidebar: sidebar, path: trail + [destination], workspace: configs.workspace), placement: placement, openWindow: openWindow)
            },
            openSidebar: { item, placement in
                WindowRequest.open(NavigationRequest(org: org, sidebar: item, path: [], workspace: configs.workspace), placement: placement, openWindow: openWindow)
            }
        )
    }

    /// Opens a PR or issue in the window of its own. False for anything else.
    private func openOwnWindow(_ destination: DetailSelection) -> Bool {
        switch destination {
        case .pullRequestReference(let reference):
            openWindow(value: reference)
        case .issueReference(let reference):
            openWindow(value: reference)
        case .pullRequest(let id):
            if let pr = workload?.pullRequest(id: id) {
                openWindow(value: PullRequestReference(org: org, id: pr.id, number: pr.number, title: pr.title, repo: pr.repo, url: pr.url))
            } else if let pr = metrics?.pullRequest(id: id) {
                openWindow(value: PullRequestReference(org: org, id: pr.id, number: pr.number, title: pr.title, repo: pr.repo, url: pr.url))
            } else {
                return false
            }
        case .issue(let id):
            guard let issue = workload?.issue(id: id) else { return false }
            openWindow(value: IssueReference(org: org, id: issue.id, number: issue.number, title: issue.title, repo: issue.repo, url: issue.url))
        default:
            return false
        }
        return true
    }

    // MARK: Drawer

    private static let drawerShape = UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12, style: .continuous)

    /// How far each drawer below the top one shows past its left edge.
    private static let drawerPeek: CGFloat = 28

    /// Over the right of the page, as GitHub's drawer: a click outside
    /// closes them all, Esc the top one. Those underneath show their left
    /// edge, dimmed; clicking it goes back to that one.
    @ViewBuilder
    private var drawerOverlay: some View {
        if !drawers.isEmpty {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { drawers = [] }
            GeometryReader { geometry in
                // Room for the edges of those underneath, up to three.
                let peeks = CGFloat(min(drawers.count - 1, 3)) * Self.drawerPeek
                let width = min(max(700, geometry.size.width * 0.7), max(geometry.size.width - 80 - peeks, 480))
                ZStack(alignment: .trailing) {
                    ForEach(Array(drawers.enumerated()), id: \.offset) { level, item in
                        let depth = drawers.count - 1 - level
                        if depth <= 3 {
                            drawerContent(item, level: level, isWide: width >= 900)
                                // Only the top one takes Esc and other shortcuts.
                                .disabled(depth > 0)
                                .environment(\.navigate, navigateInDrawer(at: level))
                                .environment(\.openAsPage, NavigateAction { destination in
                                    drawers = []
                                    push(at: path.count)(destination)
                                })
                                .environment(\.openElsewhere, openElsewhere(trail: path))
                                .frame(width: width)
                                .frame(maxHeight: .infinity)
                                .background(Color.windowBackground, in: Self.drawerShape)
                                .clipShape(Self.drawerShape)
                                .overlay {
                                    if depth > 0 {
                                        // Underneath: dimmed, and a click goes back to it.
                                        Self.drawerShape.fill(.black.opacity(0.18))
                                            .contentShape(Self.drawerShape)
                                            .onTapGesture { drawers = Array(drawers.prefix(through: level)) }
                                            .help("Back to \(titles.title(item))")
                                    }
                                }
                                .overlay { Self.drawerShape.strokeBorder(Color.separatorLine) }
                                .shadow(color: .black.opacity(depth == 0 ? 0.25 : 0.12), radius: 24, x: -4)
                                .offset(x: -CGFloat(depth) * Self.drawerPeek)
                                .transition(.move(edge: .trailing))
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            }
            .transition(.move(edge: .trailing))
        }
    }

    /// Done (or Esc) in a drawer closes it and any above it, back to the
    /// one beneath.
    private func closeDrawer(_ level: Int) {
        drawers = Array(drawers.prefix(level))
    }

    /// Above a drawer opened from another: back to the one beneath.
    @ViewBuilder
    private func drawerBack(_ level: Int) -> some View {
        if level > 0 {
            HStack {
                Button {
                    drawers = Array(drawers.prefix(level))
                } label: {
                    Label("Back to \(titles.title(drawers[level - 1]))", systemImage: "chevron.left")
                        .lineLimit(1)
                }
                .linkButton()
                Spacer()
            }
            .font(.callout)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Divider()
        }
    }

    /// An issue as the views' drawer shows it (timeline and board fields
    /// beside the description); a PR or harness document as its page, under
    /// Open as Page, Open in Window and Done.
    @ViewBuilder
    private func drawerContent(_ item: DetailSelection, level: Int, isWide: Bool) -> some View {
        VStack(spacing: 0) {
            drawerBack(level)
            if let reference = issueReference(item) {
                let workflow = configs.config(for: org).workflow
                let history = issueStore.history(for: org)
                let signals = history?.issues[reference.id].map { FieldContext(board: workflow.projectNumber, workflow: workflow, history: history).signals($0) }
                IssueSheet(reference: reference, signals: signals, isWide: isWide) { closeDrawer(level) }
                    .id(reference.id)
            } else if case .harnessDocument(let path) = item {
                // Its own header, as an issue's.
                HarnessDocumentPage(org: org, path: path) { closeDrawer(level) }
                    .id(path)
            } else {
                HStack(spacing: 10) {
                    if let reference = pullRequestReference(item) {
                        ReviewWithClaudeButton(reference: reference)
                    }
                    Spacer()
                    Button("Open as Page") {
                        drawers = []
                        push(at: path.count)(item)
                    }
                    Button("Open in Window") {
                        drawers = []
                        if !openOwnWindow(item) {
                            WindowRequest.open(NavigationRequest(org: org, sidebar: sidebar, path: path + [item], workspace: configs.workspace), placement: .window, openWindow: openWindow)
                        }
                    }
                    Button("Done") { closeDrawer(level) }
                        .keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                Divider()
                page(for: item, index: path.count)
                    .id(item)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// The PR behind a drawer item, when it's one.
    private func pullRequestReference(_ item: DetailSelection) -> PullRequestReference? {
        switch item {
        case .pullRequestReference(let reference):
            return reference
        case .pullRequest(let id):
            guard let pr = workload?.openPullRequests.first(where: { $0.id == id }) else { return nil }
            return PullRequestReference(org: org, id: pr.id, number: pr.number, title: pr.title, repo: pr.repo, url: pr.url)
        default:
            return nil
        }
    }

    /// The issue behind a drawer item, when it's one.
    private func issueReference(_ item: DetailSelection) -> IssueReference? {
        switch item {
        case .issueReference(let reference):
            return reference
        case .issue(let id):
            if let record = issueStore.history(for: org)?.issues[id] { return IssueReference(org: org, record: record) }
            guard let issue = workload?.issue(id: id) else { return nil }
            return IssueReference(org: org, id: issue.id, number: issue.number, title: issue.title, repo: issue.repo, url: issue.url)
        default:
            return nil
        }
    }

    // MARK: Pages

    private var actions: ActionsMetrics? {
        actionsStore.history(for: org).map { ActionsMetrics(history: $0, window: MetricsWindow(code: windowDays), config: configs.config(for: org)) }
    }

    @ViewBuilder
    private func page(for item: DetailSelection, index: Int) -> some View {
        let selection = selection(at: index + 1)
        let push = navigate(at: index + 1)
        switch item {
        case .person(let login):
            if let workload, let load = workload.load(for: login) {
                PersonColumn(load: load, workload: workload, selection: selection)
            } else {
                unavailable
            }
        case .pullRequest(let id):
            pullRequest(id: id, reference: nil, selection: selection)
        case .pullRequestReference(let reference):
            pullRequest(id: reference.id, reference: reference, selection: selection)
        case .issue(let id):
            if let workload, let issue = workload.issue(id: id) {
                IssueColumn(issue: issue, workload: workload, selection: selection)
            } else {
                unavailable
            }
        case .issueReference(let reference):
            IssueWindow(reference: reference, isEmbedded: true)
        case .repository(let name):
            if let workload, let repository = workload.repository(named: name) {
                RepositoryColumn(repository: repository, workload: workload, selection: selection)
            } else {
                unavailable
            }
        case .metric(let drill):
            MetricColumn(drill: drill, workload: workload, metrics: metrics, selection: selection)
        case .actionsRepository(let name):
            if let actions, let repo = actions.repo(name) {
                ActionsRepositoryPage(org: org, repo: repo, metrics: actions, navigate: push.perform)
            } else {
                gone("No workflow runs in this repository in \(MetricsWindow(code: windowDays).span).")
            }
        case .workflow(let key):
            if let actions, let workflow = actions.workflow(key) {
                WorkflowPage(org: org, workflow: workflow, windowStart: actions.windowStart, hasPrevious: actions.hasPrevious, navigate: push.perform)
            } else {
                gone("No runs of this workflow in \(MetricsWindow(code: windowDays).span).")
            }
        case .workflowRun(let id):
            if let run = actionsStore.history(for: org)?.runs[id] {
                RunPage(org: org, run: run, navigate: push.perform)
            } else {
                gone("This run is no longer stored.")
            }
        case .workflowJob(let key, let name):
            if let workflow = actions?.workflow(key) {
                JobPage(org: org, workflow: workflow, name: name, navigate: push.perform)
            } else {
                gone("No runs of this workflow in \(MetricsWindow(code: windowDays).span).")
            }
        case .harnessDocument(let path):
            HarnessDocumentPage(org: org, path: path)
        }
    }

    /// The richest view of a PR: from the workload, else the merged-PR
    /// history, else what the reference carries plus the work log.
    @ViewBuilder
    private func pullRequest(id: String, reference: PullRequestReference?, selection: Binding<DetailSelection?>) -> some View {
        if let workload, let pr = workload.pullRequest(id: id) {
            PullRequestColumn(pr: pr, workload: workload, timing: metrics?.pullRequest(id: id), selection: selection)
        } else if let pr = metrics?.pullRequest(id: id) {
            MetricPullRequestColumn(pr: pr, selection: selection)
        } else if let reference {
            PullRequestWindow(reference: reference, isEmbedded: true)
        } else {
            unavailable
        }
    }

    private var unavailable: some View {
        ContentUnavailableView(
            "Not in this view",
            systemImage: "eye.slash",
            description: Text("It's hidden, filtered out, or not part of this org's snapshot.")
        )
    }

    private func gone(_ message: String) -> some View {
        ContentUnavailableView("Not in this window", systemImage: "clock.arrow.circlepath", description: Text(message))
    }
}

// MARK: - Sidebar

/// The sidebar, laid out as Mail's is: the org's pages first, then People,
/// Planning and Claude Code as sections that hide and show from their
/// headers, with what's under a row in a disclosure group, so the system
/// draws the triangles, indents and badges.
struct OrgSidebar: View {
    @Environment(OrgStore.self) private var orgs
    @Environment(IssueStore.self) private var issueStore
    @Binding var selectedOrg: String?
    @Binding var workspace: UUID?
    @Binding var selection: SidebarItem?
    let workload: Workload?
    @AppStorage("sidebarPeopleExpanded") private var peopleExpanded = true
    @AppStorage("sidebarWorkExpanded") private var workExpanded = true
    @AppStorage("sidebarDeliveryExpanded") private var deliveryExpanded = true
    @AppStorage("sidebarRitualsExpanded") private var meetingsExpanded = false
    @AppStorage("sidebarSessionsExpanded") private var sessionsExpanded = true
    @AppStorage("sidebarAllExpanded") private var allExpanded = false
    /// Team IDs opened under People, comma separated.
    @AppStorage("sidebarExpandedTeams") private var expandedTeamIDs = ""
    @AppStorage("sidebarRepositoriesExpanded") private var repositoriesExpanded = false
    @AppStorage("sidebarIssuesExpanded") private var issuesExpanded = true
    @AppStorage("sidebarHarnessSectionExpanded") private var harnessExpanded = false
    @Environment(HarnessStore.self) private var harnessStore
    @AppStorage("sidebarProjectsExpanded") private var projectsExpanded = true
    @AppStorage("sidebarViewsExpanded") private var viewsExpanded = true
    @Environment(ProjectStore.self) private var projectStore
    @Environment(OrgConfigStore.self) private var configs
    @Environment(AuthStore.self) private var auth
    @Environment(SessionStore.self) private var sessions

    /// Documents of the kind that follow the harness's standard, as the page
    /// lists them.
    private func harnessCount(_ kind: HarnessKind) -> Int {
        guard let selectedOrg, let index = harnessStore.combined(org: selectedOrg, configs.config(for: selectedOrg).harnesses) else { return 0 }
        return index.documents(kind).count(where: \.followsStandard)
    }

    /// The Harness section only shows once there's a harness in view: the
    /// project's, else any of the org's.
    private var hasHarness: Bool {
        selectedOrg.map { !configs.config(for: $0).harnesses.isEmpty } ?? false
    }

    var body: some View {
        List(selection: $selection) {
            if let selectedOrg {
                // What needs me, and quick answers.
                Section {
                    row(.inbox)
                    row(.ask)
                    row(.dashboard)
                }

                // What's in flight and what's next.
                Section("Work", isExpanded: $workExpanded) {
                    row(.pullRequests)
                    DisclosureGroup(isExpanded: $issuesExpanded) {
                        ForEach(IssueList.allCases, id: \.self) { list in
                            Label(list.rawValue, systemImage: list.systemImage)
                                .badge(issueCount(list))
                                .tag(SidebarItem.issueList(list))
                                .contextMenu { OpenElsewhereItems(sidebar: .issueList(list)) }
                        }
                    } label: {
                        row(.issues)
                    }
                    row(.epics)
                    DisclosureGroup(isExpanded: $projectsExpanded) {
                        ForEach(projectStore.boards(org: selectedOrg, repo: configs.config(for: selectedOrg).boardsRepo)) { board in
                            Label(board.title, systemImage: "rectangle.split.3x1")
                                .lineLimit(1)
                                .tag(SidebarItem.project(board.number))
                                .contextMenu { OpenElsewhereItems(sidebar: .project(board.number)) }
                        }
                    } label: {
                        row(.projects)
                    }
                    DisclosureGroup(isExpanded: $viewsExpanded) {
                        ForEach(configs.config(for: selectedOrg).fieldViews) { view in
                            Label(view.name, systemImage: WorkloadTab.views.systemImage)
                                .lineLimit(1)
                                .tag(SidebarItem.fieldView(view.id))
                                .contextMenu {
                                    OpenElsewhereItems(sidebar: .fieldView(view.id))
                                    Button("Duplicate") {
                                        var copy = view
                                        copy.id = UUID()
                                        copy.name = "\(view.name) copy"
                                        configs.saveFieldView(copy, in: selectedOrg)
                                    }
                                    Button("Delete", role: .destructive) {
                                        if selection == .fieldView(view.id) { selection = .tab(.views) }
                                        configs.deleteFieldView(view.id, in: selectedOrg)
                                    }
                                }
                        }
                    } label: {
                        row(.views)
                    }
                }

                // How it's going.
                Section("Delivery", isExpanded: $deliveryExpanded) {
                    row(.scorecard)
                    row(.delivery)
                    row(.issueFlow)
                    row(.investments)
                    row(.actions)
                    DisclosureGroup(isExpanded: $repositoriesExpanded) {
                        ForEach(repositories) { repository in
                            repositoryRow(repository)
                        }
                    } label: {
                        row(.repositories)
                    }
                }

                // Who's doing what.
                Section("Team", isExpanded: $peopleExpanded) {
                    peopleRows
                    peopleViewRow(.activity)
                    peopleViewRow(.timeOff)
                }

                // The meetings Gannin runs.
                Section("Rituals", isExpanded: $meetingsExpanded) {
                    peopleViewRow(.standup)
                    row(.recap)
                    row(.prioritisation)
                    row(.hygiene)
                }

                // The team's knowledge.
                if hasHarness {
                    Section("Harness", isExpanded: $harnessExpanded) {
                        ForEach(HarnessKind.allCases) { kind in
                            Label(kind.rawValue, systemImage: kind.systemImage)
                                .badge(harnessCount(kind))
                                .tag(SidebarItem.harnessKind(kind))
                                .contextMenu { OpenElsewhereItems(sidebar: .harnessKind(kind)) }
                        }
                    }
                }

                Section("Agents", isExpanded: $sessionsExpanded) {
                    row(.agents)
                    SessionSidebarRows(org: selectedOrg)
                }

            }
            if let error = orgs.errors["orgs"] {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
        }
        .task(id: selectedOrg) {
            if let selectedOrg { await projectStore.loadBoards(org: selectedOrg) }
        }
        .task(id: selectedOrg.flatMap { configs.config(for: $0).boardsRepo }) {
            if let selectedOrg, let repo = configs.config(for: selectedOrg).boardsRepo {
                await projectStore.loadRepoBoards(org: selectedOrg, repo: repo)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if let selectedOrg {
                    HarnessPendingRow(org: selectedOrg)
                    SyncFooter(org: selectedOrg)
                        .loadsHarness(org: selectedOrg)
                }
                SidebarFooter(selectedOrg: $selectedOrg, workspace: $workspace, selection: $selection)
            }
            // Its own material, so rows scrolled under it (and the sync
            // panel sliding up over them) don't show through.
            .background(.bar)
        }
    }

    /// A section's own row: its page, with its count.
    private func row(_ tab: WorkloadTab) -> some View {
        Label(tab.title, systemImage: tab.systemImage)
            .badge(badge(for: tab))
            .tag(SidebarItem.tab(tab))
            .contextMenu { OpenElsewhereItems(sidebar: .tab(tab)) }
    }

    private func issueCount(_ list: IssueList) -> Int {
        switch list {
        // Open ones.
        case .all: (workload?.assignedIssues.count ?? 0) + (workload?.unassignedIssues.count ?? 0)
        // Open ones on no board, once the issue history has loaded.
        case .notOnBoard: selectedOrg.flatMap { issueStore.history(for: $0) }?.issues.values.filter { $0.isOpen && $0.projectFields.isEmpty }.count ?? 0
        }
    }

    /// Repos with open PRs or issues, by name.
    private var repositories: [RepositoryLoad] {
        (workload?.repositories ?? [])
            .filter { !$0.openPullRequests.isEmpty || !$0.issues.isEmpty }
            .sorted { $0.shortName.localizedCaseInsensitiveCompare($1.shortName) == .orderedAscending }
    }

    /// Its name, with open PRs as the count and the rest in the tooltip.
    private func repositoryRow(_ repository: RepositoryLoad) -> some View {
        Label(repository.shortName, systemImage: "folder")
            .lineLimit(1)
            .badge(repository.openPullRequests.count)
            .help(summary([
                count(repository.openPullRequests.count, "PR", "PRs"),
                count(repository.issues.count, "issue", "issues"),
            ], stale: repository.stalePullRequests.count))
            .contextMenu {
                OpenElsewhereItems(sidebar: .repository(repository.name))
                RepositoryMenu(repository: repository.name, org: selectedOrg ?? "")
            }
            .tag(SidebarItem.repository(repository.name))
    }

    private func count(_ n: Int, _ singular: String, _ plural: String) -> String? {
        n == 0 ? nil : "\(n) \(n == 1 ? singular : plural)"
    }

    /// "3 PRs, 2 issues, 1 stale", for a tooltip.
    private func summary(_ parts: [String?], stale: Int) -> String {
        let parts = parts.compactMap { $0 } + (stale > 0 ? ["\(stale) stale"] : [])
        return parts.isEmpty ? "Nothing in flight" : parts.joined(separator: ", ")
    }

    /// Avatar and name, with what they have in flight as the count and the
    /// breakdown in the tooltip.
    private func personRow(_ load: PersonLoad) -> some View {
        Label {
            Text(load.person.displayName).lineLimit(1)
        } icon: {
            Avatar(url: load.person.avatarUrl, size: 18)
        }
        .badge(load.pullRequests.count + load.reviewRequests.count + load.activeIssues.count)
        .help(summary([
            count(load.pullRequests.count, "PR", "PRs"),
            count(load.reviewRequests.count, "review", "reviews"),
            count(load.activeIssues.count, "issue", "issues"),
        ], stale: load.stalePullRequests.count))
        .excludable(login: load.person.login, org: selectedOrg ?? "", opens: .person(load.id))
        .tag(SidebarItem.person(load.id))
    }

    private func peopleViewRow(_ view: PeopleView) -> some View {
        Label(view.rawValue, systemImage: view.systemImage)
            .tag(SidebarItem.peopleView(view))
            .contextMenu { OpenElsewhereItems(sidebar: .peopleView(view)) }
    }

    // MARK: People

    /// Everyone (the people stats, opening to each person), then each
    /// team and No team opening to their members. An org without teams
    /// lists its people under Everyone alone.
    @ViewBuilder
    private var peopleRows: some View {
        DisclosureGroup(isExpanded: $allExpanded) {
            ForEach(people) { load in personRow(load) }
        } label: {
            Label("Everyone", systemImage: WorkloadTab.people.systemImage)
                .badge(people.count)
                .tag(SidebarItem.tab(.people))
                .contextMenu { OpenElsewhereItems(sidebar: .tab(.people)) }
        }
        ForEach(teamGroups, id: \.id) { group in
            DisclosureGroup(isExpanded: teamBinding(group.id)) {
                ForEach(group.members) { load in personRow(load) }
            } label: {
                Label(group.name, systemImage: group.id == "none" ? "person.crop.circle.dashed" : "person.2.circle")
                    .badge(group.members.count)
            }
        }
    }

    /// The org's teams with the people in view in each, by name, plus
    /// "No team" for the rest. Empty when the org has no teams.
    private var teamGroups: [(id: String, name: String, members: [PersonLoad])] {
        let teams = (workload?.snapshot.teams ?? [])
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard !teams.isEmpty else { return [] }
        let everyone = people
        var groups: [(id: String, name: String, members: [PersonLoad])] = teams.compactMap { team in
            let logins = Set(team.members)
            let members = everyone.filter { logins.contains($0.person.login) }
            return members.isEmpty ? nil : (team.id, team.name, members)
        }
        let inTeams = Set(teams.flatMap(\.members))
        let rest = everyone.filter { !inTeams.contains($0.person.login) }
        if !rest.isEmpty { groups.append(("none", "No team", rest)) }
        return groups
    }

    private var expandedTeams: Set<String> {
        Set(expandedTeamIDs.split(separator: ",").map(String.init))
    }

    private func teamBinding(_ id: String) -> Binding<Bool> {
        Binding {
            expandedTeams.contains(id)
        } set: { open in
            var ids = expandedTeams
            if open { ids.insert(id) } else { ids.remove(id) }
            expandedTeamIDs = ids.sorted().joined(separator: ",")
        }
    }

    /// Everyone in view (team and hidden filters apply), by name.
    private var people: [PersonLoad] {
        (workload?.people ?? []).sorted {
            $0.person.displayName.localizedCaseInsensitiveCompare($1.person.displayName) == .orderedAscending
        }
    }

    private func badge(for tab: WorkloadTab) -> Int {
        guard let workload else { return 0 }
        switch tab {
        case .pullRequests: return workload.openPullRequests.count
        case .inbox:
            guard let login = auth.viewer?.login else { return 0 }
            return Inbox(login: login, workload: workload, history: nil, workflow: IssueWorkflow()).count
        // Issues' lists under it have their own counts.
        case .agents:
            guard let selectedOrg else { return 0 }
            return sessions.sessions(for: selectedOrg).filter { sessions.isRunning($0.id) && (sessions.attention[$0.id] != nil || SessionQuestionCard.isAsking($0, in: sessions)) }.count
        case .dashboard, .issues, .people, .repositories, .actions, .investments, .projects, .harness, .views, .prioritisation, .recap, .scorecard, .ask, .epics, .hygiene, .delivery, .issueFlow, .settings: return 0
        }
    }
}

/// The org switcher, the org's settings and the account menu, pinned to the
/// bottom of the sidebar.
private struct SidebarFooter: View {
    @Environment(AuthStore.self) private var auth
    @Environment(OrgStore.self) private var orgs
    @Environment(OrgConfigStore.self) private var configs
    @Environment(\.openURL) private var openURL
    @Binding var selectedOrg: String?
    @Binding var workspace: UUID?
    @Binding var selection: SidebarItem?
    @State private var showingSettings = false

    var body: some View {
        // With projects, the cog sits beside the project and the account
        // beside the org, both 26 points, so the two menus line up.
        VStack(spacing: 6) {
            if let current, !configs.baseConfig(for: current.login).repoProjects.isEmpty {
                HStack(spacing: 8) {
                    projectMenu(current.login)
                    orgSettingsButton(current)
                }
                HStack(spacing: 8) {
                    orgMenu
                    accountMenu
                }
            } else {
                HStack(spacing: 8) {
                    orgMenu
                    if let current {
                        orgSettingsButton(current)
                    }
                    accountMenu
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }

    /// The window's project, or All; other windows and tabs keep theirs.
    private func projectMenu(_ org: String) -> some View {
        let projects = configs.baseConfig(for: org).repoProjects
        let project = configs.currentProject(org)
        return Menu {
            Picker("Project", selection: Binding(get: { project?.id }, set: { workspace = $0 })) {
                Text("All").tag(UUID?.none)
                Divider()
                ForEach(projects) { Text($0.name).tag(Optional($0.id)) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: project == nil ? "square.stack.3d.up" : "folder")
                    .foregroundStyle(project == nil ? Color.secondary : Color.accentColor)
                    .frame(width: 20)
                Text(project?.name ?? "All projects")
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help("The project this window shows; other windows and tabs keep theirs")
    }

    private var current: Organisation? {
        selectedOrg.flatMap(orgs.org(login:))
    }

    private var orgMenu: some View {
        Menu {
            Picker("Organisation", selection: $selectedOrg) {
                if !orgs.starredOrgs.isEmpty {
                    Section("Starred") {
                        ForEach(orgs.starredOrgs) { org in
                            Text(org.displayName).tag(Optional(org.login))
                        }
                    }
                }
                let personal = orgs.orgs.filter { $0.isPersonal && !orgs.isStarred($0) }
                if !personal.isEmpty {
                    Section("Personal") {
                        ForEach(personal) { account in
                            Text("\(account.displayName) (\(account.login))").tag(Optional(account.login))
                        }
                    }
                }
                Section(orgs.starredOrgs.isEmpty ? "Organisations" : "Other Organisations") {
                    ForEach(orgs.orgs.filter { !orgs.isStarred($0) && !$0.isPersonal }) { org in
                        Text(org.displayName).tag(Optional(org.login))
                    }
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            if let current {
                Button(orgs.isStarred(current) ? "Unstar \(current.displayName)" : "Star \(current.displayName)") {
                    orgs.toggleStar(current)
                }
                Button("Open \(current.displayName) on GitHub") {
                    if let url = URL(string: "https://github.com/\(current.login)") { openURL(url) }
                }
            }
            Button("Reload Accounts") {
                Task { await orgs.loadOrgs() }
            }
            .disabled(orgs.isLoadingOrgs)
        } label: {
            HStack(spacing: 8) {
                if let current {
                    Avatar(url: current.avatarUrl, size: 20)
                } else {
                    Image(systemName: "building.2")
                        .frame(width: 20, height: 20)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(current?.displayName ?? "Choose Organisation")
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help("Switch organisation")
    }

    /// The org's Settings page, lit while it's showing.
    private func orgSettingsButton(_ org: Organisation) -> some View {
        let isShowing = selection == .tab(.settings)
        return Button {
            selection = .tab(.settings)
        } label: {
            Image(systemName: WorkloadTab.settings.systemImage)
                .font(.system(size: 15))
                .foregroundStyle(isShowing ? Color.accentColor : .secondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(org.displayName) settings")
        .contextMenu { OpenElsewhereItems(sidebar: .tab(.settings)) }
    }

    @ViewBuilder
    private var accountMenu: some View {
        if let viewer = auth.viewer {
            Menu {
                Text(viewer.name ?? viewer.login)
                Divider()
                SettingsLink { Text("Settings") }
                Button("Sign Out") {
                    auth.signOut()
                    orgs.clear()
                }
            } label: {
                Avatar(url: viewer.avatarUrl, size: 26)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(viewer.login)
        }
    }
}
