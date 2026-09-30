import SwiftUI

/// Issues › Open: every open issue in the workload, assigned or not, found
/// with the search field and narrowed by assignee, repository and label.
struct OpenIssuesView: View {
    let workload: Workload
    @Binding var selection: DetailSelection?

    /// `anyone`, `assigned`, `unassigned`, or `@login`.
    @SceneStorage("openIssuesAssignee") private var assignee = "anyone"
    @SceneStorage("openIssuesRepository") private var repository = ""
    @SceneStorage("openIssuesLabel") private var label = ""
    @State private var search = ""

    var body: some View {
        let all = workload.assignedIssues + workload.unassignedIssues
        let issues = all.filter(matches).sorted { $0.updatedAt > $1.updatedAt }
        let filtered = assignee != "anyone" || !repository.isEmpty || !label.isEmpty
        List(selection: $selection) {
            Section {
                if issues.isEmpty {
                    Text(all.isEmpty ? "No open issues." : "No open issues match.")
                        .foregroundStyle(.secondary)
                }
                ForEach(issues) { issue in
                    IssueRow(issue: issue, linkedCount: workload.linkedPullRequests(for: issue).count)
                        .tag(DetailSelection.issue(issue.id))
                }
            } header: {
                HStack {
                    Text(issues.count == all.count ? "\(all.count) open" : "\(issues.count) of \(all.count) open")
                    Spacer()
                    if filtered || !search.isEmpty {
                        Button("Clear Filters") {
                            assignee = "anyone"
                            repository = ""
                            label = ""
                            search = ""
                        }
                        .linkButton()
                    }
                }
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Title, number, repo, label or person")
        .toolbar {
            ToolbarItem {
                Picker("Assignee", selection: $assignee) {
                    Text("Anyone").tag("anyone")
                    Text("Assigned").tag("assigned")
                    Text("Unassigned").tag("unassigned")
                    Divider()
                    ForEach(assignees(all), id: \.login) { person in
                        Text(person.displayName).tag("@" + person.login)
                    }
                }
                .fixedSize()
                .help("Whose issues")
            }
            ToolbarItem {
                Picker("Repository", selection: $repository) {
                    Text("All Repositories").tag("")
                    Divider()
                    ForEach(Array(Set(all.map(\.repo))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }, id: \.self) { repo in
                        Text(repo.split(separator: "/").last.map(String.init) ?? repo).tag(repo)
                    }
                }
                .fixedSize()
                .help("Issues in one repository")
            }
            ToolbarItem {
                Picker("Label", selection: $label) {
                    Text("Any Label").tag("")
                    Divider()
                    ForEach(Array(Set(all.flatMap { $0.labels.map(\.name) })).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .fixedSize()
                .help("Issues with one label")
            }
        }
    }

    /// Everyone with an open issue, by name.
    private func assignees(_ issues: [Issue]) -> [Person] {
        var byLogin: [String: Person] = [:]
        for person in issues.flatMap(\.assignees) { byLogin[person.login] = person }
        return byLogin.values.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private func matches(_ issue: Issue) -> Bool {
        switch assignee {
        case "anyone": break
        case "assigned": if issue.assignees.isEmpty { return false }
        case "unassigned": if !issue.assignees.isEmpty { return false }
        default: if !issue.assignees.contains(where: { "@" + $0.login == assignee }) { return false }
        }
        if !repository.isEmpty, issue.repo != repository { return false }
        if !label.isEmpty, !issue.labels.contains(where: { $0.name == label }) { return false }
        return IssueSearch.matches(search, title: issue.title, repo: issue.repo, number: issue.number,
                                   people: issue.assignees.flatMap { [$0.login, $0.displayName] } + [issue.author?.login].compactMap { $0 },
                                   labels: issue.labels.map(\.name))
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
