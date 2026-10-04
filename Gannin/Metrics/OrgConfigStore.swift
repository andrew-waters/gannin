import Foundation
import Observation

/// Per-org settings for the stats: repos and authors left out of them.
struct OrgConfig: Codable, Hashable {
    /// `owner/name` of repos whose PRs are left out.
    var excludedRepos: Set<String> = []
    /// Logins whose PRs and reviews are left out.
    var excludedAuthors: Set<String> = []
    /// Bot-looking logins the user has chosen to count anyway.
    var includedAuthors: Set<String> = []
    /// `owner/name` of repos whose PRs don't need a review (docs, config, a
    /// harness), so merging one unreviewed isn't flagged.
    var reposWithoutReview: Set<String> = []
    /// Investment categories; nil until edited, meaning the default preset.
    var investments: InvestmentConfig?
    /// How issues move through the org's board; nil means the defaults.
    var issueWorkflow: IssueWorkflow?
    /// Working days and hours; nil means Monday to Friday, 9 to 5.
    var workWeek: WorkWeek?

    var week: WorkWeek { workWeek ?? WorkWeek() }
    /// Holiday allowance and leave year; nil means 25 days from January.
    var leave: LeavePolicy?
    /// The org's harness, a repo of plans, requirements and skills beside
    /// the code: where work in any repo no project's harness names runs,
    /// and where the team's data is kept. Nil for none.
    var harness: HarnessConfig?
    /// Harnesses beside the org's, from before projects had their own;
    /// only read, and moved into projects (`moveHarnessesToProjects`).
    /// The user's own, as `harness` is.
    var otherHarnesses: [HarnessConfig] = []
    /// Saved field views, in sidebar order.
    var fieldViews: [FieldView] = []
    /// Delivery targets, for the org and its teams; nil for none.
    var goals: MetricGoals?
    /// What Claude is asked when drafting a new harness document, by kind
    /// (`HarnessKind.singular`); a kind missing here gets Gannin's default
    /// (`HarnessAuthoring`).
    var authoring: [String: String]?
    /// How often the team recaps what it closed (Rituals › Recap); nil
    /// means every two weeks from a Monday.
    var recap: RecapCadence?

    var recapCadence: RecapCadence { recap ?? RecapCadence() }
    /// Projects: named groups of repos (a product, a side project), each
    /// with its own harness and settings if it wants them. A window picks
    /// one to narrow to it.
    var repoProjects: [RepoProject] = []
    /// The window's project's repos, set by `OrgConfigStore.config(for:)`
    /// and never saved: everything outside them is left out as excluded
    /// repos are.
    var focusRepos: Set<String>?
    /// The window's project, laid over the org's settings by
    /// `OrgConfigStore.config(for:)` and never saved; nil for All.
    var scope: RepoProject?

    /// The repo whose linked boards the window lists; nil for every board.
    var boardsRepo: String? { scope?.boardsRepo }

    /// What views check a repo against: excluded, or outside the project.
    var repoExclusion: RepoExclusion { RepoExclusion(excluded: excludedRepos, focus: focusRepos) }

    /// Repos not to fetch CI runs for: excluded ones no project names, the
    /// same whichever project a window has picked.
    var unfetchedRepos: Set<String> { excludedRepos.subtracting(repoProjects.flatMap(\.repos)) }

    /// The scorecard's measurables, by cadence; nil until edited, when the
    /// goals stand in as weekly ones (`measurables`).
    var scorecard: [Measurable]?

    var leavePolicy: LeavePolicy { leave ?? LeavePolicy() }

    /// The harnesses in view: the project's own, with one picked that has
    /// one; else every harness, the org's first, then each project's.
    var harnesses: [HarnessConfig] {
        if let own = scope?.ownHarness { return [own] }
        return allHarnesses
    }

    /// Every harness, the org's first, then any left from before projects,
    /// then each project's (for its repos).
    var allHarnesses: [HarnessConfig] {
        var seen: Set<String> = []
        let projects = repoProjects.compactMap(\.ownHarness)
        return ((harness.map { [$0] } ?? []) + otherHarnesses + projects).filter { seen.insert($0.repo).inserted }
    }

    /// Where work in these repos runs: the project's harness, with one
    /// picked that has one; else the first harness that names one of them,
    /// else one that names none (it takes any other repo), else the first.
    func harness(covering repos: [String]) -> HarnessConfig? {
        let all = harnesses
        for repo in repos {
            if let match = all.first(where: { $0.covers(repo) }) { return match }
        }
        return all.first { ($0.repos ?? []).isEmpty } ?? all.first
    }

    /// Makes another harness the one the team's data is read from (the
    /// org's, in `harness`): one left from before projects.
    mutating func keepTeamData(in repo: String) {
        guard let index = otherHarnesses.firstIndex(where: { $0.repo == repo }) else { return }
        let target = otherHarnesses.remove(at: index)
        if let current = harness { otherHarnesses.insert(current, at: 0) }
        harness = target
    }

    /// Takes a harness away; the next keeps the team's data if it was this
    /// one's.
    mutating func removeHarness(_ repo: String) {
        if harness?.repo == repo {
            harness = otherHarnesses.isEmpty ? nil : otherHarnesses.removeFirst()
        } else {
            otherHarnesses.removeAll { $0.repo == repo }
        }
    }

    /// Changes a harness, wherever it's kept: the org's, one left from
    /// before projects, or a project's.
    mutating func updateHarness(_ repo: String, _ change: (inout HarnessConfig) -> Void) {
        if harness?.repo == repo, var setup = harness {
            change(&setup)
            harness = setup
        } else if let index = otherHarnesses.firstIndex(where: { $0.repo == repo }) {
            change(&otherHarnesses[index])
        } else if let index = repoProjects.firstIndex(where: { $0.harness?.repo == repo }), var setup = repoProjects[index].harness {
            change(&setup)
            repoProjects[index].harness = setup
        }
    }

    /// Any of the org's harnesses by repo, whichever project is picked.
    func harness(repo: String) -> HarnessConfig? { allHarnesses.first { $0.repo == repo } }

    /// Lays a project over the org's settings: its repos, and whatever it
    /// keeps of its own. A project naming no repos yet leaves every repo in.
    mutating func apply(_ project: RepoProject) {
        scope = project
        if !project.repos.isEmpty { focusRepos = Set(project.repos) }
        if let own = project.workflow { issueWorkflow = own }
        if let own = project.investments { investments = own }
        if let own = project.goals { goals = own }
        if let own = project.scorecard { scorecard = own }
        if let own = project.recap { recap = own }
    }

    /// Undoes `apply` after a change made with a project laid over the
    /// settings (`before`, from the saved `base`): each setting the project
    /// keeps of its own goes back to the org's, its change kept in the
    /// project instead. The rest stay as changed, the org's.
    mutating func separate(project id: UUID, base: OrgConfig, before: OrgConfig) {
        focusRepos = nil
        scope = nil
        guard let index = repoProjects.firstIndex(where: { $0.id == id }) else { return }
        var project = repoProjects[index]
        route(\.issueWorkflow, \.workflow, empty: IssueWorkflow(), base: base, before: before, project: &project)
        route(\.investments, \.investments, empty: .default, base: base, before: before, project: &project)
        route(\.goals, \.goals, empty: MetricGoals(), base: base, before: before, project: &project)
        route(\.scorecard, \.scorecard, empty: [], base: base, before: before, project: &project)
        route(\.recap, \.recap, empty: RecapCadence(), base: base, before: before, project: &project)
        repoProjects[index] = project
    }

    /// A setting the org leaves nil for its default stays the project's
    /// own as that default (`empty`).
    private mutating func route<Value: Equatable>(
        _ setting: WritableKeyPath<OrgConfig, Value?>, _ own: WritableKeyPath<RepoProject, Value?>, empty: Value,
        base: OrgConfig, before: OrgConfig, project: inout RepoProject
    ) {
        guard project[keyPath: own] != nil else { return }
        let value = self[keyPath: setting]
        if value != before[keyPath: setting] { project[keyPath: own] = value ?? empty }
        self[keyPath: setting] = base[keyPath: setting]
    }

    /// Harnesses beside the org's, from before projects had harnesses,
    /// become projects: one with the same repos takes the harness, else a
    /// new one named after it. Names alone become `org/name`.
    mutating func moveHarnessesToProjects(org: String) {
        for setup in otherHarnesses where !repoProjects.contains(where: { $0.harness?.repo == setup.repo }) {
            let repos = (setup.repos ?? []).map { $0.contains("/") ? $0 : "\(org)/\($0)" }
            var own = setup
            own.repos = nil
            if !repos.isEmpty, let index = repoProjects.firstIndex(where: { $0.harness == nil && Set($0.repos) == Set(repos) }) {
                repoProjects[index].harness = own
            } else {
                repoProjects.append(RepoProject(name: setup.name, repos: repos, harness: own))
            }
        }
        otherHarnesses = []
    }

    var workflow: IssueWorkflow { issueWorkflow ?? IssueWorkflow() }

    var investmentConfig: InvestmentConfig { investments ?? .default }

    init() {}

    /// Tolerates configs saved before a field existed.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        excludedRepos = try container.decodeIfPresent(Set<String>.self, forKey: .excludedRepos) ?? []
        excludedAuthors = try container.decodeIfPresent(Set<String>.self, forKey: .excludedAuthors) ?? []
        includedAuthors = try container.decodeIfPresent(Set<String>.self, forKey: .includedAuthors) ?? []
        reposWithoutReview = try container.decodeIfPresent(Set<String>.self, forKey: .reposWithoutReview) ?? []
        investments = try container.decodeIfPresent(InvestmentConfig.self, forKey: .investments)
        issueWorkflow = try container.decodeIfPresent(IssueWorkflow.self, forKey: .issueWorkflow)
        workWeek = try container.decodeIfPresent(WorkWeek.self, forKey: .workWeek)
        leave = try container.decodeIfPresent(LeavePolicy.self, forKey: .leave)
        harness = try container.decodeIfPresent(HarnessConfig.self, forKey: .harness)
        otherHarnesses = try container.decodeIfPresent([HarnessConfig].self, forKey: .otherHarnesses) ?? []
        fieldViews = try container.decodeIfPresent([FieldView].self, forKey: .fieldViews) ?? []
        goals = try container.decodeIfPresent(MetricGoals.self, forKey: .goals)
        authoring = try container.decodeIfPresent([String: String].self, forKey: .authoring)
        recap = try container.decodeIfPresent(RecapCadence.self, forKey: .recap)
        scorecard = try container.decodeIfPresent([Measurable].self, forKey: .scorecard)
        repoProjects = try container.decodeIfPresent([RepoProject].self, forKey: .repoProjects) ?? []
    }

    var isEmpty: Bool { excludedRepos.isEmpty && excludedAuthors.isEmpty && includedAuthors.isEmpty && reposWithoutReview.isEmpty && investments == nil && issueWorkflow == nil && workWeek == nil && leave == nil && harness == nil && otherHarnesses.isEmpty && fieldViews.isEmpty && goals == nil && authoring == nil && recap == nil && scorecard == nil && repoProjects.isEmpty }

    /// Automation accounts that are ordinary GitHub users (so GraphQL doesn't
    /// type them as `Bot`) usually follow these naming conventions.
    static func looksLikeBot(_ login: String) -> Bool {
        let lower = login.lowercased()
        return lower.hasSuffix("-bot") || lower.hasSuffix("[bot]")
    }

    /// Whether the repo's PRs should have a review before they merge.
    func needsReview(_ repo: String) -> Bool { !reposWithoutReview.contains(repo) }

    func excludes(_ login: String) -> Bool {
        if excludedAuthors.contains(login) { return true }
        return Self.looksLikeBot(login) && !includedAuthors.contains(login)
    }
}

/// Each org's settings, in memory and written through to the synced
/// `UserDatabase`; loaded again when another device's changes arrive.
///
/// An org that keeps its team data in its harness (`HarnessTeamStore`) has
/// its views, investments, issue workflow, working week, leave policy and
/// exclusions from there instead, and changes to them wait to be committed
/// there. Which harness it is stays the user's own.
///
/// The app shares one store, for All. A main window with a project picked
/// puts that project's store (`scoped`) in its environment instead: the
/// same settings, read with the project laid over them, and changes to
/// what the project keeps of its own written to the project.
@Observable
final class OrgConfigStore {
    /// The settings themselves, shared by every window's store.
    @Observable
    final class Storage {
        var configs: [String: OrgConfig]
        @ObservationIgnored let database: UserDatabase
        @ObservationIgnored var team: HarnessTeamStore?
        @ObservationIgnored weak var root: OrgConfigStore?
        @ObservationIgnored var scopes: [UUID: OrgConfigStore] = [:]

        init(database: UserDatabase) {
            self.database = database
            configs = database.loadConfigs()
            database.onRemoteChange { [weak self] in
                guard let self else { return }
                let loaded = database.loadConfigs()
                if loaded != configs { configs = loaded }
            }
        }
    }

    private let storage: Storage
    /// The project the window's picked (`RepoProject.id`); nil for All,
    /// and for the store the app shares.
    let workspace: UUID?

    init(database: UserDatabase) {
        storage = Storage(database: database)
        workspace = nil
        storage.root = self
    }

    private init(storage: Storage, workspace: UUID) {
        self.storage = storage
        self.workspace = workspace
    }

    var configs: [String: OrgConfig] { storage.configs }

    var team: HarnessTeamStore? {
        get { storage.team }
        set { storage.team = newValue }
    }

    /// The store the app shares, for All: Settings, and anything outside
    /// a main window.
    var root: OrgConfigStore { storage.root ?? self }

    /// A window's store for a project; nil is the one the app shares.
    func scoped(_ workspace: UUID?) -> OrgConfigStore {
        guard let workspace else { return root }
        if let store = storage.scopes[workspace] { return store }
        let store = OrgConfigStore(storage: storage, workspace: workspace)
        storage.scopes[workspace] = store
        return store
    }

    /// The settings, with the window's project laid over them.
    func config(for org: String) -> OrgConfig {
        var config = baseConfig(for: org)
        if let project = findProject(workspace, in: config) { config.apply(project) }
        return config
    }

    /// The settings as saved, with no project laid over them: for editing.
    func baseConfig(for org: String) -> OrgConfig {
        let own = storage.configs[org] ?? OrgConfig()
        return storage.team?.data(for: org)?.applied(to: own) ?? own
    }

    private func findProject(_ id: UUID?, in config: OrgConfig) -> RepoProject? {
        id.flatMap { id in config.repoProjects.first { $0.id == id } }
    }

    /// The window's project, if it still exists.
    func currentProject(_ org: String) -> RepoProject? {
        findProject(workspace, in: baseConfig(for: org))
    }

    /// The org's harness, from the user's own settings.
    func harness(for org: String) -> HarnessConfig? { storage.configs[org]?.harness }

    /// Every org back to the defaults.
    func clear() {
        storage.configs = [:]
        storage.database.deleteAllConfigs()
    }

    /// Changes the settings as the window sees them: with a project picked,
    /// what it keeps of its own changes in the project, the rest in the org.
    func update(_ org: String, _ change: (inout OrgConfig) -> Void) {
        let base = baseConfig(for: org)
        guard let workspace, let project = findProject(workspace, in: base) else {
            return save(org, change)
        }
        var before = base
        before.apply(project)
        var after = before
        change(&after)
        save(org) { config in
            config = after
            config.separate(project: workspace, base: base, before: before)
        }
    }

    /// Changes one project, whichever the window has picked.
    func updateProject(_ id: UUID, in org: String, _ change: (inout RepoProject) -> Void) {
        save(org) { config in
            guard let index = config.repoProjects.firstIndex(where: { $0.id == id }) else { return }
            change(&config.repoProjects[index])
        }
    }

    /// Moves the harnesses left from before projects into projects, once
    /// per org that has any, and forgets the account-wide focus each
    /// window's project replaced. Team data waits to be committed, as any
    /// change. An org whose harness isn't indexed yet waits for the next
    /// launch, so projects kept in its team data aren't missed.
    func moveHarnessesToProjects() {
        UserDefaults.standard.removeObject(forKey: "repoFocus")
        for (org, config) in storage.configs where !config.otherHarnesses.isEmpty {
            if let setup = config.harness, storage.team?.harness.index(for: org, setup) == nil { continue }
            save(org) { $0.moveHarnessesToProjects(org: org) }
        }
    }

    /// Writes the org's settings as given, with no project laid over them.
    private func save(_ org: String, _ change: (inout OrgConfig) -> Void) {
        let before = baseConfig(for: org)
        var config = before
        change(&config)
        // The window's project is its view, not a setting.
        config.focusRepos = nil
        config.scope = nil
        guard config != before else { return }
        if let team, team.keepsData(org) {
            team.stage(org: org, HarnessTeamData.changedFiles(from: before, to: config))
            // Only which harnesses are the user's own here.
            guard config.harness != before.harness || config.otherHarnesses != before.otherHarnesses else { return }
            var own = storage.configs[org] ?? OrgConfig()
            own.harness = config.harness
            own.otherHarnesses = config.otherHarnesses
            storage.configs[org] = own.isEmpty ? nil : own
            storage.database.saveConfig(org: org, own.isEmpty ? nil : own)
            return
        }
        storage.configs[org] = config.isEmpty ? nil : config
        storage.database.saveConfig(org: org, config.isEmpty ? nil : config)
    }

    func updateInvestments(_ org: String, _ change: (inout InvestmentConfig) -> Void) {
        update(org) { config in
            var investments = config.investmentConfig
            change(&investments)
            config.investments = investments
        }
    }

    /// Chooses a PR's category by hand; nil goes back to the rules.
    func setCategory(_ categoryID: UUID?, for prID: String, in org: String) {
        updateInvestments(org) { $0.manual[prID] = categoryID }
    }

    func fieldView(_ id: UUID, in org: String) -> FieldView? {
        config(for: org).fieldViews.first { $0.id == id }
    }

    /// Adds the view, or replaces the one with its ID.
    func saveFieldView(_ view: FieldView, in org: String) {
        update(org) { config in
            if let index = config.fieldViews.firstIndex(where: { $0.id == view.id }) {
                config.fieldViews[index] = view
            } else {
                config.fieldViews.append(view)
            }
        }
    }

    func deleteFieldView(_ id: UUID, in org: String) {
        update(org) { $0.fieldViews.removeAll { $0.id == id } }
    }

    func toggleRepo(_ repo: String, in org: String) {
        update(org) { config in
            if config.excludedRepos.remove(repo) == nil { config.excludedRepos.insert(repo) }
        }
    }

    func toggleReview(_ repo: String, in org: String) {
        update(org) { config in
            if config.reposWithoutReview.remove(repo) == nil { config.reposWithoutReview.insert(repo) }
        }
    }

    func toggleAuthor(_ login: String, in org: String) {
        update(org) { config in
            if config.excludes(login) {
                config.excludedAuthors.remove(login)
                if OrgConfig.looksLikeBot(login) { config.includedAuthors.insert(login) }
            } else {
                config.includedAuthors.remove(login)
                if !OrgConfig.looksLikeBot(login) { config.excludedAuthors.insert(login) }
            }
        }
    }
}
