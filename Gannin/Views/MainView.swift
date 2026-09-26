import SwiftUI

/// What the detail column is showing.
enum DetailSelection: Hashable {
    case person(String)
    case pullRequest(String)
    case issue(String)
    case repository(String)
    case metric(MetricDrill)
}

/// The sidebar's sections, in sidebar order.
enum WorkloadTab: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case issues = "Issues"
    case pullRequests = "Pull Requests"
    case people = "People"
    case repositories = "Repositories"
    case investments = "Investments"
    case settings = "Settings"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .dashboard: "square.grid.2x2"
        case .issues: "smallcircle.filled.circle"
        case .pullRequests: "arrow.triangle.pull"
        case .people: "person.2"
        case .repositories: "folder"
        case .investments: "chart.pie"
        case .settings: "gearshape"
        }
    }
}

/// A sidebar row: a section, or a person listed under People.
enum SidebarItem: Hashable {
    case tab(WorkloadTab)
    case person(String)
}

struct MainView: View {
    @Environment(OrgStore.self) private var orgs
    @Environment(HiddenStore.self) private var hidden
    @Environment(MetricsStore.self) private var metricsStore
    @Environment(OrgConfigStore.self) private var orgConfigs
    @AppStorage(MetricsStore.windowKey) private var windowDays = MetricsStore.defaultWindowDays
    @AppStorage("excludeDrafts") private var excludeDrafts = false
    @AppStorage("showHidden") private var showHidden = false

    @AppStorage("selectedOrg") private var selectedOrg: String?
    @State private var teamID: String?
    @AppStorage("selectedTab") private var tab: WorkloadTab = .dashboard
    /// The drill-down trail: each entry is the item open in the next column.
    @State private var path: [DetailSelection] = []
    /// The person picked under People in the sidebar, shown as the main view.
    @State private var person: String?
    /// No search field for now; the list filtering is kept for when it returns.
    @State private var searchText = ""

    var body: some View {
        NavigationSplitView {
            OrgSidebar(selectedOrg: $selectedOrg, selection: sidebarSelection, workload: workload)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            if let selectedOrg {
                ColumnBrowser(
                    org: selectedOrg,
                    workload: workload,
                    metrics: metrics,
                    teamID: $teamID,
                    tab: $tab,
                    person: person,
                    path: $path,
                    searchText: searchText
                )
                .id(selectedOrg)
            } else {
                ContentUnavailableView(
                    "Pick an organisation",
                    systemImage: "building.2",
                    description: Text("Choose one with the switcher at the bottom of the sidebar.")
                )
            }
        }
        .task { await orgs.loadOrgs() }
        .onChange(of: selectedOrg) {
            teamID = nil
            person = nil
            path = []
        }
        .onChange(of: orgs.orgs, initial: true) {
            if selectedOrg == nil {
                selectedOrg = (orgs.starredOrgs.first ?? orgs.orgs.first)?.login
            }
        }
    }

    /// The section, or the person picked under People.
    private var sidebarSelection: Binding<SidebarItem?> {
        Binding {
            if tab == .people, let person { return .person(person) }
            return .tab(tab)
        } set: { item in
            switch item {
            case .tab(let newTab):
                tab = newTab
                person = nil
                path = []
            case .person(let login):
                tab = .people
                person = login
                path = []
            case nil:
                break
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

// MARK: - Column browser

/// Finder-style columns: the org's workload list, then one column per
/// drilled-into item. Selecting in a column replaces everything to its right.
private struct ColumnBrowser: View {
    let org: String
    let workload: Workload?
    let metrics: OrgMetrics?
    @Binding var teamID: String?
    @Binding var tab: WorkloadTab
    let person: String?
    @Binding var path: [DetailSelection]
    let searchText: String

    private static let columnWidth: CGFloat = 440
    private static let minimumRootWidth: CGFloat = 360

    /// First-column width while drilled in, per kind of first column.
    /// Zero for Overview means "60% of the window".
    @AppStorage("overviewColumnWidth") private var overviewWidth: Double = 0
    @AppStorage("listColumnWidth") private var listWidth: Double = 420
    @State private var dragStartWidth: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        OrgWorkloadView(
                            org: org,
                            workload: workload,
                            metrics: metrics,
                            teamID: $teamID,
                            tab: $tab,
                            person: person,
                            selection: selection(at: 0),
                            searchText: searchText
                        )
                        .frame(width: path.isEmpty ? geometry.size.width : rootWidth(available: geometry.size.width))

                        ForEach(Array(path.enumerated()), id: \.offset) { index, item in
                            if index == 0 {
                                ColumnResizeHandle { translation in
                                    resizeRoot(by: translation, available: geometry.size.width)
                                } onEnd: {
                                    dragStartWidth = nil
                                }
                            } else {
                                Divider()
                            }
                            VStack(spacing: 0) {
                                ColumnTitleBar(title: title(for: item)) {
                                    path = Array(path.prefix(index))
                                }
                                Divider()
                                column(for: item, index: index)
                            }
                            .frame(width: width(of: index, available: geometry.size.width))
                                .id(index)
                        }
                    }
                    .frame(height: geometry.size.height)
                }
                .scrollIndicators(.automatic)
                .onChange(of: path) {
                    guard !path.isEmpty else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(path.count - 1, anchor: .trailing)
                    }
                }
            }
        }
        .onExitCommand {
            if !path.isEmpty { path.removeLast() }
        }
        .environment(\.currentOrg, org)
    }

    /// The last column stretches to fill any room left in the window.
    private func width(of index: Int, available: CGFloat) -> CGFloat {
        guard index == path.count - 1 else { return Self.columnWidth }
        let used = rootWidth(available: available) + CGFloat(path.count - 1) * Self.columnWidth
        return max(Self.columnWidth, available - used)
    }

    /// Overview wants room for its tables, so it defaults much wider than
    /// the list tabs. Either can be dragged, and the width is remembered.
    /// Dashboard and the People stats hold wide tables.
    private var isWide: Bool {
        tab == .dashboard || tab == .investments || (tab == .people && person == nil)
    }

    private func rootWidth(available: CGFloat) -> CGFloat {
        let stored = isWide ? (overviewWidth > 0 ? overviewWidth : available * 0.6) : listWidth
        let maximum = max(Self.minimumRootWidth, available - Self.columnWidth)
        return min(max(CGFloat(stored), Self.minimumRootWidth), maximum)
    }

    private func resizeRoot(by translation: CGFloat, available: CGFloat) {
        let start = dragStartWidth ?? rootWidth(available: available)
        dragStartWidth = start
        let width = Double(min(max(start + translation, Self.minimumRootWidth), available - 200))
        if isWide {
            overviewWidth = width
        } else {
            listWidth = width
        }
    }

    /// Selection within the column at `depth`: reading gives the item open
    /// to its right, writing truncates the trail there and opens the new one.
    private func selection(at depth: Int) -> Binding<DetailSelection?> {
        Binding {
            path.indices.contains(depth) ? path[depth] : nil
        } set: { newValue in
            var trail = Array(path.prefix(depth))
            if let newValue { trail.append(newValue) }
            path = trail
        }
    }

    @ViewBuilder
    private func column(for item: DetailSelection, index: Int) -> some View {
        let selection = selection(at: index + 1)
        switch item {
        case .person(let login):
            if let workload, let load = workload.load(for: login) {
                PersonColumn(load: load, workload: workload, selection: selection)
            } else {
                unavailable
            }
        case .pullRequest(let id):
            if let workload, let pr = workload.pullRequest(id: id) {
                PullRequestColumn(pr: pr, workload: workload, timing: metrics?.pullRequest(id: id), selection: selection)
            } else if let pr = metrics?.pullRequest(id: id) {
                MetricPullRequestColumn(pr: pr, selection: selection)
            } else {
                unavailable
            }
        case .issue(let id):
            if let workload, let issue = workload.issue(id: id) {
                IssueColumn(issue: issue, workload: workload, selection: selection)
            } else {
                unavailable
            }
        case .repository(let name):
            if let workload, let repository = workload.repository(named: name) {
                RepositoryColumn(repository: repository, workload: workload, selection: selection)
            } else {
                unavailable
            }
        case .metric(let drill):
            MetricColumn(drill: drill, workload: workload, metrics: metrics, selection: selection)
        }
    }

    private func title(for item: DetailSelection) -> String {
        switch item {
        case .person(let login):
            return workload?.load(for: login)?.person.displayName ?? login
        case .pullRequest(let id):
            if let pr = workload?.pullRequest(id: id) { return "\(pr.repo)#\(pr.number)" }
            if let pr = metrics?.pullRequest(id: id) { return "\(pr.repo)#\(pr.number)" }
            return "Pull request"
        case .issue(let id):
            return workload?.issue(id: id).map { "\($0.repo)#\($0.number)" } ?? "Issue"
        case .repository(let name):
            return name
        case .metric(let drill):
            if case .personStats(let login) = drill,
               let person = metrics?.people.first(where: { $0.id == login })?.person
                ?? metrics?.reviewers.first(where: { $0.id == login })?.person {
                return person.displayName
            }
            return drill.title
        }
    }

    private var unavailable: some View {
        ContentUnavailableView(
            "Not in this view",
            systemImage: "eye.slash",
            description: Text("It's hidden, filtered out, or not part of this org's snapshot.")
        )
    }
}

// MARK: - Sidebar

struct OrgSidebar: View {
    @Environment(OrgStore.self) private var orgs
    @Binding var selectedOrg: String?
    @Binding var selection: SidebarItem?
    let workload: Workload?
    @AppStorage("sidebarPeopleExpanded") private var peopleExpanded = true

    var body: some View {
        List(selection: $selection) {
            if selectedOrg != nil {
                ForEach(WorkloadTab.allCases.filter { $0 != .settings }) { tab in
                    if tab == .people {
                        peopleRow
                        if peopleExpanded {
                            ForEach(people) { load in
                                personRow(load)
                            }
                        }
                    } else {
                        Label(tab.rawValue, systemImage: tab.systemImage)
                            .badge(badge(for: tab))
                            .tag(SidebarItem.tab(tab))
                    }
                }
                Section {
                    Label(WorkloadTab.settings.rawValue, systemImage: WorkloadTab.settings.systemImage)
                        .tag(SidebarItem.tab(.settings))
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if let selectedOrg {
                    SyncFooter(org: selectedOrg)
                }
                SidebarFooter(selectedOrg: $selectedOrg)
            }
        }
    }

    private var peopleRow: some View {
        HStack {
            Label(WorkloadTab.people.rawValue, systemImage: WorkloadTab.people.systemImage)
            Spacer(minLength: 4)
            Button {
                withAnimation(.easeOut(duration: 0.15)) { peopleExpanded.toggle() }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(peopleExpanded ? 90 : 0))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(peopleExpanded ? "Hide people" : "Show people")
        }
        .tag(SidebarItem.tab(.people))
    }

    /// Name, then what they have on in words ("2 PRs · 1 review"), with
    /// only "stale" coloured as a warning.
    private func personRow(_ load: PersonLoad) -> some View {
        HStack(spacing: 8) {
            Avatar(url: load.person.avatarUrl, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(load.person.displayName)
                    .lineLimit(1)
                workSummary(load)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.leading, 20)
        .padding(.vertical, 1)
        .excludable(login: load.person.login, org: selectedOrg ?? "")
        .tag(SidebarItem.person(load.id))
    }

    private func workSummary(_ load: PersonLoad) -> Text {
        func count(_ n: Int, _ singular: String, _ plural: String) -> String? {
            n == 0 ? nil : "\(n) \(n == 1 ? singular : plural)"
        }
        let parts = [
            count(load.pullRequests.count, "PR", "PRs"),
            count(load.reviewRequests.count, "review", "reviews"),
            count(load.activeIssues.count, "issue", "issues"),
        ].compactMap { $0 }
        let stale = load.stalePullRequests.count
        guard !parts.isEmpty || stale > 0 else { return Text("Nothing in flight") }
        var summary = Text(parts.joined(separator: " · "))
        if stale > 0 {
            let staleText = Text("\(stale) stale").foregroundStyle(.orange)
            summary = parts.isEmpty ? staleText : Text("\(summary) · \(staleText)")
        }
        return summary
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
        case .issues: return workload.assignedIssues.count
        case .dashboard, .people, .repositories, .investments, .settings: return 0
        }
    }
}

/// The org switcher and the account menu, pinned to the bottom of the sidebar.
private struct SidebarFooter: View {
    @Environment(AuthStore.self) private var auth
    @Environment(OrgStore.self) private var orgs
    @Environment(\.openURL) private var openURL
    @Binding var selectedOrg: String?

    var body: some View {
        HStack(spacing: 8) {
            orgMenu
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

// MARK: - Resize handle

/// A divider that can be dragged sideways to resize the column to its left.
private struct ColumnResizeHandle: View {
    let onChange: (CGFloat) -> Void
    let onEnd: () -> Void
    @State private var isHovering = false

    var body: some View {
        Rectangle()
            .fill(isHovering ? Color.accentColor.opacity(0.6) : Color(nsColor: .separatorColor))
            .frame(width: isHovering ? 2 : 1)
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        isHovering = hovering
                        if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { onChange($0.translation.width) }
                            .onEnded { _ in onEnd() }
                    )
            }
            .zIndex(1)
            .help("Drag to resize")
    }
}

// MARK: - Column title bar

/// Close button and title across the top of a drill-down column.
private struct ColumnTitleBar: View {
    let title: String
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.callout.weight(.semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Close this column")
            Text(title)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(.bar)
    }
}
