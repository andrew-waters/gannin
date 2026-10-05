import SwiftUI

/// Issues › All: the org's issues from the issue history, open, closed or
/// both, found with the filter bar's search and narrowed by assignee,
/// repository and label. Excluded repos and hidden issues are left out, as
/// elsewhere, and a team picked narrows it to issues assigned to its members.
struct OpenIssuesView: View {
    @Environment(IssueStore.self) private var store
    @Environment(HiddenStore.self) private var hidden
    @Environment(OrgConfigStore.self) private var configs
    @SceneStorage(MetricsStore.windowKey) private var windowDays = MetricsStore.defaultWindowDays
    @AppStorage("showHidden") private var showHidden = false
    let org: String
    let workload: Workload
    @Binding var selection: DetailSelection?
    private var stored = StoredIssueFilters("allIssues")

    init(org: String, workload: Workload, selection: Binding<DetailSelection?>) {
        self.org = org
        self.workload = workload
        _selection = selection
    }

    var body: some View {
        let filters = stored.wrappedValue
        let pool = pool(filters)
        let issues = pool.filter { filters.matches($0, names: name) }
        VStack(spacing: 0) {
            IssueFilterBar(filters: stored.projectedValue, pool: pool, names: name)
            Divider()
            List(selection: $selection) {
                Section {
                    if issues.isEmpty {
                        Text(store.history(for: org) == nil ? "Loading issues." : pool.isEmpty ? "No \(noun(filters))." : "No \(noun(filters)) match.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(issues) { issue in
                        let reference = IssueReference(org: org, record: issue)
                        row(issue)
                            .tag(DetailSelection.issueReference(reference))
                            .hideable(issue.id, url: issue.url, opens: .issueReference(reference))
                    }
                } header: {
                    Text(issues.count == pool.count ? "\(pool.count) \(noun(filters))" : "\(issues.count) of \(pool.count) \(noun(filters))")
                } footer: {
                    if let history = store.history(for: org), filters.state != .open {
                        Text("Closed issues since \(history.coveredFrom.formatted(date: .abbreviated, time: .omitted)), as far back as the issue history goes (Investments' All time fetches everything).")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .task(id: org) { await store.sync(org, windowDays: MetricsWindow(code: windowDays).syncDays()) }
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

    private func row(_ issue: IssueRecord) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if !issue.isOpen {
                        Pill(text: issue.isNotPlanned ? "Not planned" : "Closed", color: issue.isNotPlanned ? .secondary : .purple)
                    }
                    Text(issue.title).lineLimit(1)
                }
                HStack(spacing: 4) {
                    Text("\(issue.repo)#\(String(issue.number))")
                    if let author = issue.author { Text("by \(author)") }
                    Text(issue.closedAt == nil ? "· opened" : "· closed")
                    RelativeDate(date: issue.closedAt ?? issue.createdAt)
                    if !issue.linkedPullRequests.isEmpty {
                        LinkedPullRequestsBadge(
                            count: issue.linkedPullRequests.count,
                            tint: issue.linkedPullRequests.linkedPullRequestsTint,
                            anyMerged: issue.linkedPullRequests.contains(where: \.isMerged)
                        )
                    }
                    if let mentioned = issue.mentionedInPullRequests, !mentioned.isEmpty {
                        LinkedPullRequestsBadge(
                            count: mentioned.count,
                            tint: mentioned.linkedPullRequestsTint,
                            anyMerged: mentioned.contains(where: \.isMerged),
                            systemImage: "at",
                            label: "Mentioned in pull requests"
                        )
                    }
                    if !issue.labels.isEmpty {
                        Text("· \(issue.labels.prefix(3).joined(separator: ", "))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer()
            AvatarStack(people: issue.assignees.map { workload.person(login: $0) })
        }
        .padding(.vertical, 2)
    }

    private func name(_ login: String) -> String { workload.person(login: login).displayName }
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
