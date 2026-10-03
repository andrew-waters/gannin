import SwiftUI

/// A project: a named set of repos (a product, a side project) that can
/// have its own harness, workflow board, investments, goals, scorecard,
/// recap cadence and committed date field, each the org's while unset. A
/// window picks one (Org › Project in the sidebar's footer) and narrows to
/// it: every other repo is left out of the workload, the stats, the
/// scorecard, CI, Recap and the issue pages, as excluded repos are, and its
/// sessions and Harness pages are its harness's. A team setting, so in the
/// harness once the org keeps its data there.
struct RepoProject: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    /// `owner/name`.
    var repos: [String]
    /// Its own harness; nil for the org's.
    var harness: HarnessConfig?
    /// Its own workflow board; nil for the org's.
    var workflow: IssueWorkflow?
    /// Its own investment categories; nil for the org's.
    var investments: InvestmentConfig?
    /// Its own goals; nil for the org's.
    var goals: MetricGoals?
    /// Its own scorecard measurables; nil for the org's.
    var scorecard: [Measurable]?
    /// Its own recap cadence; nil for the org's.
    var recap: RecapCadence?
    /// The board's date field Prioritisation reads as committed to; nil
    /// for the one picked for the org on this Mac.
    var committedDateField: String?

    init(name: String, repos: [String], harness: HarnessConfig? = nil) {
        self.name = name
        self.repos = repos
        self.harness = harness
    }

    /// Tolerates projects saved before a field existed.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        repos = try container.decodeIfPresent([String].self, forKey: .repos) ?? []
        harness = try container.decodeIfPresent(HarnessConfig.self, forKey: .harness)
        workflow = try container.decodeIfPresent(IssueWorkflow.self, forKey: .workflow)
        investments = try container.decodeIfPresent(InvestmentConfig.self, forKey: .investments)
        goals = try container.decodeIfPresent(MetricGoals.self, forKey: .goals)
        scorecard = try container.decodeIfPresent([Measurable].self, forKey: .scorecard)
        recap = try container.decodeIfPresent(RecapCadence.self, forKey: .recap)
        committedDateField = try container.decodeIfPresent(String.self, forKey: .committedDateField)
    }

    /// Its harness, for its repos: where work in them runs.
    var ownHarness: HarnessConfig? {
        harness.map { setup in
            var setup = setup
            setup.repos = repos
            return setup
        }
    }
}

/// What views check a repo against: with a project picked, anything
/// outside its repos (which count even if excluded for the org, since the
/// project names them); else the org's excluded repos.
struct RepoExclusion: Hashable {
    let excluded: Set<String>
    /// Nil with no project picked.
    let focus: Set<String>?

    func contains(_ repo: String) -> Bool {
        if let focus { return !focus.contains(repo) }
        return excluded.contains(repo)
    }
}

/// Settings › Projects: the org's projects, one at a time: its name and
/// repos, its harness, and which settings it keeps of its own, with their
/// editors for the project's copy.
struct ProjectsSettingsSection: View {
    @Environment(OrgConfigStore.self) private var configs
    @Environment(HarnessStore.self) private var harness
    let org: String
    /// Every repo there is to pick from.
    let repos: [String]
    let teams: [Team]
    /// The project being edited, by ID.
    @SceneStorage("settingsProject") private var selectedID = ""
    @State private var isCreatingHarness = false
    /// Asked about before it goes.
    @State private var removing: RepoProject?
    @State private var isAddingRepo = false

    /// The settings a project can keep of its own.
    enum Own: String, CaseIterable, Identifiable {
        case workflow = "Workflow board"
        case investments = "Investments"
        case goals = "Goals"
        case scorecard = "Scorecard"
        case recap = "Recap cadence"
        case committedDate = "Committed date field"

        var id: Self { self }
    }

    var body: some View {
        let projects = configs.baseConfig(for: org).repoProjects
        let selected = projects.first { $0.id.uuidString == selectedID } ?? projects.first
        Section {
            if projects.isEmpty {
                Text("A project is a set of repos (a product, a side project) that can have its own harness, workflow board, investments, goals and scorecard. Pick one at the bottom of the sidebar and the window narrows to it.")
                    .foregroundStyle(.secondary)
            }
            ForEach(projects) { project in
                projectRow(project, isSelected: project.id == selected?.id)
            }
            Button("Add Project") {
                let project = RepoProject(name: "New project", repos: [])
                configs.update(org) { $0.repoProjects.append(project) }
                selectedID = project.id.uuidString
            }
        } header: {
            Text("Projects")
        } footer: {
            Text("Click a project to edit it below. Each window picks a project, or All, at the bottom of the sidebar. Excluded repos stay out either way.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .confirmationDialog("Remove \(removing?.name ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            if let project = removing {
                Button("Remove Project", role: .destructive) { remove(project) }
            }
        } message: {
            Text("Its repos and harness are untouched, and so is anything it kept of its own in the org's settings. Windows on it go back to All.")
        }
        if let selected {
            details(selected)
            harnessSection(selected)
            if let setup = selected.harness {
                HarnessPromptsSection(org: org, setup: setup)
            }
            ownSection(selected)
            ownEditors(selected)
                .environment(configs.scoped(selected.id))
        }
    }

    /// A project in the list: its name, what it has, picked to edit it,
    /// and removed from its button.
    private func projectRow(_ project: RepoProject, isSelected: Bool) -> some View {
        HStack {
            Button {
                selectedID = project.id.uuidString
            } label: {
                HStack {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(project.name).fontWeight(isSelected ? .medium : .regular)
                        Text(summary(project)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
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

    /// "3 repos, own harness", for its row.
    private func summary(_ project: RepoProject) -> String {
        let repos = project.repos.isEmpty ? "No repos yet" : "\(project.repos.count) \(project.repos.count == 1 ? "repo" : "repos")"
        return project.harness.map { "\(repos), harness \($0.name)" } ?? repos
    }

    private func remove(_ project: RepoProject) {
        configs.update(org) { $0.repoProjects.removeAll { $0.id == project.id } }
        if selectedID == project.id.uuidString { selectedID = "" }
        removing = nil
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

    // MARK: Harness

    private func harnessSection(_ project: RepoProject) -> some View {
        let config = configs.baseConfig(for: org)
        // Any repo but the org's harness; what's saved stays listed even
        // before GitHub's list loads.
        let choices = Set(harness.repositories[org] ?? []).union(project.harness.map { [$0.repo] } ?? [])
            .subtracting(config.harness.map { [$0.repo] } ?? [])
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return Section {
            LabeledContent("Harness") {
                SearchablePicker(
                    choices: [SearchableChoice(value: nil, title: config.harness.map { "The org's (\($0.name))" } ?? "The org's")]
                        + choices.map { SearchableChoice(value: $0, title: $0) },
                    selection: project.harness?.repo,
                    prompt: "Search repositories",
                    isLoading: harness.repositories[org] == nil
                ) { repo in
                    update(project.id) { $0.harness = repo.map { HarnessConfig(repo: $0) } }
                }
            }
            if let setup = project.harness {
                branchPicker(project, setup: setup)
                if let error = harness.error(org, setup) {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            } else {
                Button("Create Harness") { isCreatingHarness = true }
            }
        } footer: {
            Text("Work on this project's issues and PRs runs in its harness, with its prompts and skills, and its Harness pages are that harness's. With the org's, they're as for All.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task { await harness.loadRepositories(org: org) }
        .loadsHarness(org: org)
        .sheet(isPresented: $isCreatingHarness) { CreateHarnessSheet(org: org, project: project.id) }
    }

    private func branchPicker(_ project: RepoProject, setup: HarnessConfig) -> some View {
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
                update(project.id) { $0.harness?.branch = branch }
            }
        }
        .task(id: setup.repo) { await harness.loadBranches(repo: setup.repo) }
    }

    // MARK: Its own settings

    private func ownSection(_ project: RepoProject) -> some View {
        Section {
            ForEach(Own.allCases) { own in
                Picker(own.rawValue, selection: Binding(get: { owns(own, project) }, set: { setOwns(own, $0, project: project) })) {
                    Text("The org's").tag(false)
                    Text("Its own").tag(true)
                }
            }
        } header: {
            Text("Its own settings")
        } footer: {
            Text("Its own starts as a copy of the org's. Edit the workflow, investments and goals below; the scorecard, recap cadence and committed date field where they're used, with this project picked.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The editors for what it keeps of its own, editing its copy (they're
    /// given the project's store).
    @ViewBuilder
    private func ownEditors(_ project: RepoProject) -> some View {
        if project.workflow != nil {
            IssueWorkflowSection(org: org)
        }
        if project.investments != nil {
            InvestmentCategoriesSection(org: org)
        }
        if project.goals != nil {
            GoalsSettingsSection(org: org, teams: teams)
        }
    }

    private func owns(_ own: Own, _ project: RepoProject) -> Bool {
        switch own {
        case .workflow: project.workflow != nil
        case .investments: project.investments != nil
        case .goals: project.goals != nil
        case .scorecard: project.scorecard != nil
        case .recap: project.recap != nil
        case .committedDate: project.committedDateField != nil
        }
    }

    /// Its own starts from the org's; the org's drops the project's copy.
    private func setOwns(_ own: Own, _ isOwn: Bool, project: RepoProject) {
        let config = configs.baseConfig(for: org)
        update(project.id) { project in
            switch own {
            case .workflow: project.workflow = isOwn ? config.workflow : nil
            case .investments: project.investments = isOwn ? config.investmentConfig : nil
            case .goals: project.goals = isOwn ? config.goals ?? MetricGoals() : nil
            case .scorecard: project.scorecard = isOwn ? config.measurables : nil
            case .recap: project.recap = isOwn ? config.recapCadence : nil
            case .committedDate: project.committedDateField = isOwn ? PrioritisationView.orgDateField(org) : nil
            }
        }
    }

    private func update(_ id: UUID, _ change: (inout RepoProject) -> Void) {
        configs.updateProject(id, in: org, change)
    }
}
