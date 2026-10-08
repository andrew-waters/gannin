import SwiftUI

/// The org's settings, as panes picked from a segmented control in the
/// toolbar: which repos and people count anywhere in the app, the
/// projects, working time, the issue workflow, investments, the harness, and the PRs
/// and issues hidden one at a time.
struct OrgSettingsView: View {
    @Environment(OrgStore.self) private var orgs
    @Environment(MetricsStore.self) private var metricsStore
    @Environment(OrgConfigStore.self) private var configs
    @Environment(HiddenStore.self) private var hidden
    @Environment(HarnessStore.self) private var harness

    let org: String
    @State private var search = ""
    @FocusState private var isFiltering: Bool
    @SceneStorage("orgSettingsPane") private var pane: Pane = .repositories

    enum Pane: String, CaseIterable, Identifiable {
        case repositories = "Repositories"
        case projects = "Projects"
        case people = "People"
        case workingTime = "Working Time"
        case issues = "Issues"
        case investments = "Investments"
        case goals = "Goals"
        case harness = "Harness"
        case hidden = "Hidden"

        var id: Self { self }
    }

    var body: some View {
        Form {
            content(pane)
        }
        .formStyle(.grouped)
        .id(pane)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Settings", selection: $pane) {
                    ForEach(Pane.allCases) { pane in
                        Text(pane.rawValue).tag(pane)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
        }
        .onChange(of: pane) { search = "" }
        // Every repo, for those with nothing synced yet.
        .task(id: org) { await harness.loadRepositories(org: org) }
    }

    @ViewBuilder
    private func content(_ pane: Pane) -> some View {
        let snapshot = orgs.snapshot(for: org)
        let history = metricsStore.history(for: org)
        let orgName = orgs.org(login: org)?.displayName ?? org
        switch pane {
        case .repositories:
            let all = Self.repositories(snapshot: snapshot, history: history, all: allRepos).filter { matches($0.name) }
            // Included first, then the rest, each by name.
            let excluded = configs.config(for: org).excludedRepos
            let repos = all.filter { !excluded.contains($0.name) } + all.filter { excluded.contains($0.name) }
            Section {
                Text("Unticked repositories are left out everywhere in \(orgName): the workload lists, People and the stats. Untick Needs Review for a repository whose PRs can merge without one (docs, config, the harness), so they aren't flagged as merged without review.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                filterField("Type to filter repositories")
                bulkActions(all.map(\.name))
            }
            Section {
                if repos.isEmpty {
                    Text(search.isEmpty ? "No repositories yet. They appear once GitHub's list has loaded." : "No matches")
                        .foregroundStyle(.secondary)
                }
                ForEach(repos) { repo in repositoryRow(repo) }
            } header: {
                header("Repositories", excluded: excluded.count)
            }
        case .projects:
            ProjectsSettingsSection(org: org, repos: Self.repositories(snapshot: snapshot, history: history).map(\.name))
        case .people:
            let everyone = Self.people(snapshot: snapshot, history: history)
            let people = everyone.filter { matches($0.person.login) || matches($0.person.displayName) }
            Section {
                Text("Unticked people are left out everywhere in \(orgName): their PRs and reviews don't count in the workload lists, People or the stats. Accounts ending in -bot start unticked.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                filterField("Type to filter people")
            }
            Section {
                if people.isEmpty {
                    Text(search.isEmpty ? "No people yet. They appear once the org has synced." : "No matches")
                        .foregroundStyle(.secondary)
                }
                ForEach(people) { option in
                    Toggle(isOn: included(login: option.person.login)) {
                        HStack(spacing: 8) {
                            Avatar(url: option.person.avatarUrl, size: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(option.person.displayName)
                                // The login, when the name isn't it already.
                                if option.person.name != nil {
                                    Text(option.person.login)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            } header: {
                header("People", excluded: everyone.filter { isExcluded($0.person.login) }.count)
            }
        case .workingTime:
            WorkWeekSection(org: org)
            LeavePolicySection(org: org)
            PeopleDatesSection(org: org, people: (snapshot?.members ?? []).sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending })
        case .issues:
            IssueWorkflowSection(org: org)
        case .investments:
            InvestmentCategoriesSection(org: org)
        case .goals:
            GoalsSettingsSection(org: org, teams: snapshot?.teams ?? [])
        case .harness:
            HarnessSettingsSection(org: org)
        case .hidden:
            let hiddenItems = Self.hiddenItems(snapshot: snapshot, hidden: hidden.keys)
            Section {
                if hiddenItems.isEmpty {
                    Text("Nothing hidden. Right-click a pull request or issue to hide it.")
                        .foregroundStyle(.secondary)
                }
                ForEach(hiddenItems) { item in
                    LabeledContent {
                        Button("Unhide") { hidden.toggle(item.id) }
                    } label: {
                        Text(item.title)
                        Text(item.reference)
                    }
                }
            } header: {
                header("Hidden items", excluded: 0)
            }
        }
    }

    /// A search field, focused when the pane opens so typing a name
    /// filters straight away.
    private func filterField(_ prompt: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Filter", text: $search, prompt: Text(prompt))
                .textFieldStyle(.plain)
                .labelsHidden()
                .multilineTextAlignment(.leading)
                .focused($isFiltering)
                .onKeyPress(.escape) {
                    guard !search.isEmpty else { return .ignored }
                    search = ""
                    return .handled
                }
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help("Clear")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.7), in: Capsule())
        .onAppear { isFiltering = true }
    }

    /// Changes every repo listed (those the filter matches) at once, as one
    /// change to the settings.
    private func bulkActions(_ names: [String]) -> some View {
        let shown = Set(names)
        let label = search.isEmpty ? "all \(names.count)" : "the \(names.count) shown"
        return HStack {
            Text("Change \(label)")
                .foregroundStyle(.secondary)
            Spacer()
            Button("Include") { configs.update(org) { $0.excludedRepos.subtract(shown) } }
            Button("Exclude") { configs.update(org) { $0.excludedRepos.formUnion(shown) } }
            Divider().frame(height: 16)
            Button("Needs Review") { configs.update(org) { $0.reposWithoutReview.subtract(shown) } }
            Button("No Review") { configs.update(org) { $0.reposWithoutReview.formUnion(shown) } }
        }
        .disabled(names.isEmpty)
        .controlSize(.small)
    }

    /// The org's repos from GitHub, and any excluded, so they can come back.
    private var allRepos: [String] {
        (harness.repositories[org] ?? []) + configs.config(for: org).excludedRepos
    }

    private func repositoryRow(_ repo: RepositoryOption) -> some View {
        let isIncluded = !configs.config(for: org).excludedRepos.contains(repo.name)
        return LabeledContent {
            HStack(spacing: 16) {
                Toggle("Needs Review", isOn: Binding {
                    configs.config(for: org).needsReview(repo.name)
                } set: { _ in
                    configs.toggleReview(repo.name, in: org)
                })
                .checkboxToggle()
                .disabled(!isIncluded)
                .help("Whether its PRs should have a review before they merge")
                Toggle("Included", isOn: included(repo: repo.name))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
        } label: {
            Text(repo.name)
            if !repo.summary.isEmpty { Text(repo.summary) }
        }
    }

    private func header(_ title: String, excluded: Int) -> some View {
        HStack(spacing: 6) {
            Text(title)
            if excluded > 0 {
                Text("\(excluded) excluded").foregroundStyle(.secondary).fontWeight(.regular)
            }
        }
    }

    private var query: String { search.trimmingCharacters(in: .whitespaces) }

    private func matches(_ text: String) -> Bool {
        query.isEmpty || text.localizedCaseInsensitiveContains(query)
    }

    /// Excluded in this org's config, or hidden with the old per-person Hide.
    private func isExcluded(_ login: String) -> Bool {
        configs.config(for: org).excludes(login) || hidden.isHidden(HiddenStore.personKey(login))
    }

    private func included(repo: String) -> Binding<Bool> {
        Binding {
            !configs.config(for: org).excludedRepos.contains(repo)
        } set: { _ in
            configs.toggleRepo(repo, in: org)
        }
    }

    private func included(login: String) -> Binding<Bool> {
        Binding {
            !isExcluded(login)
        } set: { include in
            let key = HiddenStore.personKey(login)
            let excludedByConfig = configs.config(for: org).excludes(login)
            if include {
                if hidden.isHidden(key) { hidden.toggle(key) }
                if excludedByConfig { configs.toggleAuthor(login, in: org) }
            } else if !excludedByConfig {
                configs.toggleAuthor(login, in: org)
            }
        }
    }
}

// MARK: - Options

extension OrgSettingsView {
    struct RepositoryOption: Identifiable {
        let name: String
        let openPullRequests: Int
        let issues: Int
        let merged: Int

        var id: String { name }

        var summary: String {
            var parts: [String] = []
            if openPullRequests > 0 { parts.append(openPullRequests == 1 ? "1 open PR" : "\(openPullRequests) open PRs") }
            if issues > 0 { parts.append(issues == 1 ? "1 open issue" : "\(issues) open issues") }
            if merged > 0 { parts.append("\(merged) merged") }
            return parts.joined(separator: " · ")
        }

    }

    struct PersonOption: Identifiable {
        let person: Person
        let merged: Int

        var id: String { person.login }
    }

    struct HiddenItem: Identifiable {
        let id: String
        let title: String
        let reference: String
    }

    /// Every repo seen in the snapshot or the metrics history, plus `all`
    /// (the org's from GitHub) with nothing to count, by name.
    static func repositories(snapshot: OrgSnapshot?, history: MetricsHistory?, all: [String] = []) -> [RepositoryOption] {
        let open = Dictionary(grouping: snapshot?.openPullRequests ?? [], by: \.repo).mapValues(\.count)
        let issues = Dictionary(grouping: snapshot?.issues ?? [], by: \.repo).mapValues(\.count)
        let merged = Dictionary(grouping: history.map { Array($0.pullRequests.values) } ?? [], by: \.repo).mapValues(\.count)
        let names = Set(open.keys).union(issues.keys).union(merged.keys)
            .union((snapshot?.mergedPullRequests ?? []).map(\.repo))
            .union(all)
        return names
            .map { RepositoryOption(name: $0, openPullRequests: open[$0] ?? 0, issues: issues[$0] ?? 0, merged: merged[$0] ?? 0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Members plus anyone who authored or reviewed a PR in the metrics
    /// history (GitHub Apps aside), by name.
    static func people(snapshot: OrgSnapshot?, history: MetricsHistory?) -> [PersonOption] {
        var byLogin = Dictionary((snapshot?.members ?? []).map { ($0.login, $0) }, uniquingKeysWith: { first, _ in first })
        var merged: [String: Int] = [:]
        for pr in history.map({ Array($0.pullRequests.values) }) ?? [] where !pr.authorIsBot {
            if let author = pr.author {
                merged[author.login, default: 0] += 1
                if byLogin[author.login] == nil { byLogin[author.login] = author }
            }
            for login in pr.reviewers where byLogin[login] == nil {
                byLogin[login] = Person(login: login, name: nil, avatarUrl: nil)
            }
        }
        return byLogin.values
            .map { PersonOption(person: $0, merged: merged[$0.login] ?? 0) }
            .sorted { $0.person.displayName.localizedCaseInsensitiveCompare($1.person.displayName) == .orderedAscending }
    }

    /// Hidden PRs and issues that belong to this org's snapshot. Keys are
    /// global, so ones from other orgs aren't listed here.
    static func hiddenItems(snapshot: OrgSnapshot?, hidden: Set<String>) -> [HiddenItem] {
        guard let snapshot else { return [] }
        let prs = (snapshot.openPullRequests + snapshot.mergedPullRequests)
            .filter { hidden.contains($0.id) }
            .map { HiddenItem(id: $0.id, title: $0.title, reference: "\($0.repo)#\($0.number) · pull request") }
        let issues = snapshot.issues
            .filter { hidden.contains($0.id) }
            .map { HiddenItem(id: $0.id, title: $0.title, reference: "\($0.repo)#\($0.number) · issue") }
        var seen = Set<String>()
        return (prs + issues).filter { seen.insert($0.id).inserted }
    }
}

// MARK: - Excluding from a row

/// Adds "Exclude from <org>" and Open on GitHub to a person row's context menu.
struct ExcludablePerson: ViewModifier {
    @Environment(OrgConfigStore.self) private var configs
    @Environment(OrgStore.self) private var orgs
    @Environment(\.openURL) private var openURL
    let login: String
    let org: String
    /// The sidebar row this is, for Open in New Tab and Window.
    var opens: SidebarItem?

    func body(content: Content) -> some View {
        content.contextMenu {
            if let opens { OpenElsewhereItems(sidebar: opens) }
            Button("Exclude from \(orgs.org(login: org)?.displayName ?? org)") {
                if !configs.config(for: org).excludes(login) { configs.toggleAuthor(login, in: org) }
            }
            if let url = URL(string: "https://github.com/\(login)") {
                Button("Open on GitHub") { openURL(url) }
            }
        }
    }
}

/// Exclude and Open on GitHub for a repo row's context menu.
struct RepositoryMenu: View {
    @Environment(OrgConfigStore.self) private var configs
    @Environment(OrgStore.self) private var orgs
    @Environment(\.openURL) private var openURL
    let repository: String
    let org: String

    var body: some View {
        Button("Exclude from \(orgs.org(login: org)?.displayName ?? org)") {
            if !configs.config(for: org).excludedRepos.contains(repository) { configs.toggleRepo(repository, in: org) }
        }
        if let url = URL(string: "https://github.com/\(repository)") {
            Button("Open on GitHub") { openURL(url) }
        }
    }
}

extension View {
    func excludable(login: String, org: String, opens: SidebarItem? = nil) -> some View {
        modifier(ExcludablePerson(login: login, org: org, opens: opens))
    }
}
