import SwiftUI

/// Per-org choice of which repos and authors count towards the stats.
struct OrgStatsConfigView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case repos = "Repositories"
        case people = "People"
        var id: Self { self }
    }

    @Environment(OrgConfigStore.self) private var configs
    @Environment(\.dismiss) private var dismiss

    let org: String
    /// Repos seen in the metrics history, with merged PR counts.
    let repos: [(repo: String, count: Int)]
    /// Authors and reviewers seen in the history or the member list, with
    /// merged PRs authored.
    let people: [(person: Person, count: Int)]

    @State private var tab: Tab
    @State private var search = ""

    var body: some View {
        let config = configs.config(for: org)
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Stats for \(org)").font(.title3.weight(.semibold))
                Text("Unticked repos and people are left out of the delivery metrics. An excluded person's reviews don't count either. Accounts ending in -bot start unticked. \"PRs opened\" is an org-wide count and ignores these.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Picker("Show", selection: $tab) {
                Text("Repositories (\(config.excludedRepos.count) excluded)").tag(Tab.repos)
                Text("People (\(people.filter { config.excludes($0.person.login) }.count) excluded)").tag(Tab.people)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            TextField("Filter", text: $search)
                .textFieldStyle(.roundedBorder)

            List {
                switch tab {
                case .repos:
                    ForEach(filteredRepos, id: \.repo) { item in
                        Toggle(isOn: included(repo: item.repo)) {
                            row(item.repo, count: item.count)
                        }
                    }
                case .people:
                    ForEach(filteredPeople, id: \.person.login) { item in
                        Toggle(isOn: included(login: item.person.login)) {
                            HStack(spacing: 6) {
                                Avatar(url: item.person.avatarUrl, size: 18)
                                row(item.person.displayName, count: item.count)
                            }
                        }
                    }
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))

            HStack {
                Button("Include All") {
                    configs.update(org) { config in
                        switch tab {
                        case .repos: config.excludedRepos = []
                        case .people:
                            config.excludedAuthors = []
                            config.includedAuthors = Set(people.map(\.person.login).filter(OrgConfig.looksLikeBot))
                        }
                    }
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 500, height: 580)
    }

    private func row(_ title: String, count: Int) -> some View {
        HStack {
            Text(title).lineLimit(1)
            Spacer()
            Text(count == 1 ? "1 PR" : "\(count) PRs")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private var query: String { search.trimmingCharacters(in: .whitespaces) }

    private var filteredRepos: [(repo: String, count: Int)] {
        query.isEmpty ? repos : repos.filter { $0.repo.localizedCaseInsensitiveContains(query) }
    }

    private var filteredPeople: [(person: Person, count: Int)] {
        guard !query.isEmpty else { return people }
        return people.filter {
            $0.person.login.localizedCaseInsensitiveContains(query) || $0.person.displayName.localizedCaseInsensitiveContains(query)
        }
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
            !configs.config(for: org).excludes(login)
        } set: { _ in
            configs.toggleAuthor(login, in: org)
        }
    }
}

extension OrgStatsConfigView {
    /// Builds the pickable repos and people from everything the app has seen
    /// for the org, busiest first.
    init(org: String, history: MetricsHistory?, members: [Person], initialTab: Tab = .repos) {
        let prs = history.map { Array($0.pullRequests.values) } ?? []

        let repoCounts = Dictionary(grouping: prs, by: \.repo).mapValues(\.count)
        let repos = repoCounts
            .map { (repo: $0.key, count: $0.value) }
            .sorted { ($0.count, $1.repo) > ($1.count, $0.repo) }

        var peopleByLogin = Dictionary(members.map { ($0.login, $0) }, uniquingKeysWith: { first, _ in first })
        var counts: [String: Int] = [:]
        for pr in prs where !pr.authorIsBot {
            if let author = pr.author {
                counts[author.login, default: 0] += 1
                if peopleByLogin[author.login] == nil { peopleByLogin[author.login] = author }
            }
            for login in pr.reviewers where peopleByLogin[login] == nil {
                peopleByLogin[login] = Person(login: login, name: nil, avatarUrl: nil)
            }
        }
        let people = peopleByLogin.values
            .map { (person: $0, count: counts[$0.login] ?? 0) }
            .sorted { ($0.count, $1.person.login) > ($1.count, $0.person.login) }

        self.org = org
        self.repos = repos
        self.people = people
        _tab = State(initialValue: initialTab)
    }
}
