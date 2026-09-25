import SwiftUI

/// What the detail column is showing.
enum DetailSelection: Hashable {
    case person(String)
    case pullRequest(String)
    case issue(String)
    case metric(MetricDrill)
}

enum WorkloadTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case people = "People"
    case pullRequests = "Pull Requests"
    case issues = "Issues"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .people: "person.2"
        case .pullRequests: "arrow.triangle.pull"
        case .issues: "smallcircle.filled.circle"
        }
    }
}

/// A sidebar row: an org (which opens its overview) or one of its views.
struct SidebarItem: Hashable {
    let org: String
    let tab: WorkloadTab
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
    @AppStorage("selectedTab") private var tab: WorkloadTab = .overview
    /// The drill-down trail: each entry is the item open in the next column.
    @State private var path: [DetailSelection] = []
    /// No search field for now; the list filtering is kept for when it returns.
    @State private var searchText = ""

    var body: some View {
        NavigationSplitView {
            OrgSidebar(selection: sidebarSelection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            if let selectedOrg {
                ColumnBrowser(
                    org: selectedOrg,
                    workload: workload,
                    metrics: metrics,
                    teamID: $teamID,
                    tab: $tab,
                    path: $path,
                    searchText: searchText
                )
                .id(selectedOrg)
            } else {
                ContentUnavailableView(
                    "Pick an organisation",
                    systemImage: "building.2",
                    description: Text("Star the orgs you look after to keep them at the top.")
                )
            }
        }
        .task { await orgs.loadOrgs() }
        .onChange(of: selectedOrg) {
            teamID = nil
            path = []
        }
        .onChange(of: tab) { path = [] }
    }

    private var sidebarSelection: Binding<SidebarItem?> {
        Binding {
            selectedOrg.map { SidebarItem(org: $0, tab: tab) }
        } set: { item in
            guard let item else { return }
            selectedOrg = item.org
            tab = item.tab
        }
    }

    private var workload: Workload? {
        guard let selectedOrg, let snapshot = orgs.snapshot(for: selectedOrg) else { return nil }
        let team = teamID.flatMap { id in snapshot.teams.first { $0.id == id } }
        let options = Workload.Options(excludeDrafts: excludeDrafts, hidden: hidden.keys, showHidden: showHidden)
        return Workload(snapshot: snapshot, team: team, options: options)
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
            config: orgConfigs.config(for: selectedOrg),
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
    }

    /// The last column stretches to fill any room left in the window.
    private func width(of index: Int, available: CGFloat) -> CGFloat {
        guard index == path.count - 1 else { return Self.columnWidth }
        let used = rootWidth(available: available) + CGFloat(path.count - 1) * Self.columnWidth
        return max(Self.columnWidth, available - used)
    }

    /// Overview wants room for its tables, so it defaults much wider than
    /// the list tabs. Either can be dragged, and the width is remembered.
    private func rootWidth(available: CGFloat) -> CGFloat {
        let stored = tab == .overview ? (overviewWidth > 0 ? overviewWidth : available * 0.6) : listWidth
        let maximum = max(Self.minimumRootWidth, available - Self.columnWidth)
        return min(max(CGFloat(stored), Self.minimumRootWidth), maximum)
    }

    private func resizeRoot(by translation: CGFloat, available: CGFloat) {
        let start = dragStartWidth ?? rootWidth(available: available)
        dragStartWidth = start
        let width = Double(min(max(start + translation, Self.minimumRootWidth), available - 200))
        if tab == .overview {
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
    @Environment(AuthStore.self) private var auth
    @Environment(OrgStore.self) private var orgs
    @Binding var selection: SidebarItem?

    var body: some View {
        List(selection: $selection) {
            if !orgs.starredOrgs.isEmpty {
                Section("Starred") {
                    ForEach(orgs.starredOrgs) { org in
                        orgRows(org)
                    }
                }
            }
            Section("Organisations") {
                ForEach(orgs.orgs.filter { !orgs.isStarred($0) }) { org in
                    orgRows(org)
                }
                if orgs.orgs.isEmpty && !orgs.isLoadingOrgs {
                    Text("No organisations found")
                        .foregroundStyle(.secondary)
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
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await orgs.loadOrgs() }
                } label: {
                    Label("Reload Organisations", systemImage: "arrow.clockwise")
                }
                .disabled(orgs.isLoadingOrgs)
            }
        }
        .safeAreaInset(edge: .bottom) {
            accountBar
        }
    }

    /// The org, then its views indented beneath it while it's selected.
    @ViewBuilder
    private func orgRows(_ org: Organisation) -> some View {
        OrgRow(org: org).tag(SidebarItem(org: org.login, tab: .overview))
        if selection?.org == org.login {
            ForEach(WorkloadTab.allCases.filter { $0 != .overview }) { tab in
                Label(tab.rawValue, systemImage: tab.systemImage)
                    .padding(.leading, 22)
                    .badge(badge(for: tab, org: org.login))
                    .tag(SidebarItem(org: org.login, tab: tab))
            }
        }
    }

    private func badge(for tab: WorkloadTab, org: String) -> Int {
        guard let snapshot = orgs.snapshot(for: org) else { return 0 }
        switch tab {
        case .pullRequests: return snapshot.openPullRequests.count
        case .issues: return snapshot.issues.filter { !$0.assignees.isEmpty }.count
        case .overview, .people: return 0
        }
    }

    @ViewBuilder
    private var accountBar: some View {
        if let viewer = auth.viewer {
            HStack(spacing: 8) {
                Avatar(url: viewer.avatarUrl, size: 24)
                Text(viewer.name ?? viewer.login)
                    .lineLimit(1)
                Spacer()
                Menu {
                    Button("Sign Out") {
                        auth.signOut()
                        orgs.clear()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .fixedSize()
            }
            .padding(10)
        }
    }
}

private struct OrgRow: View {
    @Environment(OrgStore.self) private var orgs
    @Environment(\.openURL) private var openURL
    let org: Organisation

    var body: some View {
        HStack(spacing: 8) {
            Avatar(url: org.avatarUrl, size: 20)
            Text(org.displayName)
                .lineLimit(1)
            Spacer()
            Button {
                orgs.toggleStar(org)
            } label: {
                Image(systemName: orgs.isStarred(org) ? "star.fill" : "star")
                    .foregroundStyle(orgs.isStarred(org) ? Color.yellow : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(orgs.isStarred(org) ? "Unstar" : "Star")
        }
        .contextMenu {
            Button(orgs.isStarred(org) ? "Unstar" : "Star") { orgs.toggleStar(org) }
            Button("Open on GitHub") {
                if let url = URL(string: "https://github.com/\(org.login)") { openURL(url) }
            }
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
