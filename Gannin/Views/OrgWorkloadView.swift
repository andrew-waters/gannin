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
                // The org's settings, whichever project the window has picked.
                OrgSettingsView(org: org)
                    .environment(configs.root)
            } else if tab == .actions {
                ActionsView(org: org, selection: $selection)
            } else if tab == .harness {
                HarnessView(org: org, selection: $selection)
            } else if tab == .agents || tab == .ask {
                // Ask is the sidebar's New Ask button now; a window saved
                // on its old row shows Agents, which lists Ask sessions.
                AgentsPage(org: org)
            } else if tab == .agentMetrics {
                AgentMetricsPage(org: org)
            } else if tab == .routines {
                RoutinesPage(org: org)
            } else if tab == .epics {
                EpicsView(org: org)
            } else if tab == .releases {
                ReleasesView(org: org)
            } else if tab == .repositories {
                // Clones on this Mac need no workload; their GitHub side does.
                repositoryView(workload)
            } else if tab == .hygiene {
                BoardHygieneView(org: org)
            } else if tab == .recap {
                RecapView(org: org)
            } else if tab == .scorecard {
                ScorecardView(org: org)
            } else if tab == .planning {
                PlanningPage(org: org)
            } else if tab == .prioritisation, let workload {
                PrioritisationView(org: org, workload: workload, selection: $selection)
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
            } else if tab == .inbox || tab == .delivery || tab == .issueFlow || tab == .investments || tab == .pullRequests || (tab == .people && person == nil) || tab == .issues, let workload {
                // Investments, the people and repo stats pages, Pull
                // Requests and every issue page: no counts bar.
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
            // A board's page has its own, for its column and filter.
            if [.inbox, .issues, .epics, .prioritisation, .hygiene, .views].contains(tab) || (tab == .projects && project == nil) {
                ToolbarItem { NewIssueButton() }
            }
        }
        .task {
            // Loops rather than running once, so a window left open on this
            // org keeps picking up new PRs and issues as the workload
            // interval passes, not just when the org is next opened.
            while !Task.isCancelled {
                await orgs.refreshIfStale(org)
                // The investments board's fields, when stale; the board list
                // loads with the sidebar.
                if case .projectField(let number, _, _) = configs.config(for: org).investmentConfig.trackedBy, number != 0 {
                    await projects.loadDefinition(org: org, number: number)
                }
                try? await Task.sleep(for: .seconds(30))
            }
        }
        .task(id: windowDays) { await metricsStore.sync(org, windowDays: MetricsWindow(code: windowDays).syncDays()) }
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
        (workload != nil && tab != .dashboard && tab != .delivery && tab != .issueFlow && tab != .people)
            || (orgs.errors[org] != nil && workload != nil)
            || !(workload?.snapshot.warnings ?? []).isEmpty
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let workload, tab != .dashboard, tab != .delivery, tab != .issueFlow, tab != .people {
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

    /// Pages on the metrics window: Dashboard, Actions, and the People,
    /// Repositories and Issues stats (not a person, repo or list in them).
    private var hasWindowPicker: Bool {
        switch tab {
        // Investments has its own range.
        // Not the Overview, which uses whatever was picked elsewhere.
        case .delivery, .issueFlow, .actions: true
        case .people: person == nil && peopleView == nil
        // Repositories has its own, in the bar on its Delivery part.
        case .repositories: false
        default: false
        }
    }

    private var windowPicker: some View {
        MetricsWindowPicker(code: $windowDays)
    }

    // MARK: Lists

    @ViewBuilder
    private func list(_ workload: Workload) -> some View {
        switch tab {
        case .inbox:
            InboxView(org: org, workload: workload)
        case .dashboard:
            OverviewView(org: org, workload: workload, metrics: metrics, selection: $selection, windowDays: $windowDays)
        case .delivery:
            OverviewView(org: org, workload: workload, metrics: metrics, selection: $selection, windowDays: $windowDays, part: .delivery)
        case .issueFlow:
            IssuesStatsView(org: org, workload: workload, selection: $selection)
        case .people: personView(workload)
        case .pullRequests: PullRequestsView(workload: workload, selection: $selection)
        case .issues:
            if issueList == .notOnBoard {
                OffBoardIssuesView(org: org, team: workload.team)
            } else {
                // The Issues row itself is every issue, as All is.
                OpenIssuesView(org: org, workload: workload, selection: $selection)
            }
        case .repositories: EmptyView()
        // Across everyone: a team picked on another page doesn't carry over.
        case .investments: InvestmentsView(org: org, team: nil, selection: $selection)
        case .projects, .actions, .harness, .views, .prioritisation, .planning, .recap, .scorecard, .agents, .agentMetrics, .routines, .ask, .epics, .hygiene, .releases, .settings: EmptyView()
        }
    }

    /// One repo at a time, picked in the page's switcher; the sidebar and
    /// palette can ask for one.
    private func repositoryView(_ workload: Workload?) -> some View {
        RepositoriesPage(org: org, workload: workload, requested: repository, selection: $selection)
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
                    Text("·")
                    LinesText(added: pr.additions, removed: pr.deletions, files: pr.changedFiles)
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
    let linked: [LinkedItem]

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
                    if !linked.isEmpty {
                        LinkedPullRequestsBadge(
                            count: linked.count,
                            tint: linked.linkedPullRequestsTint,
                            anyMerged: linked.contains(where: \.isMerged)
                        )
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
