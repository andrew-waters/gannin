import SwiftUI

/// Identifies an issue for its own window, with enough to draw a header
/// when no store holds it.
struct IssueReference: Codable, Hashable {
    let org: String
    let id: String
    let number: Int
    let title: String
    let repo: String
    let url: URL

    init(org: String, id: String, number: Int, title: String, repo: String, url: URL) {
        self.org = org
        self.id = id
        self.number = number
        self.title = title
        self.repo = repo
        self.url = url
    }

    init(org: String, record: IssueRecord) {
        self.org = org
        id = record.id
        number = record.number
        title = record.title
        repo = record.repo
        url = record.url
    }
}

/// An issue in a window of its own: its dates and people, time in progress
/// under the org's workflow, board history, linked PRs and description.
struct IssueWindow: View {
    @Environment(IssueStore.self) private var store
    @Environment(RoutineStore.self) private var routines
    @Environment(OrgConfigStore.self) private var configs
    @Environment(DetailStore.self) private var details
    let reference: IssueReference
    /// Shown as a page in a main window rather than a window of its own:
    /// the main window has the title and the investment prompt.
    var isEmbedded = false

    var body: some View {
        let record = store.history(for: reference.org)?.issues[reference.id]
        let workflow = configs.config(for: reference.org).workflow
        VStack(spacing: 0) {
            header(record: record, workflow: workflow)
            Divider()
            HStack(spacing: 0) {
                details(record: record, workflow: workflow)
                    .frame(minWidth: 480, maxWidth: .infinity)
                Divider()
                // Board fields on the right, like GitHub's issue sidebar.
                Form {
                    // Tracked in a board field, it's among the fields below.
                    if !configs.config(for: reference.org).investmentConfig.trackedBy.isBoardField {
                        Section("Investment") {
                            CategoriseMenu(issueID: reference.id, org: reference.org)
                        }
                    }
                    ProjectFieldsSections(org: reference.org, issueID: reference.id)
                }
                .formStyle(.grouped)
                .frame(width: 340)
            }
        }
        .frame(minWidth: isEmbedded ? nil : 860, minHeight: isEmbedded ? nil : 480)
        .ownWindowTitle(isEmbedded ? nil : "\(reference.repo)#\(reference.number)", subtitle: reference.title)
        .task(id: reference.id) { await details.load(reference.id) }
        .loadsHarness(org: reference.org)
        .modifier(OwnInvestmentPrompt(isEnabled: !isEmbedded))
        .toolbar {
            ToolbarItem { PlanThisButton(reference: reference) }
            ToolbarItem { StartSessionButton(reference: reference) }
            ToolbarItem { ScheduleForAgentButton(reference: reference) }
        }
    }

    /// Full width across the top: the title and the headline facts.
    private func header(record: IssueRecord?, workflow: IssueWorkflow) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ItemHeader(title: reference.title, reference: "\(reference.repo)#\(reference.number)", url: reference.url, pill: pill(record),
                       accessory: AnyView(ScheduledForAgentPill(routines: routines, issueID: reference.id)))
            if let record {
                let timing = IssueTiming(record, workflow: workflow, now: .now)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 16, alignment: .topLeading)], alignment: .leading, spacing: 12) {
                    fact("Created", record.createdAt.formatted(date: .abbreviated, time: .omitted))
                    if let author = record.author { fact("Opened by", author) }
                    if let closedAt = record.closedAt {
                        fact(record.isNotPlanned ? "Closed, not planned" : "Closed", closedAt.formatted(date: .abbreviated, time: .omitted))
                    }
                    if !record.assignees.isEmpty { fact("Assignees", record.assignees.joined(separator: ", ")) }
                    if let type = record.issueType { fact("Type", type) }
                    fact("In progress", timing.cycleTime.map { "\($0.compactDuration)\(timing.isInProgress ? " so far" : "")" } ?? "Not started")
                    if let lead = timing.leadTime { fact("Lead time", lead.compactDuration) }
                    if let efficiency = timing.flowEfficiency { fact("Flow efficiency", efficiency.formatted(.percent.precision(.fractionLength(0)))) }
                    if let creep = timing.scopeCreep { fact("Scope creep", "\(creep.formatted(.percent.precision(.fractionLength(0)))) of \(record.subIssuesAddedAt.count)") }
                    if record.reopenedAt.count > 0 { fact("Reopened", record.reopenedAt.count == 1 ? "Once" : "\(record.reopenedAt.count) times") }
                }
                if !record.labels.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(record.labels, id: \.self) { label in
                            Text(label)
                                .font(.caption)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private func details(record: IssueRecord?, workflow: IssueWorkflow) -> some View {
        List {
            HarnessIssueSection(reference: reference)
            IssueTimelineSection(reference: reference)
            if let record {
                let changes = record.statusChanges.filter(workflow.counts)
                if !changes.isEmpty {
                    Section(header: SectionHeader(title: "Board status", count: changes.count)) {
                        ForEach(Array(changes.enumerated()), id: \.offset) { _, change in
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(workflow.isInProgress(change.status) ? ChartPalette.blue : Color.secondary.opacity(0.4))
                                    .frame(width: 8, height: 8)
                                Text(change.status)
                                if let project = change.projectTitle { Text(project).foregroundStyle(.secondary) }
                                Spacer()
                                Text(change.at.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if !record.linkedPullRequests.isEmpty {
                    Section(header: SectionHeader(title: "Linked pull requests", count: record.linkedPullRequests.count)) {
                        ForEach(record.linkedPullRequests, id: \.url) { pr in LinkedPullRequestRow(pr: pr) }
                    }
                }
                if let mentioned = record.mentionedInPullRequests, !mentioned.isEmpty {
                    Section(header: SectionHeader(title: "Mentioned in pull requests", count: mentioned.count)) {
                        ForEach(mentioned, id: \.url) { pr in LinkedPullRequestRow(pr: pr, systemImage: "at") }
                    }
                }
            }
            DescriptionSections(id: reference.id, url: reference.url)
        }
    }

    private func pill(_ record: IssueRecord?) -> Pill {
        guard let record else { return Pill(text: "Issue", color: .secondary) }
        if record.isOpen { return Pill(text: "Open", color: .green) }
        if record.isNotPlanned { return Pill(text: "Not planned", color: .secondary) }
        return Pill(text: "Completed", color: .purple)
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .lineLimit(2)
        }
    }
}
