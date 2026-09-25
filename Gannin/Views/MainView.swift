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
    @State private var selection: DetailSelection?
    @State private var searchText = ""

    var body: some View {
        NavigationSplitView {
            OrgSidebar(selection: $selectedOrg)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } content: {
            content
                .navigationSplitViewColumnWidth(min: 360, ideal: 460)
        } detail: {
            detail
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Filter by title, repo or person")
        .task { await orgs.loadOrgs() }
        .onChange(of: selectedOrg) {
            teamID = nil
            selection = nil
        }
    }

    private var workload: Workload? {
        guard let selectedOrg, let snapshot = orgs.snapshot(for: selectedOrg) else { return nil }
        let team = teamID.flatMap { id in snapshot.teams.first { $0.id == id } }
        return Workload(snapshot: snapshot, team: team)
    }

    @ViewBuilder
    private var content: some View {
        if let selectedOrg {
            OrgWorkloadView(
                org: selectedOrg,
                workload: workload,
                teamID: $teamID,
                tab: $tab,
                selection: $selection,
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

    @ViewBuilder
    private var detail: some View {
        if let workload, let selection {
            switch selection {
            case .person(let login):
                if let load = workload.load(for: login) {
                    PersonDetailView(load: load, workload: workload, selection: $selection)
                } else {
                    unavailable
                }
            case .pullRequest(let id):
                if let pr = workload.pullRequest(id: id) {
                    PullRequestDetailView(pr: pr, workload: workload, selection: $selection)
                } else {
                    unavailable
                }
            case .issue(let id):
                if let issue = workload.issue(id: id) {
                    IssueDetailView(issue: issue, workload: workload, selection: $selection)
                } else {
                    unavailable
                }
            }
        } else {
            ContentUnavailableView("Nothing selected", systemImage: "sidebar.right")
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
