import SwiftUI

// Each column is a List whose selection opens the next column to its right.

// MARK: - Person

struct PersonColumn: View {
    let load: PersonLoad
    let workload: Workload
    @Binding var selection: DetailSelection?

    var body: some View {
        List(selection: $selection) {
            Section {
                HStack(spacing: 12) {
                    Avatar(url: load.person.avatarUrl, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(load.person.displayName).font(.title3.weight(.semibold))
                        Link(load.person.login, destination: URL(string: "https://github.com/\(load.person.login)")!)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text("\(load.inFlight)").font(.title.monospacedDigit().weight(.semibold))
                        Text("in flight").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            pullRequestSection("Pull requests", load.pullRequests)
            pullRequestSection("Waiting on their review", load.reviewRequests)

            Section(header: SectionHeader(title: "Assigned issues", count: load.issues.count)) {
                ForEach(load.issues) { issue in
                    IssueRow(issue: issue, linkedCount: workload.linkedPullRequests(for: issue).count)
                        .tag(DetailSelection.issue(issue.id))
                }
            }

            pullRequestSection("Merged in the last \(workload.snapshot.lookbackDays) days", load.merged)
        }
    }

    private func pullRequestSection(_ title: String, _ prs: [PullRequest]) -> some View {
        Section(header: SectionHeader(title: title, count: prs.count)) {
            ForEach(prs) { pr in
                PullRequestRow(pr: pr).tag(DetailSelection.pullRequest(pr.id))
            }
        }
    }
}

// MARK: - Issue

struct IssueColumn: View {
    @Environment(DetailStore.self) private var details
    let issue: Issue
    let workload: Workload
    @Binding var selection: DetailSelection?

    var body: some View {
        let linked = workload.linkedPullRequests(for: issue)
        List(selection: $selection) {
            Section {
                ItemHeader(
                    title: issue.title,
                    reference: "\(issue.repo)#\(issue.number)",
                    url: issue.url,
                    pill: Pill(text: issue.assignees.isEmpty ? "Unassigned" : "Open", color: issue.assignees.isEmpty ? .gray : .green)
                )
                if !issue.labels.isEmpty {
                    HStack { ForEach(issue.labels, id: \.self) { LabelChip(label: $0) } }
                }
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    PeopleGridRow(title: "Assignees", people: issue.assignees, selection: $selection)
                    if let author = issue.author {
                        PeopleGridRow(title: "Opened by", people: [author], selection: $selection)
                    }
                    DateGridRow(title: "Opened", date: issue.createdAt)
                    DateGridRow(title: "Last activity", date: issue.updatedAt)
                }
                .padding(.vertical, 4)
            }

            Section(header: SectionHeader(title: "Linked pull requests", count: linked.count)) {
                ForEach(linked) { item in
                    if let pr = workload.pullRequest(id: item.id) {
                        PullRequestRow(pr: pr).tag(DetailSelection.pullRequest(pr.id))
                    } else {
                        ExternalItemRow(item: item, systemImage: "arrow.triangle.pull")
                    }
                }
            }

            DescriptionSections(id: issue.id, url: issue.url)
        }
        .task(id: issue.id) { await details.load(issue.id) }
    }
}

// MARK: - Pull request

struct PullRequestColumn: View {
    @Environment(DetailStore.self) private var details
    let pr: PullRequest
    let workload: Workload
    @Binding var selection: DetailSelection?

    var body: some View {
        let detail = details.detail(for: pr.id)
        List(selection: $selection) {
            Section {
                ItemHeader(
                    title: pr.title,
                    reference: "\(pr.repo)#\(pr.number)",
                    url: pr.url,
                    pill: Pill(text: pr.statusText, color: pr.statusColor)
                )
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    if let author = pr.author {
                        PeopleGridRow(title: "Author", people: [author], selection: $selection)
                    }
                    PeopleGridRow(title: "Assignees", people: pr.assignees, selection: $selection)
                    PeopleGridRow(title: "Review requested", people: pr.requestedReviewers, selection: $selection)
                    PeopleGridRow(title: "Reviewed by", people: pr.reviewers, selection: $selection)
                    if let head = detail?.headRef, let base = detail?.baseRef {
                        GridRow {
                            Text("Branch").foregroundStyle(.secondary)
                            Text("\(head) → \(base)")
                                .font(.callout.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                    }
                    if let checks = detail?.checks {
                        GridRow {
                            Text("Checks").foregroundStyle(.secondary)
                            ChecksLabel(state: checks)
                        }
                    }
                    GridRow {
                        Text("Size").foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            Text("+\(pr.additions)").foregroundStyle(.green)
                            Text("-\(pr.deletions)").foregroundStyle(.red)
                        }
                        .monospacedDigit()
                    }
                    DateGridRow(title: "Opened", date: pr.createdAt)
                    GridRow {
                        Text(pr.isMerged ? "Merged" : "Last activity").foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            RelativeDate(date: pr.mergedAt ?? pr.updatedAt)
                            if Workload.isStale(pr) {
                                Pill(text: "Stale", color: .orange)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Section(header: SectionHeader(title: "Linked issues", count: pr.linkedIssues.count)) {
                ForEach(pr.linkedIssues) { item in
                    if let issue = workload.issue(id: item.id) {
                        IssueRow(issue: issue, linkedCount: workload.linkedPullRequests(for: issue).count)
                            .tag(DetailSelection.issue(issue.id))
                    } else {
                        ExternalItemRow(item: item, systemImage: "smallcircle.filled.circle")
                    }
                }
            }

            DescriptionSections(id: pr.id, url: pr.url)
        }
        .task(id: pr.id) { await details.load(pr.id) }
    }
}

// MARK: - Description and comments

/// Body and recent comments, loaded on demand through `DetailStore`.
private struct DescriptionSections: View {
    @Environment(DetailStore.self) private var details
    let id: String
    let url: URL

    var body: some View {
        if let detail = details.detail(for: id) {
            Section("Description") {
                if detail.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("No description").foregroundStyle(.tertiary)
                } else {
                    MarkdownText(source: detail.body)
                        .padding(.vertical, 4)
                }
            }
            Section(header: SectionHeader(title: "Comments", count: detail.commentCount)) {
                if detail.commentCount > detail.recentComments.count {
                    Link("\(detail.commentCount - detail.recentComments.count) earlier comments on GitHub", destination: url)
                        .font(.callout)
                }
                ForEach(detail.recentComments) { comment in
                    CommentView(comment: comment)
                }
            }
        } else if let error = details.errors[id] {
            Section("Description") {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                Button("Try Again") { Task { await details.load(id, force: true) } }
            }
        } else {
            Section("Description") {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading").foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct CommentView: View {
    let comment: Comment

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Avatar(url: comment.author?.avatarUrl, size: 18)
                Text(comment.author?.login ?? "ghost").fontWeight(.medium)
                RelativeDate(date: comment.createdAt)
                    .foregroundStyle(.secondary)
                Spacer()
                Link(destination: comment.url) {
                    Image(systemName: "arrow.up.right.square")
                }
                .help("Open comment on GitHub")
            }
            .font(.callout)
            MarkdownText(source: comment.body)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Building blocks

struct SectionHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

private struct ItemHeader: View {
    let title: String
    let reference: String
    let url: URL
    let pill: Pill

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                pill
                Text(reference).foregroundStyle(.secondary)
                Spacer()
                Link(destination: url) {
                    Label("Open on GitHub", systemImage: "arrow.up.right.square")
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ChecksLabel: View {
    let state: ItemDetail.CheckState

    var body: some View {
        switch state {
        case .success:
            Label("Passing", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failure, .error:
            Label("Failing", systemImage: "xmark.circle.fill").foregroundStyle(.red)
        case .pending, .expected:
            Label("Running", systemImage: "clock.fill").foregroundStyle(.orange)
        }
    }
}

private struct DateGridRow: View {
    let title: String
    let date: Date

    var body: some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            RelativeDate(date: date)
        }
    }
}

private struct PeopleGridRow: View {
    let title: String
    let people: [Person]
    @Binding var selection: DetailSelection?

    var body: some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            if people.isEmpty {
                Text("None").foregroundStyle(.tertiary)
            } else {
                HStack(spacing: 10) {
                    ForEach(people) { person in
                        Button {
                            selection = .person(person.login)
                        } label: {
                            HStack(spacing: 4) {
                                Avatar(url: person.avatarUrl, size: 18)
                                Text(person.login)
                            }
                        }
                        .buttonStyle(.plain)
                        .help("Show \(person.login)'s work")
                    }
                }
            }
        }
    }
}

/// A linked issue or PR that isn't in the snapshot (closed, or outside the
/// org), so it opens on GitHub instead of in a column.
private struct ExternalItemRow: View {
    @Environment(\.openURL) private var openURL
    let item: LinkedItem
    let systemImage: String

    var body: some View {
        Button {
            openURL(item.url)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: systemImage).foregroundStyle(item.stateColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).lineLimit(1)
                    Text("\(item.repo)#\(item.number) · \(item.state.capitalized)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.right.square").foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
