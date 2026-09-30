import SwiftUI

struct OrgWorkloadView: View {
    @Environment(OrgStore.self) private var orgs
    @Environment(ProjectStore.self) private var projects
    @Environment(OrgConfigStore.self) private var configs
    @Environment(MetricsStore.self) private var metricsStore
    @SceneStorage(MetricsStore.windowKey) private var windowDays = MetricsStore.defaultWindowDays

    let org: String
    let workload: Workload?
    let metrics: OrgMetrics?
    /// The team the stats are filtered to. Nothing picks one for now, so
    /// it stays nil (everyone); the filtering behind it is kept.
    @Binding var teamID: String?
    @Binding var tab: WorkloadTab
    /// The person picked under People in the sidebar.
    let person: String?
    /// The work log, threads or punchcards, picked under People.
    let peopleView: PeopleView?
    /// The repo picked under Repositories in the sidebar.
    let repository: String?
    /// The issue list picked under Issues in the sidebar.
    let issueList: IssueList?
    /// The board picked under Projects in the sidebar.
    @Binding var project: Int?
    /// The field view picked under Views.
    @Binding var fieldView: UUID?
    @Binding var selection: DetailSelection?
    let searchText: String

    var body: some View {
        Group {
            if tab == .settings {
                OrgSettingsView(org: org)
            } else if tab == .actions {
                ActionsView(org: org, selection: $selection)
            } else if tab == .harness {
                HarnessView(org: org, selection: $selection)
            } else if tab == .views {
                if let fieldView {
                    FieldViewPage(org: org, id: fieldView, selection: $selection)
                        .id(fieldView)
                } else {
                    FieldViewsLanding(org: org) { fieldView = $0 }
                }
            } else if tab == .projects {
                if let project {
                    ProjectBoardView(org: org, number: project)
                        .id(project)
                } else {
                    ProjectsLandingView(org: org) { project = $0 }
                }
            } else if tab == .inbox || tab == .investments || (tab == .people && person == nil) || (tab == .repositories && repository == nil) || (tab == .issues && (issueList == nil || issueList == .notOnBoard)), let workload {
                // Investments and the people and repo stats pages: no
                // counts bar.
                list(workload)
            } else {
                VStack(spacing: 0) {
                    if hasHeader {
                        header
                        Divider()
                    }
                    content
                }
            }
        }
        .toolbar {
            if hasWindowPicker {
                ToolbarItem { windowPicker }
            }
        }
        .task {
            await orgs.refreshIfStale(org)
            // The investments board's fields, when stale; the board list
            // loads with the sidebar.
            if case .projectField(let number, _, _) = configs.config(for: org).investmentConfig.trackedBy, number != 0 {
                await projects.loadDefinition(org: org, number: number)
            }
        }
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

    /// The counts on the list pages, and any refresh error or warning.
    /// Exclude Drafts and Show Hidden are in Settings.
    private var hasHeader: Bool {
        (workload != nil && tab != .dashboard && tab != .people)
            || (orgs.errors[org] != nil && workload != nil)
            || !(workload?.snapshot.warnings ?? []).isEmpty
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
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

    /// Pages on the metrics window: Dashboard, Investments, and the People,
    /// Repositories and Issues stats (not a person, repo or list in them).
    private var hasWindowPicker: Bool {
        switch tab {
        case .dashboard, .investments, .actions: true
        case .people: person == nil && peopleView == nil
        case .repositories: repository == nil
        case .issues: issueList == nil
        default: false
        }
    }

    private var windowPicker: some View {
        Picker("Window", selection: $windowDays) {
            ForEach(MetricsStore.windowOptions, id: \.self) { Text("\($0) days").tag($0) }
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .help("Window for the delivery and people stats")
    }

    // MARK: Lists

    @ViewBuilder
    private func list(_ workload: Workload) -> some View {
        switch tab {
        case .inbox:
            InboxView(org: org, workload: workload)
        case .dashboard:
            OverviewView(org: org, workload: workload, metrics: metrics, selection: $selection)
        case .people: personView(workload)
        case .pullRequests: pullRequestList(workload)
        case .issues:
            if issueList == .notOnBoard {
                OffBoardIssuesView(org: org, team: workload.team)
            } else if issueList == .open {
                OpenIssuesView(workload: workload, selection: $selection)
            } else {
                IssuesStatsView(org: org, workload: workload, selection: $selection)
            }
        case .repositories: repositoryView(workload)
        // Across everyone: a team picked on another page doesn't carry over.
        case .investments: InvestmentsView(org: org, team: nil, selection: $selection)
        case .projects, .actions, .harness, .views, .settings: EmptyView()
        }
    }

    /// The repo picked in the sidebar, or every repo's stats until then.
    @ViewBuilder
    private func repositoryView(_ workload: Workload) -> some View {
        if let repository, let load = workload.repository(named: repository) {
            RepositoryColumn(repository: load, workload: workload, selection: $selection)
        } else if repository != nil {
            ContentUnavailableView(
                "Not in this view",
                systemImage: "eye.slash",
                description: Text("It's excluded, or has no open or recent work.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            RepositoryStatsView(org: org, metrics: metrics, selection: $selection)
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
        } else if peopleView == .timeOff {
            TimeOffPage(org: org, workload: workload)
        } else if peopleView == .activity {
            WorkLogPage(org: org, workload: workload)
        } else if peopleView == .standup {
            StandupPage(org: org, workload: workload)
        } else {
            PeopleStatsView(org: org, workload: workload, metrics: metrics, selection: $selection)
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
}

// MARK: - Rows

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
                    Text("\(pr.repo)#\(String(pr.number))")
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
        .hideable(pr.id, url: pr.url, opens: .pullRequest(pr.id))
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
                    Text("\(issue.repo)#\(String(issue.number))")
                    if let author = issue.author {
                        Text("by \(author.login)")
                    }
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
        .hideable(issue.id, url: issue.url, opens: .issue(issue.id))
    }
}
