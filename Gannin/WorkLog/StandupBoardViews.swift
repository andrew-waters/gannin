import SwiftUI

/// Walk the Board: the four columns side by side (stacked when narrow), or
/// the one on screen while presenting.
struct StandupBoardColumns: View {
    let org: String
    let workload: Workload?
    let board: StandupBoard
    let presenting: Bool
    /// The only column shown, while presenting; nil for all four.
    let column: StandupBoard.Column?
    let onDiscuss: (StandupBoard.Item) -> Void
    @State private var width: CGFloat = 1200

    var body: some View {
        Group {
            if let column {
                columnView(column)
            } else if width >= 900 {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(StandupBoard.Column.allCases) { columnView($0) }
                }
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(StandupBoard.Column.allCases) { columnView($0) }
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private func columnView(_ column: StandupBoard.Column) -> some View {
        StandupColumn(org: org, workload: workload, column: column, board: board, presenting: presenting, onDiscuss: onDiscuss)
    }
}

/// One person's tickets, in the columns that have any: compact, without
/// avatars, as they're all theirs.
struct StandupTickets: View {
    let org: String
    let board: StandupBoard
    let presenting: Bool
    let isWide: Bool
    let onDiscuss: ((StandupBoard.Item) -> Void)?

    var body: some View {
        let columns = StandupBoard.Column.allCases.filter { board.count($0) > 0 }
        if isWide {
            HStack(alignment: .top, spacing: 10) {
                ForEach(columns) { column(for: $0) }
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(columns) { column(for: $0) }
            }
        }
    }

    private func column(for column: StandupBoard.Column) -> some View {
        StandupColumn(org: org, workload: nil, column: column, board: board, presenting: presenting, isCompact: true, onDiscuss: onDiscuss)
    }
}

/// A column of the board: its title and count, then its issues, under each
/// assignee when there's a workload to name them. Done lists what's to
/// discuss first.
struct StandupColumn: View {
    let org: String
    /// Groups the issues by assignee; nil lists them as they are.
    let workload: Workload?
    let column: StandupBoard.Column
    let board: StandupBoard
    let presenting: Bool
    var isCompact = false
    let onDiscuss: ((StandupBoard.Item) -> Void)?

    var body: some View {
        let count = board.count(column)
        VStack(alignment: .leading, spacing: isCompact ? 6 : 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: column.symbol).foregroundStyle(column.tint)
                Text(column.title)
                    .font(presenting ? .title2.weight(.semibold) : isCompact ? .subheadline.weight(.semibold) : .headline)
                Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
                Spacer(minLength: 0)
            }
            if column == .done && !board.discussion.isEmpty {
                subheading("To discuss")
                cards(board.discussion)
                if !board.items(.done).isEmpty { subheading("Done") }
            }
            cards(board.items(column))
            if count == 0 {
                Text(emptyText)
                    .font(presenting ? .title3 : .callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
        }
        .padding(isCompact ? 10 : presenting ? 18 : 14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func cards(_ items: [StandupBoard.Item]) -> some View {
        if let workload {
            ForEach(Self.byAssignee(items), id: \.login) { group in
                VStack(alignment: .leading, spacing: 6) {
                    assignee(group.login.map(workload.person(login:)), count: group.items.count)
                    ForEach(group.items) { card($0) }
                }
                .padding(.top, 2)
            }
        } else {
            ForEach(items) { card($0) }
        }
    }

    /// The items under each assignee, by name, then the unassigned; an
    /// issue with two assignees is under both.
    static func byAssignee(_ items: [StandupBoard.Item]) -> [(login: String?, items: [StandupBoard.Item])] {
        var groups: [String: [StandupBoard.Item]] = [:]
        var unassigned: [StandupBoard.Item] = []
        for item in items {
            if item.record.assignees.isEmpty { unassigned.append(item) }
            for login in item.record.assignees { groups[login, default: []].append(item) }
        }
        let named: [(login: String?, items: [StandupBoard.Item])] = groups.keys
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { ($0, groups[$0] ?? []) }
        return unassigned.isEmpty ? named : named + [(nil, unassigned)]
    }

    private func assignee(_ person: Person?, count: Int) -> some View {
        HStack(spacing: 6) {
            if let person {
                Avatar(url: person.avatarUrl, size: presenting ? 24 : 18)
                Text(person.displayName)
            } else {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .foregroundStyle(.secondary)
                Text("Unassigned").foregroundStyle(.secondary)
            }
            Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
        }
        .font(presenting ? .headline : .subheadline.weight(.medium))
        .lineLimit(1)
    }

    private func card(_ item: StandupBoard.Item) -> some View {
        StandupIssueCard(org: org, item: item, presenting: presenting, isCompact: isCompact, onDiscuss: onDiscuss)
    }

    private func subheading(_ text: String) -> some View {
        Text(text)
            .font(presenting ? .headline : .caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 2)
    }

    private var emptyText: String {
        switch column {
        case .done: "Nothing in a done status, and nothing to discuss."
        case .review: "Nothing in review."
        case .progress: "Nothing in progress."
        case .triage: "Nothing to triage: every open issue has a Status."
        }
    }
}

extension StandupBoard.Column {
    var tint: Color {
        switch self {
        case .done: ChartPalette.good
        case .review: .purple
        case .progress: ChartPalette.blue
        case .triage: .orange
        }
    }
}

/// An issue on the standup, as a tile like a board card: its title, then
/// where it is and since when, with a mark when it's to discuss. Opens in
/// the drawer; its menu marks it for discussion, or discussed.
struct StandupIssueCard: View {
    @Environment(\.navigate) private var navigate
    let org: String
    let item: StandupBoard.Item
    let presenting: Bool
    var isCompact = false
    let onDiscuss: ((StandupBoard.Item) -> Void)?

    var body: some View {
        let reference = IssueReference(org: org, record: item.record)
        Button {
            navigate?(.issueReference(reference))
        } label: {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.record.title)
                        .font(presenting ? .title3 : .body)
                        .lineLimit(presenting ? 3 : 2)
                        .multilineTextAlignment(.leading)
                    Text(verbatim: detail)
                        .font(presenting ? .callout : .caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if item.needsDiscussion {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .foregroundStyle(.orange)
                        .help("To discuss")
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(isCompact ? 8 : presenting ? 14 : 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.record.title)
        .hideable(item.record.id, url: item.record.url, opens: .issueReference(reference)) {
            if let onDiscuss {
                Button(item.needsDiscussion ? "Discussed" : "Needs Discussion") { onDiscuss(item) }
            }
        }
    }

    /// "api#12 · In Review · moved 3 days ago".
    private var detail: String {
        let when = item.since.formatted(.relative(presentation: .named))
        return [
            StandupRow.number(item.record.repo, item.record.number),
            item.status ?? (item.isOnBoard ? "No status" : "Not on the board"),
            item.since == item.record.createdAt ? "opened \(when)" : "moved \(when)",
        ].joined(separator: " · ")
    }
}

// MARK: - Discussion

/// The discussion label going on an issue, or coming off it.
struct StandupDiscussion: Identifiable {
    let issue: IssueRecord
    let label: String
    /// Adding the label; else taking it off.
    let adding: Bool

    var id: String { issue.id }

    /// Writes the change on GitHub, creating the label in the repo if it's
    /// missing, then records the issue's labels.
    func write(org: String, api: GitHubAPI, issues: IssueStore, projects: ProjectStore) async throws {
        let parts = issue.repo.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return }
        let found = try await api.repositoryLabel(owner: parts[0], repo: parts[1], name: label)
        var labels = issue.labels.filter { $0.caseInsensitiveCompare(label) != .orderedSame }
        if adding {
            var id = found.labelID
            if id == nil { id = try await api.createLabel(label, repositoryID: found.repositoryID) }
            if let id { try await api.addLabel(id, to: issue.id) }
            labels.append(label)
        } else if let id = found.labelID {
            try await api.removeLabel(id, from: issue.id)
        }
        IssueEdits.setLabels(org: org, issueID: issue.id, labels: labels, issues: issues, projects: projects)
    }
}

/// Confirms the discussion label's change before it's written to GitHub.
struct StandupDiscussionSheet: View {
    @Environment(AuthStore.self) private var auth
    @Environment(IssueStore.self) private var issues
    @Environment(ProjectStore.self) private var projects
    let org: String
    let change: StandupDiscussion
    let onClose: () -> Void

    var body: some View {
        BulkWriteSheet(
            title: change.adding ? "Mark the issue for discussion?" : "Mark the issue as discussed?",
            explanation: change.adding
                ? "Adds the \"\(change.label)\" label to it on GitHub, creating the label in its repo if it's missing."
                : "Takes the \"\(change.label)\" label off it on GitHub.",
            action: change.adding ? "Add Label" : "Remove Label",
            rows: [.init(id: change.issue.id, title: change.issue.title, detail: "\(change.issue.repo)#\(String(change.issue.number))")]
        ) { _ in
            guard let api = auth.api else { throw InvestmentWriteError.message("Not signed in") }
            try await change.write(org: org, api: api, issues: issues, projects: projects)
        } onClose: {
            onClose()
        }
    }
}
