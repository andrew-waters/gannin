import SwiftUI

struct OrgWorkloadView: View {
    @Environment(OrgStore.self) private var orgs
    @Environment(MetricsStore.self) private var metricsStore
    @AppStorage(MetricsStore.windowKey) private var windowDays = MetricsStore.defaultWindowDays
    @AppStorage("excludeDrafts") private var excludeDrafts = false
    @AppStorage("showHidden") private var showHidden = false

    let org: String
    let workload: Workload?
    let metrics: OrgMetrics?
    @Binding var teamID: String?
    @Binding var tab: WorkloadTab
    /// The person picked under People in the sidebar.
    let person: String?
    @Binding var selection: DetailSelection?
    let searchText: String

    var body: some View {
        Group {
            if tab == .settings {
                OrgSettingsView(org: org)
            } else if tab == .people && person == nil, let workload {
                // Everyone's stats: no team or filter bar.
                list(workload)
            } else {
                VStack(spacing: 0) {
                    header
                    Divider()
                    content
                }
            }
        }
        .navigationTitle(orgs.org(login: org)?.displayName ?? org)
        .toolbar {
            if tab == .dashboard || (tab == .people && person == nil) {
                ToolbarItem {
                    Picker("Window", selection: $windowDays) {
                        ForEach(MetricsStore.windowOptions, id: \.self) { Text("\($0) days").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .help("Window for the delivery and people stats")
                }
            }
        }
        .task { await orgs.refreshIfStale(org) }
        .task(id: windowDays) { await metricsStore.sync(org, windowDays: windowDays) }
    }

    @ViewBuilder
    private var content: some View {
        if let workload {
            list(workload)
        } else if let error = orgs.errors[org] {
            ContentUnavailableView {
                Label("Couldn't load \(org)", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { Task { await orgs.refresh(org) } }
            }
        } else {
            ProgressView("Loading work in \(org)")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                teamPicker
                filterMenu
                Spacer(minLength: 8)
            }
            .controlSize(.small)

            if let workload, tab != .dashboard, tab != .people {
                summary(workload)
            }
            if let error = orgs.errors[org], workload != nil {
                Banner(message: "Refresh failed: \(error)", systemImage: "exclamationmark.triangle.fill", tint: .red) {
                    Task { await orgs.refresh(org) }
                }
            }
            ForEach(workload?.snapshot.warnings ?? [], id: \.self) { warning in
                Banner(message: warning, systemImage: "info.circle", tint: .secondary)
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private var teamPicker: some View {
        let teams = (workload?.snapshot.teams ?? []).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if !teams.isEmpty {
            Picker(selection: $teamID) {
                Text("Everyone").tag(String?.none)
                Divider()
                ForEach(teams) { team in
                    Text(team.name).tag(Optional(team.id))
                }
            } label: {
                Image(systemName: "person.3")
            }
            .fixedSize()
            .help("Team")
        }
    }

    private var filterMenu: some View {
        let hiddenCount = workload?.hiddenCount ?? 0
        let isFiltering = excludeDrafts || (hiddenCount > 0 && !showHidden)
        return Menu {
            Toggle("Exclude Drafts", isOn: $excludeDrafts)
            Toggle("Show Hidden (\(hiddenCount))", isOn: $showHidden)
        } label: {
            Image(systemName: isFiltering ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Filter. Right-click a row to hide it.")
    }

    private func summary(_ workload: Workload) -> some View {
        let stale = workload.openPullRequests.filter(Workload.isStale).count
        return HStack(spacing: 12) {
            CountBadge(count: workload.openPullRequests.count, systemImage: "arrow.triangle.pull", help: "Open pull requests", tint: .blue)
            CountBadge(count: stale, systemImage: "clock.badge.exclamationmark", help: "Open PRs with no activity for \(Workload.staleAfterDays) days", tint: .orange)
            CountBadge(count: workload.mergedPullRequests.count, systemImage: "checkmark.circle", help: "Merged in the last \(workload.snapshot.lookbackDays) days", tint: .purple)
            CountBadge(count: workload.assignedIssues.count, systemImage: "smallcircle.filled.circle", help: "Open assigned issues", tint: .green)
            if workload.team == nil {
                CountBadge(count: workload.unassignedIssues.count, systemImage: "circle.dashed", help: "Open unassigned issues")
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
    }

    // MARK: Lists

    @ViewBuilder
    private func list(_ workload: Workload) -> some View {
        switch tab {
        case .dashboard:
            OverviewView(org: org, workload: workload, metrics: metrics, selection: $selection)
        case .people: personView(workload)
        case .pullRequests: pullRequestList(workload)
        case .issues: issueList(workload)
        case .repositories: repositoryList(workload)
        case .settings: EmptyView()
        }
    }

    private func repositoryList(_ workload: Workload) -> some View {
        let repositories = workload.repositories.filter { query.isEmpty || matches($0.name) }
        let active = repositories.filter { !$0.openPullRequests.isEmpty || !$0.issues.isEmpty }
        let quiet = repositories.filter { $0.openPullRequests.isEmpty && $0.issues.isEmpty }
        return List(selection: $selection) {
            Section("Open work (\(active.count))") {
                ForEach(active) { repository in
                    RepositoryRow(repository: repository).tag(DetailSelection.repository(repository.id))
                }
            }
            if !quiet.isEmpty {
                Section("Merged only (\(quiet.count))") {
                    ForEach(quiet) { repository in
                        RepositoryRow(repository: repository).tag(DetailSelection.repository(repository.id))
                    }
                }
            }
        }
    }

    /// The person picked in the sidebar, or everyone's stats until then.
    @ViewBuilder
    private func personView(_ workload: Workload) -> some View {
        if let person, let load = workload.load(for: person) {
            PersonColumn(load: load, workload: workload, selection: $selection)
        } else if person != nil {
            ContentUnavailableView(
                "Not in this view",
                systemImage: "eye.slash",
                description: Text("They're excluded, or not in the selected team.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            PeopleStatsView(org: org, metrics: metrics, selection: $selection)
        }
    }

    private func pullRequestList(_ workload: Workload) -> some View {
        let open = workload.openPullRequests.filter(matches)
        let merged = workload.mergedPullRequests.filter(matches)
        return List(selection: $selection) {
            Section("Open (\(open.count))") {
                ForEach(open) { pr in
                    PullRequestRow(pr: pr).tag(DetailSelection.pullRequest(pr.id))
                }
            }
            Section("Merged in the last \(workload.snapshot.lookbackDays) days (\(merged.count))") {
                ForEach(merged) { pr in
                    PullRequestRow(pr: pr).tag(DetailSelection.pullRequest(pr.id))
                }
            }
        }
    }

    private func issueList(_ workload: Workload) -> some View {
        let assigned = workload.assignedIssues.filter(matches)
        let unassigned = workload.unassignedIssues.filter(matches)
        return List(selection: $selection) {
            Section("Assigned (\(assigned.count))") {
                ForEach(assigned) { issue in
                    IssueRow(issue: issue, linkedCount: workload.linkedPullRequests(for: issue).count)
                        .tag(DetailSelection.issue(issue.id))
                }
            }
            if workload.team == nil {
                Section("Unassigned (\(unassigned.count))") {
                    ForEach(unassigned) { issue in
                        IssueRow(issue: issue, linkedCount: workload.linkedPullRequests(for: issue).count)
                            .tag(DetailSelection.issue(issue.id))
                    }
                }
            }
        }
    }

    // MARK: Filtering

    private var query: String { searchText.trimmingCharacters(in: .whitespaces) }

    private func matches(_ text: String) -> Bool {
        text.localizedCaseInsensitiveContains(query)
    }

    private func matches(_ person: Person) -> Bool {
        query.isEmpty || matches(person.login) || matches(person.displayName)
    }

    private func matches(_ pr: PullRequest) -> Bool {
        query.isEmpty || matches(pr.title) || matches(pr.repo) || matches("#\(pr.number)")
            || pr.workers.contains(where: matches) || pr.requestedReviewers.contains(where: matches)
    }

    private func matches(_ issue: Issue) -> Bool {
        query.isEmpty || matches(issue.title) || matches(issue.repo) || matches("#\(issue.number)")
            || issue.assignees.contains(where: matches) || issue.labels.contains { matches($0.name) }
    }
}

// MARK: - Rows

struct RepositoryRow: View {
    let repository: RepositoryLoad

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(repository.shortName)
                    .fontWeight(.medium)
                    .lineLimit(1)
                HStack(spacing: 10) {
                    CountBadge(count: repository.openPullRequests.count, systemImage: "arrow.triangle.pull", help: "Open pull requests", tint: .blue)
                    if !repository.stalePullRequests.isEmpty {
                        CountBadge(count: repository.stalePullRequests.count, systemImage: "clock.badge.exclamationmark", help: "Stale pull requests", tint: .orange)
                    }
                    CountBadge(count: repository.mergedPullRequests.count, systemImage: "checkmark.circle", help: "Merged recently", tint: .purple)
                    CountBadge(count: repository.issues.count, systemImage: "smallcircle.filled.circle", help: "Open issues", tint: .green)
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

struct PullRequestRow: View {
    let pr: PullRequest

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Pill(text: pr.statusText, color: pr.statusColor)
                    Text(pr.title).lineLimit(1)
                }
                HStack(spacing: 4) {
                    Text("\(pr.repo)#\(pr.number)")
                    if let author = pr.author {
                        Text("by \(author.login)")
                    }
                    Text("·")
                    RelativeDate(date: pr.mergedAt ?? pr.updatedAt)
                    if Workload.isStale(pr) {
                        Image(systemName: "clock.badge.exclamationmark")
                            .foregroundStyle(.orange)
                            .help("No activity for \(Workload.staleAfterDays) days")
                    }
                    if !pr.linkedIssues.isEmpty {
                        Label("\(pr.linkedIssues.count)", systemImage: "link")
                            .help("Linked issues")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer()
            AvatarStack(people: pr.assignees.isEmpty ? pr.author.map { [$0] } ?? [] : pr.assignees)
        }
        .padding(.vertical, 2)
        .hideable(pr.id, url: pr.url)
    }
}

struct IssueRow: View {
    let issue: Issue
    let linkedCount: Int

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(issue.title).lineLimit(1)
                HStack(spacing: 4) {
                    Text("\(issue.repo)#\(issue.number)")
                    Text("·")
                    RelativeDate(date: issue.updatedAt)
                    if linkedCount > 0 {
                        Label("\(linkedCount)", systemImage: "arrow.triangle.pull")
                            .help("Linked pull requests")
                    }
                    ForEach(issue.labels.prefix(3), id: \.self) { LabelChip(label: $0) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer()
            AvatarStack(people: issue.assignees)
        }
        .padding(.vertical, 2)
        .hideable(issue.id, url: issue.url)
    }
}
