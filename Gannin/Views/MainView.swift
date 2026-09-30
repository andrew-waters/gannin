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
    case settings = "Settings"

    var id: Self { self }

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
    @Environment(OrgConfigStore.self) private var orgConfigs
    @SceneStorage(MetricsStore.windowKey) private var windowDays = MetricsStore.defaultWindowDays
    @AppStorage("excludeDrafts") private var excludeDrafts = false
    @AppStorage("showHidden") private var showHidden = false

    @SceneStorage("selectedOrg") private var selectedOrg: String?
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
            OrgSidebar(selectedOrg: $selectedOrg, selection: sidebarSelection, workload: workload)
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
                .id(selectedOrg)
                #if !os(macOS)
                // The page's title and controls share the bar with the
                // sidebar toggle, as on the Mac's title bar.
                .navigationTitle(customTitle.isEmpty ? automaticTitle : customTitle)
                .navigationBarTitleDisplayMode(.inline)
                #endif
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
        .environment(\.showPerson, ShowPersonAction { login in sidebarSelection.wrappedValue = .person(login) })
        .environment(\.showSidebarItem, ShowSidebarAction { item in sidebarSelection.wrappedValue = item })
        #if os(macOS)
        .background(WindowAccessor { window in
            TabMenuRename.shared.register(window, action: startRenaming)
        })
        #endif
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
                selectedOrg = (orgs.starredOrgs.first ?? orgs.orgs.first)?.login
            }
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
        sidebarSelection.wrappedValue = pending.sidebar
        path = pending.path
    }

    /// Sidebar rows open in a new tab or window on the same org.
    private var sidebarOpenElsewhere: OpenElsewhereAction? {
        guard let selectedOrg else { return nil }
        return OpenElsewhereAction(
            open: { destination, placement in
                WindowRequest.open(NavigationRequest(org: selectedOrg, sidebar: .tab(tab), path: [destination]), placement: placement, openWindow: openWindow)
            },
            openSidebar: { item, placement in
                WindowRequest.open(NavigationRequest(org: selectedOrg, sidebar: item, path: []), placement: placement, openWindow: openWindow)
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
            harness: selectedOrg.flatMap { org in orgConfigs.config(for: org).harness.flatMap { harnessStore.index(for: org, $0) } }
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
        case .projects:
            return project.map { number in projectStore.boardLists[selectedOrg]?.first { $0.number == number }?.title ?? "Project \(number)" } ?? "Projects"
        case .views:
            return fieldView.flatMap { orgConfigs.fieldView($0, in: selectedOrg)?.name } ?? "Views"
        default:
            return tab.rawValue
        }
    }

    /// The section, or the person or repo picked beneath it.
    private var sidebarSelection: Binding<SidebarItem?> {
        Binding {
            if tab == .people, let person { return .person(person) }
            if tab == .people, let peopleView { return .peopleView(peopleView) }
            if tab == .repositories, let repository { return .repository(repository) }
            if tab == .issues, let issueList { return .issueList(issueList) }
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
            windowDays: windowDays,
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

    /// The PR or issue open in the drawer over the page.
    @State private var drawer: DetailSelection?

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
        .animation(.snappy(duration: 0.25), value: drawer)
        .onChange(of: path) { drawer = nil }
        .toolbar {
            if !path.isEmpty {
                ToolbarItem(placement: .navigation) { backButton }
                if usesWindow(path.last) {
                    ToolbarItem { windowPicker }
                }
            }
        }
        .onEscape {
            if drawer != nil {
                drawer = nil
            } else if !path.isEmpty {
                path.removeLast()
            }
        }
        .environment(\.currentOrg, org)
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
        Picker("Window", selection: $windowDays) {
            ForEach(MetricsStore.windowOptions, id: \.self) { Text("\($0) days").tag($0) }
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .help("Window for the stats")
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
    /// PRs and issues open in the drawer, everywhere in the app; anything
    /// else is pushed from `depth` (closing the drawer).
    private func navigate(at depth: Int) -> NavigateAction {
        NavigateAction { destination in
            if Self.opensInDrawer(destination) {
                drawer = destination
            } else {
                drawer = nil
                push(at: depth)(destination)
            }
        }
    }

    static func opensInDrawer(_ destination: DetailSelection) -> Bool {
        switch destination {
        case .issue, .issueReference, .pullRequest, .pullRequestReference: true
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
                WindowRequest.open(NavigationRequest(org: org, sidebar: sidebar, path: trail + [destination]), placement: placement, openWindow: openWindow)
            },
            openSidebar: { item, placement in
                WindowRequest.open(NavigationRequest(org: org, sidebar: item, path: []), placement: placement, openWindow: openWindow)
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

    /// Over the right of the page, as GitHub's drawer: a click outside or
    /// Esc closes it, and links inside it to another PR or issue swap it.
    @ViewBuilder
    private var drawerOverlay: some View {
        if let item = drawer {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { drawer = nil }
            GeometryReader { geometry in
                let width = min(max(700, geometry.size.width * 0.7), max(geometry.size.width - 80, 480))
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    drawerContent(item, isWide: width >= 900)
                        .environment(\.navigate, navigate(at: path.count))
                        .environment(\.openAsPage, NavigateAction { destination in
                            drawer = nil
                            push(at: path.count)(destination)
                        })
                        .environment(\.openElsewhere, openElsewhere(trail: path))
                        .frame(width: width)
                        .frame(maxHeight: .infinity)
                        .background(Color.windowBackground, in: Self.drawerShape)
                        .clipShape(Self.drawerShape)
                        .overlay { Self.drawerShape.strokeBorder(Color.separatorLine) }
                        .shadow(color: .black.opacity(0.25), radius: 24, x: -4)
                }
            }
            .transition(.move(edge: .trailing))
        }
    }

    /// An issue as the views' drawer shows it (timeline and board fields
    /// beside the description); a PR as its page, under Open as Page, Open
    /// in Window and Done.
    @ViewBuilder
    private func drawerContent(_ item: DetailSelection, isWide: Bool) -> some View {
        if let reference = issueReference(item) {
            let workflow = configs.config(for: org).workflow
            let history = issueStore.history(for: org)
            let signals = history?.issues[reference.id].map { FieldContext(board: workflow.projectNumber, workflow: workflow, history: history).signals($0) }
            IssueSheet(reference: reference, signals: signals, isWide: isWide) { drawer = nil }
                .id(reference.id)
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Spacer()
                    Button("Open as Page") {
                        drawer = nil
                        push(at: path.count)(item)
                    }
                    Button("Open in Window") {
                        drawer = nil
                        if !openOwnWindow(item) {
                            WindowRequest.open(NavigationRequest(org: org, sidebar: sidebar, path: path + [item]), placement: .window, openWindow: openWindow)
                        }
                    }
                    Button("Done") { drawer = nil }
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
        actionsStore.history(for: org).map { ActionsMetrics(history: $0, windowDays: windowDays, config: configs.config(for: org)) }
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
                gone("No workflow runs in this repository in the last \(windowDays) days.")
            }
        case .workflow(let key):
            if let actions, let workflow = actions.workflow(key) {
                WorkflowPage(org: org, workflow: workflow, windowStart: actions.windowStart, hasPrevious: actions.hasPrevious, navigate: push.perform)
            } else {
                gone("No runs of this workflow in the last \(windowDays) days.")
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
                gone("No runs of this workflow in the last \(windowDays) days.")
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
    @Binding var selection: SidebarItem?
    let workload: Workload?
    @AppStorage("sidebarPeopleExpanded") private var peopleExpanded = true
    @AppStorage("sidebarPlanningExpanded") private var planningExpanded = true
    @AppStorage("sidebarSessionsExpanded") private var sessionsExpanded = true
    @AppStorage("sidebarAllExpanded") private var allExpanded = false
    /// Team IDs opened under People, comma separated.
    @AppStorage("sidebarExpandedTeams") private var expandedTeamIDs = ""
    @AppStorage("sidebarRepositoriesExpanded") private var repositoriesExpanded = false
    @AppStorage("sidebarIssuesExpanded") private var issuesExpanded = true
    @AppStorage("sidebarProjectsExpanded") private var projectsExpanded = true
    @AppStorage("sidebarViewsExpanded") private var viewsExpanded = true
    @Environment(ProjectStore.self) private var projectStore
    @Environment(OrgConfigStore.self) private var configs
    @Environment(AuthStore.self) private var auth
    #if os(macOS)
    @Environment(SessionStore.self) private var sessions
    #endif

    /// The Harness row only shows once the org names its harness repo.
    private var hasHarness: Bool {
        selectedOrg.map { configs.config(for: $0).harness != nil } ?? false
    }

    var body: some View {
        List(selection: $selection) {
            if let selectedOrg {
                Section {
                    row(.inbox)
                    row(.dashboard)
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
                    row(.pullRequests)
                    DisclosureGroup(isExpanded: $repositoriesExpanded) {
                        ForEach(repositories) { repository in
                            repositoryRow(repository)
                        }
                    } label: {
                        row(.repositories)
                    }
                    row(.actions)
                }

                Section("People", isExpanded: $peopleExpanded) {
                    peopleViewRow(.activity)
                    peopleViewRow(.standup)
                    peopleViewRow(.timeOff)
                    peopleRows
                }

                Section("Planning", isExpanded: $planningExpanded) {
                    row(.investments)
                    if hasHarness { row(.harness) }
                    DisclosureGroup(isExpanded: $projectsExpanded) {
                        ForEach(projectStore.boardLists[selectedOrg] ?? []) { board in
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

                #if os(macOS)
                if !sessions.sessions(for: selectedOrg).isEmpty {
                    Section("Claude Code", isExpanded: $sessionsExpanded) {
                        SessionSidebarRows(org: selectedOrg)
                    }
                }
                #endif

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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if let selectedOrg {
                    HarnessPendingRow(org: selectedOrg)
                    SyncFooter(org: selectedOrg)
                        .loadsHarness(org: selectedOrg)
                }
                SidebarFooter(selectedOrg: $selectedOrg, selection: $selection)
            }
            #if !os(macOS)
            // The Mac's sidebar gives the footer its own material; iPad's
            // lets the rows show through, so it needs one.
            .background(.bar)
            #endif
        }
    }

    /// A section's own row: its page, with its count.
    private func row(_ tab: WorkloadTab) -> some View {
        Label(tab.rawValue, systemImage: tab.systemImage)
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
        case .dashboard, .issues, .people, .repositories, .actions, .investments, .projects, .harness, .views, .settings: return 0
        }
    }
}

/// The org switcher, the org's settings and the account menu, pinned to the
/// bottom of the sidebar.
private struct SidebarFooter: View {
    @Environment(AuthStore.self) private var auth
    @Environment(OrgStore.self) private var orgs
    @Environment(\.openURL) private var openURL
    @Binding var selectedOrg: String?
    @Binding var selection: SidebarItem?
    @State private var showingSettings = false

    var body: some View {
        HStack(spacing: 8) {
            orgMenu
            if let current {
                orgSettingsButton(current)
            }
            accountMenu
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
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
                Section(orgs.starredOrgs.isEmpty ? "Organisations" : "Other Organisations") {
                    ForEach(orgs.orgs.filter { !orgs.isStarred($0) }) { org in
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
            Button("Reload Organisations") {
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
                Text(current?.displayName ?? "Choose Organisation")
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
                #if os(macOS)
                SettingsLink { Text("Settings") }
                #else
                Button("Settings") { showingSettings = true }
                #endif
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
            #if !os(macOS)
            // iPad has no Settings window, so the app's settings are a sheet.
            .sheet(isPresented: $showingSettings) {
                NavigationStack {
                    SettingsView()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showingSettings = false }
                            }
                        }
                }
            }
            #endif
        }
    }
}
