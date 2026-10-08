import SwiftUI

/// Repositories before one is picked: the clones on this Mac, or the
/// delivery stats by repo, picked in the toolbar.
struct RepositoriesLanding: View {
    enum Part: String, CaseIterable {
        case local = "On This Mac"
        case delivery = "Delivery"
    }

    static let partKey = "repositoriesPart"
    @SceneStorage(RepositoriesLanding.partKey) private var part: Part = .local
    let org: String
    let workload: Workload?
    let metrics: OrgMetrics?
    @Binding var selection: DetailSelection?

    var body: some View {
        Group {
            switch part {
            case .local: LocalRepositoriesView(org: org, workload: workload, selection: $selection)
            case .delivery: RepositoryStatsView(org: org, metrics: metrics, selection: $selection)
            }
        }
        .toolbar {
            ToolbarItem {
                Picker("Show", selection: $part) {
                    ForEach(Part.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
    }
}

/// The project's repos and any with work in flight, each with its clone
/// here: branch, changes, ahead and behind, worktrees. Picking one opens
/// its page; those not on this Mac can be cloned.
private struct LocalRepositoriesView: View {
    @Environment(OrgConfigStore.self) private var configs
    let org: String
    let workload: Workload?
    @Binding var selection: DetailSelection?
    @State private var search = ""
    @State private var clones: [String: String] = [:]
    @State private var summaries: [String: CloneSummary] = [:]
    @State private var cloning = false

    var body: some View {
        let repos = repos.filter { repo in search.lowercased().split(separator: " ").allSatisfy { repo.lowercased().contains($0) } }
        let here = repos.filter { clones[$0] != nil }
        let elsewhere = repos.filter { clones[$0] == nil }
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                FilterSearchField(text: $search, prompt: "Repositories")
                Spacer()
                Button("Clone a Repository") { cloning = true }
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            List(selection: $selection) {
                Section {
                    if here.isEmpty {
                        Text("None of them yet").foregroundStyle(.secondary)
                    }
                    ForEach(here, id: \.self) { repo in
                        cloneRow(repo, path: clones[repo] ?? "")
                            .tag(DetailSelection.repository(repo))
                    }
                } header: {
                    SectionHeader(title: "On this Mac", count: here.count)
                }
                if !elsewhere.isEmpty {
                    Section {
                        ForEach(elsewhere, id: \.self) { repo in
                            HStack {
                                Label(repo, systemImage: "folder.badge.questionmark")
                                Spacer()
                                Text("Not cloned").font(.caption).foregroundStyle(.secondary)
                            }
                            .tag(DetailSelection.repository(repo))
                        }
                    } header: {
                        SectionHeader(title: "Not on this Mac", count: elsewhere.count)
                    }
                }
            }
        }
        .sheet(isPresented: $cloning) {
            CloneRepositorySheet(org: org) { repo in
                locate()
                selection = .repository(repo)
            }
        }
        .task(id: repos) {
            locate()
            do {
                while true {
                    summaries = await LocalClones.summaries(clones)
                    try await Task.sleep(for: .seconds(30))
                }
            } catch {}
        }
    }

    /// The window's project's repos, those with work in flight, and any
    /// with a clone saved here, in the org.
    private var repos: [String] {
        let config = configs.config(for: org)
        var names = Set(config.focusRepos ?? [])
        for load in workload?.repositories ?? [] where !config.repoExclusion.contains(load.name) {
            names.insert(load.name)
        }
        for repo in LocalClones.savedRepos where repo.lowercased().hasPrefix(org.lowercased() + "/") && !config.repoExclusion.contains(repo) {
            names.insert(repo)
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func locate() {
        let config = configs.config(for: org)
        var found: [String: String] = [:]
        for repo in repos {
            if let path = LocalClones.find(repo, org: org, config: config) { found[repo] = path }
        }
        if found != clones { clones = found }
    }

    private func cloneRow(_ repo: String, path: String) -> some View {
        let summary = summaries[repo]
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Label(repo.split(separator: "/").last.map(String.init) ?? repo, systemImage: "folder")
                Text(path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if let summary {
                if summary.worktrees > 1 {
                    Text("\(summary.worktrees) worktrees").font(.caption).foregroundStyle(.secondary)
                }
                Label(summary.branch ?? "Detached", systemImage: "arrow.triangle.branch")
                    .font(.callout)
                    .lineLimit(1)
                    .frame(maxWidth: 220, alignment: .leading)
                Text(summary.changes == 0 ? "No changes" : summary.changes == 1 ? "1 change" : "\(summary.changes) changes")
                    .font(.caption)
                    .foregroundStyle(summary.changes == 0 ? Color.secondary : Color.orange)
                    .frame(width: 80, alignment: .trailing)
                Group {
                    if !summary.hasUpstream {
                        Text("Not published")
                    } else if summary.ahead > 0 || summary.behind > 0 {
                        Text([summary.ahead > 0 ? "↑\(summary.ahead)" : nil, summary.behind > 0 ? "↓\(summary.behind)" : nil].compactMap { $0 }.joined(separator: " "))
                    } else {
                        Text("Up to date")
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .trailing)
                .help("Against the branch's upstream, as of the last fetch")
            }
        }
    }
}

/// Clone one of the org's repos, or any GitHub repo by URL, into the
/// project's `projects/` folder or a folder chosen.
private struct CloneRepositorySheet: View {
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
