import SwiftUI

/// Issues › All: the org's issues from the issue history, open, closed or
/// both, found with the filter bar's search and narrowed by assignee,
/// repository and label. Excluded repos and hidden issues are left out, as
/// elsewhere, and a team picked narrows it to issues assigned to its members.
struct OpenIssuesView: View {
    @Environment(IssueStore.self) private var store
    @Environment(HiddenStore.self) private var hidden
    @Environment(OrgConfigStore.self) private var configs
    @Environment(\.openURL) private var openURL
    @SceneStorage(MetricsStore.windowKey) private var windowDays = MetricsStore.defaultWindowDays
    @AppStorage("showHidden") private var showHidden = false
    let org: String
    let workload: Workload
    @Binding var selection: DetailSelection?
    private var stored = StoredIssueFilters("allIssues")
    /// The issue Work on This was picked for in a row's context menu.
    @State private var workingOn: IssueReference?
    @State private var tableSelection: Set<String> = []
    @State private var sortOrder: [KeyPathComparator<IssueTableRow>] = []
    @AppStorage("allIssuesColumns") private var storedColumns = Data()

    init(org: String, workload: Workload, selection: Binding<DetailSelection?>) {
        self.org = org
        self.workload = workload
        _selection = selection
    }

    var body: some View {
        let filters = stored.wrappedValue
        let pool = pool(filters)
        let issues = pool.filter { filters.matches($0, names: name) }
        let rows = issues.map { IssueTableRow(issue: $0, assignees: $0.assignees.map(workload.person(login:))) }
        VStack(spacing: 0) {
            IssueFilterBar(filters: stored.projectedValue, pool: pool, names: name)
            Divider()
            if issues.isEmpty {
                ContentUnavailableView(
                    store.history(for: org) == nil ? "Loading issues" : pool.isEmpty ? "No \(noun(filters))" : "No \(noun(filters)) match",
                    systemImage: "smallcircle.filled.circle"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                table(rows, title: issues.count == pool.count ? "\(pool.count) \(noun(filters))" : "\(issues.count) of \(pool.count) \(noun(filters))")
            }
            if let history = store.history(for: org), filters.state != .open {
                Divider()
                Text("Closed issues since \(history.coveredFrom.formatted(date: .abbreviated, time: .omitted)), as far back as the issue history goes (Investments' All time fetches everything).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
            }
        }
        .workOnThis($workingOn)
        // A row picked opens in the drawer, as a list row did.
        .onChange(of: tableSelection) {
            if tableSelection.count == 1, let id = tableSelection.first, let reference = reference(id) {
                selection = .issueReference(reference)
            }
        }
        .syncOffNotice(.issues)
        .task(id: org) { await store.sync(org, windowDays: MetricsWindow(code: windowDays).syncDays()) }
    }

    private func table(_ rows: [IssueTableRow], title: String) -> some View {
        Table(of: IssueTableRow.self, selection: $tableSelection, sortOrder: $sortOrder, columnCustomization: TableColumnStore.binding($storedColumns)) {
            TableColumn("Title", value: \.title) { row in
                HStack(spacing: 6) {
                    if !row.issue.isOpen {
                        Pill(text: row.issue.isNotPlanned ? "Not planned" : "Closed", color: row.issue.isNotPlanned ? .secondary : .purple)
                    }
                    Text(row.title).lineLimit(1)
                }
                .opacity(hidden.isHidden(row.id) ? 0.45 : 1)
                .help(row.title)
            }
            .width(min: 220, ideal: 440)
            .customizationID("title")
            TableColumn("Repository", value: \.repoName) { row in
                Text(verbatim: row.repoName).foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 100)
            .customizationID("repository")
            TableColumn("Number", value: \.number) { row in
                Text(verbatim: "#\(row.number)").foregroundStyle(.secondary).monospacedDigit()
            }
            .width(min: 50, ideal: 70)
            .customizationID("number")
            TableColumn("Author", value: \.author) { row in
                if let author = row.issue.author {
                    let person = workload.person(login: author)
                    HStack(spacing: 6) {
                        Avatar(url: person.avatarUrl, size: 18)
                        Text(person.displayName).lineLimit(1)
                    }
                    .help(person.displayName)
                }
            }
            .width(min: 80, ideal: 140)
            .customizationID("author")
            TableColumn("Assignees", value: \.assigneeSort) { row in
                AvatarStack(people: row.assignees)
                    .help(row.assignees.map(\.displayName).joined(separator: ", "))
            }
            .width(min: 60, ideal: 90)
            .customizationID("assignees")
            TableColumn("Labels", value: \.labelSort) { row in
                Text(row.issue.labels.joined(separator: ", "))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(row.issue.labels.joined(separator: ", "))
            }
            .width(min: 60, ideal: 140)
            .customizationID("labels")
            TableColumn("Linked", value: \.linkedCount) { row in
                HStack(spacing: 6) {
                    if !row.issue.linkedPullRequests.isEmpty {
                        LinkedPullRequestsBadge(
                            count: row.issue.linkedPullRequests.count,
                            tint: row.issue.linkedPullRequests.linkedPullRequestsTint,
                            anyMerged: row.issue.linkedPullRequests.contains(where: \.isMerged)
                        )
                    }
                    if let mentioned = row.issue.mentionedInPullRequests, !mentioned.isEmpty {
                        LinkedPullRequestsBadge(
                            count: mentioned.count,
                            tint: mentioned.linkedPullRequestsTint,
                            anyMerged: mentioned.contains(where: \.isMerged),
                            systemImage: "at",
                            label: "Mentioned in pull requests"
                        )
                    }
                }
            }
            .width(min: 50, ideal: 70)
            .customizationID("linked")
            TableColumn("Opened", value: \.createdAt) { row in
                RelativeDate(date: row.createdAt).foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 100)
            .customizationID("opened")
            TableColumn("Closed", value: \.closedSort) { row in
                if let closed = row.issue.closedAt {
                    RelativeDate(date: closed).foregroundStyle(.secondary)
                }
            }
            .width(min: 70, ideal: 100)
            .customizationID("closed")
        } rows: {
            Section("\(title)") {
                ForEach(sortOrder.isEmpty ? rows : rows.sorted(using: sortOrder)) { TableRow($0) }
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let reference = reference(id), let issue = store.history(for: org)?.issues[id] {
                OpenElsewhereItems(.issueReference(reference))
                Button(hidden.isHidden(id) ? "Unhide" : "Hide") { hidden.toggle(id) }
                NewSubIssueItem(parent: reference)
                WorkOnThisMenuItem(reference: reference, request: $workingOn)
                Button("Open on GitHub") { openURL(issue.url) }
            }
        } primaryAction: { ids in
            if let id = ids.first, let reference = reference(id) { selection = .issueReference(reference) }
        }
    }

    private func reference(_ id: String) -> IssueReference? {
        store.history(for: org)?.issues[id].map { IssueReference(org: org, record: $0) }
    }

    private func noun(_ filters: IssueFilters) -> String {
        switch filters.state {
        case .open: "open issues"
        case .closed: "closed issues"
        case .all: "issues"
        }
    }

    /// The history's issues in the state picked, less excluded repos,
    /// hidden ones and (with a team) those not assigned to its members;
    /// the latest opened or closed first.
    private func pool(_ filters: IssueFilters) -> [IssueRecord] {
        guard let history = store.history(for: org) else { return [] }
        let excluded = configs.config(for: org).repoExclusion
        let members = workload.team.map { Set($0.members) }
        return history.issues.values
            .filter { filters.inState($0) && !excluded.contains($0.repo) && (showHidden || !hidden.keys.contains($0.id)) }
            .filter { issue in members.map { team in issue.assignees.contains(where: team.contains) } ?? true }
            .sorted { ($0.closedAt ?? $0.createdAt) > ($1.closedAt ?? $1.createdAt) }
    }

    private func name(_ login: String) -> String { workload.person(login: login).displayName }
}

/// An issue as Issues › All's table shows it, with what its columns sort by.
struct IssueTableRow: Identifiable {
    let issue: IssueRecord
    let assignees: [Person]

    var id: String { issue.id }
    var title: String { issue.title }
    var repoName: String { issue.repo.split(separator: "/").last.map(String.init) ?? issue.repo }
    var number: Int { issue.number }
    var author: String { issue.author?.lowercased() ?? "" }
    var assigneeSort: String { assignees.map { $0.displayName.lowercased() }.sorted().joined(separator: ",") }
    var labelSort: String { issue.labels.joined(separator: ",").lowercased() }
    var linkedCount: Int { issue.linkedPullRequests.count + (issue.mentionedInPullRequests?.count ?? 0) }
    var createdAt: Date { issue.createdAt }
    /// Open issues sort as the newest.
    var closedSort: Date { issue.closedAt ?? .distantFuture }
}

extension Workload {
    /// A member's profile when the snapshot has it; otherwise GitHub's
    /// avatar for the login.
    func person(login: String) -> Person {
        snapshot.members.first { $0.login == login }
            ?? Person(login: login, name: nil, avatarUrl: URL(string: "https://github.com/\(login).png?size=64"))
    }
}

/// The issue pages' search: every word typed has to be in the title, the
/// repo, `#123`, a person's login or name, or a label.
enum IssueSearch {
    static func matches(_ query: String, title: String, repo: String, number: Int, people: [String], labels: [String]) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return true }
        let fields = [title, repo, "#\(number)", "\(number)"] + people + labels
        return words.allSatisfy { word in fields.contains { $0.localizedCaseInsensitiveContains(word) } }
    }

    /// An issue from the issue history.
    static func matches(_ query: String, record: IssueRecord) -> Bool {
        matches(query, title: record.title, repo: record.repo, number: record.number,
                people: record.assignees + [record.author].compactMap { $0 }, labels: record.labels)
    }
}
