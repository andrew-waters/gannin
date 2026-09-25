import SwiftUI

/// What the detail column is showing.
enum DetailSelection: Hashable {
    case person(String)
    case pullRequest(String)
    case issue(String)
}

enum WorkloadTab: String, CaseIterable, Identifiable {
    case people = "People"
    case pullRequests = "Pull Requests"
    case issues = "Issues"

    var id: Self { self }
}

struct MainView: View {
    @Environment(OrgStore.self) private var orgs

    @AppStorage("selectedOrg") private var selectedOrg: String?
    @State private var teamID: String?
    @State private var tab: WorkloadTab = .people
    /// The drill-down trail: each entry is the item open in the next column.
    @State private var path: [DetailSelection] = []
    @State private var searchText = ""

    var body: some View {
        NavigationSplitView {
            OrgSidebar(selection: $selectedOrg)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            if let selectedOrg {
                ColumnBrowser(
                    org: selectedOrg,
                    workload: workload,
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
        .searchable(text: $searchText, placement: .toolbar, prompt: "Filter by title, repo or person")
        .task { await orgs.loadOrgs() }
        .onChange(of: selectedOrg) {
            teamID = nil
            path = []
        }
        .onChange(of: tab) { path = [] }
    }

    private var workload: Workload? {
        guard let selectedOrg, let snapshot = orgs.snapshot(for: selectedOrg) else { return nil }
        let team = teamID.flatMap { id in snapshot.teams.first { $0.id == id } }
        return Workload(snapshot: snapshot, team: team)
    }
}

// MARK: - Column browser

/// Finder-style columns: the org's workload list, then one column per
/// drilled-into item. Selecting in a column replaces everything to its right.
private struct ColumnBrowser: View {
    let org: String
    let workload: Workload?
    @Binding var teamID: String?
    @Binding var tab: WorkloadTab
    @Binding var path: [DetailSelection]
    let searchText: String

    private static let rootWidth: CGFloat = 420
    private static let columnWidth: CGFloat = 440

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        OrgWorkloadView(
                            org: org,
                            workload: workload,
                            teamID: $teamID,
                            tab: $tab,
                            selection: selection(at: 0),
                            searchText: searchText
                        )
                        .frame(width: path.isEmpty ? max(Self.rootWidth, geometry.size.width) : Self.rootWidth)

                        ForEach(Array(path.enumerated()), id: \.offset) { index, item in
                            Divider()
                            column(for: item, index: index)
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
        let used = Self.rootWidth + CGFloat(path.count - 1) * Self.columnWidth
        return max(Self.columnWidth, available - used)
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
                PullRequestColumn(pr: pr, workload: workload, selection: selection)
            } else {
                unavailable
            }
        case .issue(let id):
            if let workload, let issue = workload.issue(id: id) {
                IssueColumn(issue: issue, workload: workload, selection: selection)
            } else {
                unavailable
            }
        }
    }

    private var unavailable: some View {
        ContentUnavailableView(
            "Not in this view",
            systemImage: "eye.slash",
            description: Text("They aren't an org member, or the team filter hides them.")
        )
    }
}

// MARK: - Sidebar

struct OrgSidebar: View {
    @Environment(AuthStore.self) private var auth
    @Environment(OrgStore.self) private var orgs
    @Binding var selection: String?

    var body: some View {
        List(selection: $selection) {
            if !orgs.starredOrgs.isEmpty {
                Section("Starred") {
                    ForEach(orgs.starredOrgs) { org in
                        OrgRow(org: org).tag(org.login)
                    }
                }
            }
            Section("Organisations") {
                ForEach(orgs.orgs.filter { !orgs.isStarred($0) }) { org in
                    OrgRow(org: org).tag(org.login)
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
