import SwiftUI

/// A project: one harness repo and the code repos it's for (a product, a
/// side project). Its name, repos and boards are `.gannin/project.json` in
/// its harness, and its workflow board, investments, goals, scorecard,
/// recap cadence and committed date field are that harness's own team
/// files. Every window works in one (Org › Project in the sidebar's
/// footer) and narrows to it: every other repo is left out of the
/// workload, the stats, the scorecard, CI, Recap and the issue pages, as
/// excluded repos are, and its sessions and Harness pages are its
/// harness's. Which harnesses are projects is the user's own
/// (`OrgConfig.harness` and `otherHarnesses`); the first, home, also keeps
/// the org-wide data.
struct RepoProject: Codable, Hashable, Identifiable {
    var harness: HarnessConfig
    var name: String
    /// `owner/name`; none for every repo.
    var repos: [String]
    /// The repo whose linked boards it lists (`owner/name`); nil for every
    /// board the org has.
    var boardsRepo: String?

    /// Its harness's repo: a harness is one project.
    var id: String { harness.repo }

    /// Its harness, for its repos: where work in them runs.
    var ownHarness: HarnessConfig {
        var setup = harness
        setup.repos = repos
        return setup
    }

    /// What `.gannin/project.json` holds.
    var file: ProjectFile { ProjectFile(name: name, repos: repos, boardsRepo: boardsRepo) }
}

/// A project as its harness keeps it, `.gannin/project.json`.
struct ProjectFile: Codable, Hashable {
    var name: String
    var repos: [String]
    var boardsRepo: String?
}

/// A project as `.gannin/repo-projects.json` listed it, when the org's
/// harness held every project: only read, for a harness with no
/// `project.json` of its own yet.
struct LegacyProject: Decodable {
    var name: String
    var repos: [String]?
    var harness: HarnessConfig?
    var boardsRepo: String?
}

/// What views check a repo against: with a project picked, anything
/// outside its repos (which count even if excluded for the org, since the
/// project names them); else the org's excluded repos. A repo the account
/// doesn't own, named by some project (`outside`), is shown only within
/// the project that names it, even when another project's focus is nil
/// (every repo it owns).
struct RepoExclusion: Hashable {
    let excluded: Set<String>
    /// Nil with no project picked.
    let focus: Set<String>?
    let outside: Set<String>

    init(excluded: Set<String>, focus: Set<String>?, outside: Set<String> = []) {
        self.excluded = excluded
        self.focus = focus
        self.outside = outside
    }

    func contains(_ repo: String) -> Bool {
        if outside.contains(repo) { return !(focus?.contains(repo) ?? false) }
        if let focus { return !focus.contains(repo) }
        return excluded.contains(repo)
    }
}

/// Settings › Projects: the org's projects, each a harness, one at a time:
/// its name and repos, boards, harness branch and prompts, and which is
/// home. Its workflow, investments and goals are edited in their panes, and
/// its scorecard, recap cadence and committed date field where they're
/// used, with it picked for the window.
struct ProjectsSettingsSection: View {
    @Environment(OrgConfigStore.self) private var configs
    @Environment(HarnessStore.self) private var harness
    @Environment(HarnessTeamStore.self) private var team
    @Environment(ProjectStore.self) private var boards
    let org: String
    /// Every repo there is to pick from.
    let repos: [String]
    /// The project being edited, by its harness's repo.
    @SceneStorage("settingsProject") private var selectedID = ""
    @State private var isCreatingHarness = false
    @State private var isAddingProject = false
    /// Asked about before it goes.
    @State private var removing: RepoProject?
    /// Asked about before it's home.
    @State private var homing: RepoProject?
    @State private var isMoving = false
    @State private var moveError: String?
    @State private var isAddingRepo = false

    var body: some View {
        let projects = configs.baseConfig(for: org).repoProjects
        let selected = projects.first { $0.id == selectedID } ?? configs.currentProject(org)
        Section {
            if projects.isEmpty {
                Text("A project is a harness, a repo of plans, requirements, findings, skills and prompts, and the code repos it's for (a product, a side project). Its settings are kept in its harness, and every window works in one, picked at the bottom of the sidebar.")
                    .foregroundStyle(.secondary)
            }
            ForEach(projects) { project in
                projectRow(project, isSelected: project.id == selected?.id, isHome: project.id == projects.first?.id)
            }
            HStack {
                Button("Add Project") { isAddingProject = true }
                    .popover(isPresented: $isAddingProject, arrowEdge: .bottom) {
                        SearchableList(choices: harnessChoices(projects), selection: nil, prompt: "Search repositories", isLoading: harness.repositories[org] == nil) { repo in
                            isAddingProject = false
                            guard let repo else { return }
                            configs.updateHarnesses(org) { $0.addHarness(HarnessConfig(repo: repo)) }
                            selectedID = repo
                        }
                    }
                    .help("Make a repo \(org) has a project's harness")
                Button("Create Harness") { isCreatingHarness = true }
                    .help("Create a repo for a new project's harness")
            }
            if let moveError {
                Text(moveError).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Projects")
        } footer: {
            Text("Each project's settings are kept in its harness, under .gannin. Home's also keeps what's the org's: people's dates and time off, leave, the working week, repos and people left out, and views.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task { await harness.loadRepositories(org: org) }
        .loadsHarness(org: org)
        .sheet(isPresented: $isCreatingHarness) { CreateHarnessSheet(org: org) }
        .confirmationDialog("Remove \(removing?.name ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            if let project = removing {
                Button("Remove Project", role: .destructive) { remove(project, from: projects) }
            }
        } message: {
            if removing?.id == projects.first?.id, projects.count > 1 {
                Text("\(removing?.harness.repo ?? "") and everything in it are untouched. It's home, so \(projects[1].name) becomes home, and the org's data is read from its harness from then on.")
            } else {
                Text("\(removing?.harness.repo ?? "") and everything in it are untouched; Gannin stops reading it.")
            }
        }
        .confirmationDialog("Make \(homing?.name ?? "") home?", isPresented: Binding(get: { homing != nil }, set: { if !$0 { homing = nil } })) {
            if let project = homing {
                Button("Copy the Org's Data and Make Home") { makeHome(project, copying: true) }
                Button("Make Home Without Copying") { makeHome(project, copying: false) }
            }
        } message: {
            Text("People's dates, leave, the working week, exclusions and views are read from home's harness. Gannin can commit a copy of them from \(projects.first?.harness.repo ?? "") to \(homing?.harness.repo ?? "") first; the old copy stays where it is.")
        }
        if let selected {
            details(selected)
            boardsSection(selected)
            harnessSection(selected, isHome: selected.id == projects.first?.id)
            HarnessPromptsSection(org: org, setup: selected.harness)
        }
    }

    /// A project in the list: its name, what it has, picked to edit it,
    /// and removed from its button.
    private func projectRow(_ project: RepoProject, isSelected: Bool, isHome: Bool) -> some View {
        HStack {
            Button {
                selectedID = project.id
            } label: {
                HStack {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(project.name).fontWeight(isSelected ? .medium : .regular)
                            if isHome {
                                Text("Home")
                                    .font(.caption)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                                    .foregroundStyle(Color.accentColor)
                                    .help("The org's data, people's dates and time off among it, is kept in this project's harness")
                            }
                        }
                        Text(summary(project)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if harness.isLoading(org, project.harness) { ProgressView().controlSize(.small) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Edit \(project.name) below")
            Button {
                removing = project
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove \(project.name)")
        }
    }

    /// "harness: owner/name, 3 repos", for its row.
    private func summary(_ project: RepoProject) -> String {
        let repos = project.repos.isEmpty ? "every repo" : "\(project.repos.count) \(project.repos.count == 1 ? "repo" : "repos")"
        return "\(project.harness.repo), \(repos)"
    }

    /// Repos that aren't a project's harness yet.
    private func harnessChoices(_ projects: [RepoProject]) -> [SearchableChoice] {
        let taken = Set(projects.map(\.id))
        return Set(harness.repositories[org] ?? []).subtracting(taken)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { SearchableChoice(value: $0, title: $0) }
    }

    private func remove(_ project: RepoProject, from projects: [RepoProject]) {
        configs.updateHarnesses(org) { $0.removeHarness(project.id) }
        if selectedID == project.id { selectedID = "" }
        removing = nil
    }

    private func makeHome(_ project: RepoProject, copying: Bool) {
        homing = nil
        guard copying else {
            configs.updateHarnesses(org) { $0.makeHome(project.id) }
            return
        }
        isMoving = true
        moveError = nil
        Task {
            do {
                try await team.moveOrgWideData(org: org, to: project.harness)
                configs.updateHarnesses(org) { $0.makeHome(project.id) }
            } catch {
                moveError = "Couldn't copy the org's data: \(error.localizedDescription)"
            }
            isMoving = false
        }
    }

    // MARK: Name and repos

    private func details(_ project: RepoProject) -> some View {
        Section {
            TextField("Name", text: Binding(get: { project.name }, set: { name in update(project.id) { $0.name = name } }))
            LabeledContent("Repositories") {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if project.repos.isEmpty {
                        Text("None yet: every repo").foregroundStyle(.orange)
                    }
                    ForEach(project.repos, id: \.self) { repo in
                        HStack(spacing: 2) {
                            Text(repo.split(separator: "/").last.map(String.init) ?? repo)
                            Button {
                                update(project.id) { $0.repos.removeAll { $0 == repo } }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.12)))
                        .help(repo)
                    }
                    Button {
                        isAddingRepo = true
                    } label: {
                        Image(systemName: "plus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Add a repo to this project")
                    .popover(isPresented: $isAddingRepo, arrowEdge: .bottom) {
                        SearchableList(choices: repoChoices(project), selection: nil, prompt: "Search repositories", isLoading: harness.repositories[org] == nil) { repo in
                            isAddingRepo = false
                            if let repo { update(project.id) { $0.repos.append(repo) } }
                        }
                    }
                }
                .font(.callout)
            }
        } header: {
            Text(project.name)
        } footer: {
            Text("Saved in \(project.harness.repo) as .gannin/project.json, so anyone who adds it as a project gets the same.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Every repo not in the project: those with recent PRs first, then
    /// the rest of the org's, by name.
    private func repoChoices(_ project: RepoProject) -> [SearchableChoice] {
        let taken = Set(project.repos)
        let active = repos.filter { !taken.contains($0) }
        let rest = Set(harness.repositories[org] ?? []).subtracting(taken).subtracting(active)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return active.map { SearchableChoice(value: $0, title: $0, section: "With recent PRs") }
            + rest.map { SearchableChoice(value: $0, title: $0, section: "Every other repo") }
    }

    // MARK: Boards

    private func boardsSection(_ project: RepoProject) -> some View {
        let taken = Set(project.repos)
        let rest = Set(harness.repositories[org] ?? []).union(project.boardsRepo.map { [$0] } ?? []).subtracting(taken)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        let choices = [SearchableChoice(value: nil, title: "Every board in \(org)")]
            + project.repos.map { SearchableChoice(value: $0, title: $0, section: "Its repos") }
            + rest.map { SearchableChoice(value: $0, title: $0, section: "Every other repo") }
        return Section {
            LabeledContent("Boards") {
                SearchablePicker(choices: choices, selection: project.boardsRepo, prompt: "Search repositories", isLoading: harness.repositories[org] == nil) { repo in
                    update(project.id) { $0.boardsRepo = repo }
                }
            }
            if let repo = project.boardsRepo {
                let linked = boards.boards(org: org, repo: repo)
                Text(linked.isEmpty ? "No open boards of \(org)'s are linked to \(repo) yet." : linked.map(\.title).joined(separator: ", "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .task(id: repo) { await boards.loadRepoBoards(org: org, repo: repo) }
            }
        } footer: {
            Text("With this project picked, Projects in the sidebar lists these. A repo's boards are those linked to it on GitHub (the repo's Projects tab) that \(org) owns.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Harness

    private func harnessSection(_ project: RepoProject, isHome: Bool) -> some View {
        Section {
            LabeledContent("Harness") {
                Text(project.harness.repo)
            }
            branchPicker(project.harness)
            if let error = harness.error(org, project.harness) {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            if !isHome {
                HStack {
                    Button("Make Home") { homing = project }
                        .disabled(isMoving)
                    if isMoving { ProgressView().controlSize(.small) }
                }
            }
        } footer: {
            Text("Work on this project's issues and PRs runs in its harness, with its prompts and skills, and its Harness pages are that harness's.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func branchPicker(_ setup: HarnessConfig) -> some View {
        let branches = harness.branches[setup.repo]
        // The default is Default's, so it isn't listed again.
        let listed = Set(branches?.all ?? []).union(setup.branch.map { [$0] } ?? [])
            .subtracting(branches?.defaultBranch.map { [$0] } ?? [])
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return LabeledContent("Branch") {
            SearchablePicker(
                choices: [SearchableChoice(value: nil, title: branches?.defaultBranch.map { "Default (\($0))" } ?? "Default")]
                    + listed.map { SearchableChoice(value: $0, title: $0) },
                selection: setup.branch,
                prompt: "Search branches",
                isLoading: branches == nil
            ) { branch in
                configs.updateHarnesses(org) { $0.updateHarness(setup.repo) { $0.branch = branch } }
            }
        }
        .task(id: setup.repo) { await harness.loadBranches(repo: setup.repo) }
    }

    private func update(_ id: String, _ change: (inout RepoProject) -> Void) {
        configs.updateProject(id, in: org, change)
    }
}
