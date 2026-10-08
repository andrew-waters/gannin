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

/// The repos the switcher offers: the window's project's, those with work
/// in flight, and any with a clone saved here, in the org.
enum RepositoryChoices {
    static func repos(org: String, config: OrgConfig, workload: Workload?) -> [String] {
        var names = Set(config.focusRepos ?? [])
        for load in workload?.repositories ?? [] where !config.repoExclusion.contains(load.name) {
            names.insert(load.name)
        }
        for repo in LocalClones.savedRepos where repo.lowercased().hasPrefix(org.lowercased() + "/") && !config.repoExclusion.contains(repo) {
            names.insert(repo)
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
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
    @State private var cloning = false

    var body: some View {
        let repos = choices
        let here = repos.filter { clones[$0] != nil }
        let elsewhere = repos.filter { clones[$0] == nil }
        Menu {
            Section("On this Mac") {
                ForEach(here, id: \.self) { repo in item(repo) }
            }
            if !elsewhere.isEmpty {
                Section("Not cloned") {
                    ForEach(elsewhere, id: \.self) { repo in item(repo) }
                }
            }
            Divider()
            Button("Clone a Repository") { cloning = true }
        } label: {
            Label(Self.shortName(current), systemImage: "folder")
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
        .sheet(isPresented: $cloning) {
            CloneRepositorySheet(org: org) { pick($0) }
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

/// An org with no repos to offer yet.
private struct NoRepositoriesView: View {
    let org: String
    let cloned: (String) -> Void
    @State private var cloning = false

    var body: some View {
        ContentUnavailableView {
            Label("No repositories", systemImage: "folder")
        } description: {
            Text("The project names no repos and nothing is in flight. Clone one to work on it here.")
        } actions: {
            Button("Clone a Repository") { cloning = true }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $cloning) {
            CloneRepositorySheet(org: org, cloned: cloned)
        }
    }
}

/// Clone one of the org's repos, or any GitHub repo by URL, into the
/// project's `projects/` folder or a folder chosen.
struct CloneRepositorySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(HarnessStore.self) private var harness
    @Environment(OrgConfigStore.self) private var configs
    let org: String
    let cloned: (String) -> Void
    @State private var query = ""
    @State private var picked: String?
    @State private var path = ""
    @State private var pathEdited = false
    @State private var working = false
    @State private var error: String?

    var body: some View {
        let words = query.lowercased().split(separator: " ")
        let matches = (harness.repositories[org] ?? []).filter { name in words.allSatisfy { name.lowercased().contains($0) } }
        Form {
            Section {
                TextField("Repository", text: $query, prompt: Text("Search \(org)'s repos, or paste a GitHub URL"))
                if !query.contains("github.com") {
                    List(matches.prefix(200), id: \.self, selection: $picked) { repo in
                        Text(repo).tag(repo)
                    }
                    .frame(height: 220)
                    .overlay {
                        if harness.repositories[org] == nil { ProgressView() }
                    }
                }
                HStack {
                    TextField("Folder", text: Binding(get: { path }, set: { path = $0; pathEdited = true }))
                    Button("Choose") {
                        guard let repo = repo, let folder = GitFolders.choose(message: "Choose where the clone goes. It's put in a folder of its own there.", prompt: "Clone Here") else { return }
                        path = SessionStore.tildePath(folder.appending(path: repo.split(separator: "/").last.map(String.init) ?? repo))
                        pathEdited = true
                    }
                    .disabled(repo == nil)
                }
            } header: {
                Text("Clone a repository")
            } footer: {
                if let error {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                } else {
                    Text("Clones use gh when it's installed, else git with your credential helper. The project's harness keeps them in its projects folder.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .task { await harness.loadRepositories(org: org) }
        .onChange(of: repo) { suggestPath() }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(working ? "Cloning" : "Clone") {
                    Task { await clone() }
                }
                .disabled(repo == nil || path.isEmpty || working)
            }
        }
    }

    /// The repo picked in the list, else the one a pasted URL names.
    private var repo: String? {
        if query.contains("github.com"), let typed = LocalClones.gitHubRepo(query) { return typed }
        return picked
    }

    private func suggestPath() {
        guard !pathEdited, let repo else { return }
        path = LocalClones.destination(repo, org: org, config: configs.config(for: org))
    }

    private func clone() async {
        guard let repo else { return }
        working = true
        let url = query.contains("://") || query.hasPrefix("git@") ? query.trimmingCharacters(in: .whitespaces) : nil
        error = await LocalClones.clone(repo, from: url, to: path)
        working = false
        guard error == nil else { return }
        // Where it would be looked for anyway needn't be saved.
        if LocalClones.find(repo, org: org, config: configs.config(for: org)).map({ LocalRepository.samePath($0, path) }) != true {
            LocalClones.save(path, for: repo)
        }
        dismiss()
        cloned(repo)
    }
}
