import SwiftUI

// MARK: - Person

struct PersonDetailView: View {
    let load: PersonLoad
    let workload: Workload
    @Binding var selection: DetailSelection?

    var body: some View {
        DetailScroll {
            HStack(spacing: 14) {
                Avatar(url: load.person.avatarUrl, size: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text(load.person.displayName).font(.title2.weight(.semibold))
                    Link(load.person.login, destination: URL(string: "https://github.com/\(load.person.login)")!)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Text("\(load.inFlight)").font(.largeTitle.monospacedDigit().weight(.semibold))
                    Text("in flight").font(.caption).foregroundStyle(.secondary)
                }
            }

            PullRequestSection(title: "Pull requests", prs: load.pullRequests, workload: workload, selection: $selection)
            PullRequestSection(title: "Waiting on their review", prs: load.reviewRequests, workload: workload, selection: $selection)

            DetailSection(title: "Assigned issues", count: load.issues.count) {
                ForEach(load.issues) { issue in
                    SelectableRow(target: .issue(issue.id), selection: $selection) {
                        IssueRow(issue: issue, linkedCount: workload.linkedPullRequests(for: issue).count)
                    }
                }
            }

            PullRequestSection(
                title: "Merged in the last \(workload.snapshot.lookbackDays) days",
                prs: load.merged,
                workload: workload,
                selection: $selection
            )
        }
    }
}

private struct PullRequestSection: View {
    let title: String
    let prs: [PullRequest]
    let workload: Workload
    @Binding var selection: DetailSelection?

    var body: some View {
        DetailSection(title: title, count: prs.count) {
            ForEach(prs) { pr in
                VStack(alignment: .leading, spacing: 4) {
                    SelectableRow(target: .pullRequest(pr.id), selection: $selection) {
                        PullRequestRow(pr: pr)
                    }
                    ForEach(pr.linkedIssues) { item in
                        LinkedItemRow(item: item, kind: .issue, workload: workload, selection: $selection)
                            .padding(.leading, 18)
                    }
                }
            }
        }
    }
}

// MARK: - Pull request

struct PullRequestDetailView: View {
    let pr: PullRequest
    let workload: Workload
    @Binding var selection: DetailSelection?

    var body: some View {
        DetailScroll {
            DetailHeader(
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
                GridRow {
                    Text("Size").foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Text("+\(pr.additions)").foregroundStyle(.green)
                        Text("-\(pr.deletions)").foregroundStyle(.red)
                    }
                    .monospacedDigit()
                }
                GridRow {
                    Text("Opened").foregroundStyle(.secondary)
                    RelativeDate(date: pr.createdAt)
                }
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

            DetailSection(title: "Linked issues", count: pr.linkedIssues.count) {
                ForEach(pr.linkedIssues) { item in
                    LinkedItemRow(item: item, kind: .issue, workload: workload, selection: $selection)
                }
            }
        }
    }
}

// MARK: - Issue

struct IssueDetailView: View {
    let issue: Issue
    let workload: Workload
    @Binding var selection: DetailSelection?

    var body: some View {
        let linked = workload.linkedPullRequests(for: issue)
        DetailScroll {
            DetailHeader(
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
                GridRow {
                    Text("Opened").foregroundStyle(.secondary)
                    RelativeDate(date: issue.createdAt)
                }
                GridRow {
                    Text("Last activity").foregroundStyle(.secondary)
                    RelativeDate(date: issue.updatedAt)
                }
            }

            DetailSection(title: "Linked pull requests", count: linked.count) {
                ForEach(linked) { item in
                    LinkedItemRow(item: item, kind: .pullRequest, workload: workload, selection: $selection)
                }
            }
        }
    }
}

// MARK: - Building blocks

private struct DetailScroll<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                content
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct DetailHeader: View {
    let title: String
    let reference: String
    let url: URL
    let pill: Pill

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.title2.weight(.semibold))
                .textSelection(.enabled)
            HStack(spacing: 8) {
                pill
                Text(reference).foregroundStyle(.secondary)
                Spacer()
                Link(destination: url) {
                    Label("Open on GitHub", systemImage: "arrow.up.right.square")
                }
            }
        }
    }
}

private struct DetailSection<Content: View>: View {
    let title: String
    let count: Int
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title).font(.headline)
                Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
            }
            if count == 0 {
                Text("None").foregroundStyle(.tertiary)
            } else {
                content
            }
        }
    }
}

/// A row that moves the detail pane to another item when clicked.
private struct SelectableRow<Content: View>: View {
    let target: DetailSelection
    @Binding var selection: DetailSelection?
    @ViewBuilder let content: Content

    var body: some View {
        Button {
            selection = target
        } label: {
            content.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                    }
                }
            }
        }
    }
}

/// A linked issue or PR. Selects it when it's part of this snapshot,
/// otherwise opens it on GitHub.
private struct LinkedItemRow: View {
    enum Kind { case issue, pullRequest }

    @Environment(\.openURL) private var openURL
    let item: LinkedItem
    let kind: Kind
    let workload: Workload
    @Binding var selection: DetailSelection?

    var body: some View {
        Button {
            switch kind {
            case .issue where workload.issue(id: item.id) != nil:
                selection = .issue(item.id)
            case .pullRequest where workload.pullRequest(id: item.id) != nil:
                selection = .pullRequest(item.id)
            default:
                openURL(item.url)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: kind == .issue ? "smallcircle.filled.circle" : "arrow.triangle.pull")
                    .foregroundStyle(item.stateColor)
                Text(item.title).lineLimit(1)
                Text("\(item.repo)#\(item.number)")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .font(.callout)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
