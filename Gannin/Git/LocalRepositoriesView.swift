import SwiftUI

/// Work › Repositories: one repo at a time, the one picked in its switcher
/// (or the sidebar, or the palette), remembered per org on this Mac.
struct RepositoriesPage: View {
    @Environment(OrgConfigStore.self) private var configs
    /// The repo this window shows, `owner/name`.
    @SceneStorage("repositoriesRepo") private var stored = ""
    let org: String
    let workload: Workload?
    /// A repo asked for by the sidebar or the palette.
    let requested: String?
    @Binding var selection: DetailSelection?

    var body: some View {
        Group {
            if let repo = current {
                RepositoryPage(org: org, repo: repo, workload: workload, selection: $selection) { pick($0) }
                    .id(repo)
            } else {
                NoRepositoriesView(org: org) { pick($0) }
            }
        }
        .onChange(of: requested, initial: true) {
            if let requested { pick(requested) }
        }
    }

    static func lastKey(_ org: String) -> String { "lastRepository.\(org)" }

    /// The window's repo when it's this org's, else the last picked here,
    /// else the project's first.
    private var current: String? {
        let prefix = org.lowercased() + "/"
        if stored.lowercased().hasPrefix(prefix) { return stored }
        if let last = UserDefaults.standard.string(forKey: Self.lastKey(org)), last.lowercased().hasPrefix(prefix) { return last }
        return RepositoryChoices.repos(org: org, config: configs.config(for: org), workload: workload).first
    }

    private func pick(_ repo: String) {
        stored = repo
        UserDefaults.standard.set(repo, forKey: Self.lastKey(org))
    }
}

/// The repos the switcher offers: the window's project's. A project that
/// names none covers every repo, so it's those with work in flight and any
/// with a clone saved here.
enum RepositoryChoices {
    static func repos(org: String, config: OrgConfig, workload: Workload?) -> [String] {
        if let project = config.scope, !project.repos.isEmpty {
            return project.repos.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        }
        var names: Set<String> = []
        for load in workload?.repositories ?? [] where !config.repoExclusion.contains(load.name) {
            names.insert(load.name)
        }
        for repo in LocalClones.savedRepos where repo.lowercased().hasPrefix(org.lowercased() + "/") && !config.repoExclusion.contains(repo) {
            names.insert(repo)
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// The project repos can be added to: one that names its repos. One
    /// naming none covers them all, and adding a repo would narrow it.
    static func addableProject(_ config: OrgConfig) -> RepoProject? {
        guard let project = config.scope, !project.repos.isEmpty else { return nil }
        return project
    }
}

/// The repo menu at the top left of a repo's page: those cloned here with
/// their branch, then those that aren't, and Clone a Repository.
struct RepositorySwitcher: View {
    @Environment(OrgConfigStore.self) private var configs
    let org: String
    let current: String
    let workload: Workload?
    let pick: (String) -> Void
    @State private var clones: [String: String] = [:]
    @State private var summaries: [String: CloneSummary] = [:]
    @State private var adding = false

    var body: some View {
        let repos = choices
        let project = RepositoryChoices.addableProject(configs.config(for: org))
        let here = repos.filter { clones[$0] != nil }
        let elsewhere = repos.filter { clones[$0] == nil }
        Menu {
            Section(project.map { "\($0.name) on this Mac" } ?? "On this Mac") {
                ForEach(here, id: \.self) { repo in item(repo) }
            }
            if !elsewhere.isEmpty {
                Section("Not cloned") {
                    ForEach(elsewhere, id: \.self) { repo in item(repo) }
                }
            }
            if let project {
                Divider()
                Button("Add a Repo to \(project.name)") { adding = true }
            }
        } label: {
            Label(Self.shortName(current), systemImage: "shippingbox")
                .labelStyle(.titleAndIcon)
                .fontWeight(.semibold)
        }
        .fixedSize()
        .help("\(current): switch repository")
        .task(id: repos) {
            let config = configs.config(for: org)
            var found: [String: String] = [:]
            for repo in repos {
                if let path = LocalClones.find(repo, org: org, config: config) { found[repo] = path }
            }
            clones = found
            summaries = await LocalClones.summaries(found)
        }
        .sheet(isPresented: $adding) {
            if let project { AddProjectRepoSheet(org: org, project: project) { pick($0) } }
        }
    }

    private var choices: [String] {
        let repos = RepositoryChoices.repos(org: org, config: configs.config(for: org), workload: workload)
        return repos.contains(current) ? repos : (repos + [current]).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func item(_ repo: String) -> some View {
        Button {
            pick(repo)
        } label: {
            let title = Self.shortName(repo) + detail(repo)
            if repo == current {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    /// `  main · 3 changes · ↑1`, for a clone.
    private func detail(_ repo: String) -> String {
        guard let summary = summaries[repo] else { return "" }
        var parts = [summary.branch ?? "detached"]
        if summary.changes > 0 { parts.append(summary.changes == 1 ? "1 change" : "\(summary.changes) changes") }
        if summary.ahead > 0 { parts.append("↑\(summary.ahead)") }
        if summary.behind > 0 { parts.append("↓\(summary.behind)") }
        return "  " + parts.joined(separator: " · ")
    }

    static func shortName(_ repo: String) -> String {
        repo.split(separator: "/").last.map(String.init) ?? repo
    }
}

/// A project with no repos to offer yet.
private struct NoRepositoriesView: View {
    @Environment(OrgConfigStore.self) private var configs
    let org: String
    let added: (String) -> Void
    @State private var adding = false

    var body: some View {
        let project = configs.config(for: org).scope
        ContentUnavailableView {
            Label("No repositories", systemImage: "shippingbox")
        } description: {
            Text(project.map { "\($0.name) names no repos, and nothing is in flight." } ?? "Nothing is in flight in \(org) yet.")
        } actions: {
            if project != nil { Button("Add a Repo to the Project") { adding = true } }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $adding) {
            if let project { AddProjectRepoSheet(org: org, project: project, cloned: added) }
        }
    }
}

/// Adds one of the org's repos to the window's project, in its harness's
/// `project.json`, waiting with the other changes to commit.
struct AddProjectRepoSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(HarnessStore.self) private var harness
    @Environment(OrgConfigStore.self) private var configs
    let org: String
    let project: RepoProject
    let cloned: (String) -> Void
    @State private var query = ""
    @State private var picked: String?

    var body: some View {
        let words = query.lowercased().split(separator: " ")
        let choices = (harness.repositories[org] ?? []).filter { repo in
            !project.repos.contains(repo) && words.allSatisfy { repo.lowercased().contains($0) }
        }
        Form {
            Section {
                TextField("Repository", text: $query, prompt: Text("Search \(org)'s repos"))
                List(choices.prefix(300), id: \.self, selection: $picked) { repo in
                    Text(repo).tag(repo)
                }
                .frame(height: 260)
                .overlay {
                    if harness.repositories[org] == nil { ProgressView() }
                }
            } header: {
                Text("Add a repo to \(project.name)")
            } footer: {
                Text("It's added to \(project.harness.repo)'s project.json with the other changes to commit in the sidebar, so the project's pages count it too. Clone it from its page.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .task { await harness.loadRepositories(org: org) }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add to Project") {
                    guard let picked else { return }
                    configs.updateProject(project.id, in: org) { $0.repos.append(picked) }
                    dismiss()
                    cloned(picked)
                }
                .disabled(picked == nil)
            }
        }
    }
}
