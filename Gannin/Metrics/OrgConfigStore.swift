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
    /// The home project's harness, a repo of plans, requirements and
    /// skills beside the code: a project of its own, and where the
    /// org-wide data (people's dates, leave, the working week, exclusions,
    /// views) is kept. Nil for none, when everything
    /// stays on this device. The user's own.
    var harness: HarnessConfig?
    /// Every other project's harness, each one project (`RepoProject`).
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
    /// The board's date field that says an issue's committed to
    /// (Prioritisation); nil means `Committed`.
    var committedDateField: String?

    var committedDate: String { committedDateField ?? "Committed" }
    /// Projects, one a harness, home first, as `OrgConfigStore` reads them
    /// from their harnesses; never saved. A window works in one.
    var repoProjects: [RepoProject] = []
    /// The window's project's repos, set by `OrgConfigStore.config(for:)`
    /// and never saved: everything outside them is left out as excluded
    /// repos are.
    var focusRepos: Set<String>?
    /// The window's project, laid over the org's settings by
    /// `OrgConfigStore.config(for:)` and never saved; nil for an org with
    /// no harness.
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

    /// Every project's harness, as it's saved here, home first.
    var projectHarnesses: [HarnessConfig] {
        var seen: Set<String> = []
        return ((harness.map { [$0] } ?? []) + otherHarnesses).filter { seen.insert($0.repo).inserted }
    }

    /// The harnesses in view: the window's project's.
    var harnesses: [HarnessConfig] {
        if let own = scope?.ownHarness { return [own] }
        return allHarnesses
    }

    /// Every project's harness, for its repos, home first.
    var allHarnesses: [HarnessConfig] { repoProjects.map(\.ownHarness) }

    /// Where work in these repos runs: the project's harness, with one
    /// picked; else the first harness that names one of them, else one that
    /// names none (it takes any other repo), else the first.
    func harness(covering repos: [String]) -> HarnessConfig? {
        let all = harnesses
        for repo in repos {
            if let match = all.first(where: { $0.covers(repo) }) { return match }
        }
        return all.first { ($0.repos ?? []).isEmpty } ?? all.first
    }

    /// Adds a project's harness: home if it's the first.
    mutating func addHarness(_ setup: HarnessConfig) {
        guard !projectHarnesses.contains(where: { $0.repo == setup.repo }) else { return }
        if harness == nil { harness = setup } else { otherHarnesses.append(setup) }
    }

    /// Makes another project home, where the org-wide data is read from.
    mutating func makeHome(_ repo: String) {
        guard let index = otherHarnesses.firstIndex(where: { $0.repo == repo }) else { return }
        let target = otherHarnesses.remove(at: index)
        if let current = harness { otherHarnesses.insert(current, at: 0) }
        harness = target
    }

    /// Takes a project's harness away; the next is home if it was.
    mutating func removeHarness(_ repo: String) {
        if harness?.repo == repo {
            harness = otherHarnesses.isEmpty ? nil : otherHarnesses.removeFirst()
        } else {
            otherHarnesses.removeAll { $0.repo == repo }
        }
    }

    /// Changes a project's harness (its branch).
    mutating func updateHarness(_ repo: String, _ change: (inout HarnessConfig) -> Void) {
        if harness?.repo == repo, var setup = harness {
            change(&setup)
            harness = setup
        } else if let index = otherHarnesses.firstIndex(where: { $0.repo == repo }) {
            change(&otherHarnesses[index])
        }
    }

    /// Any of the org's harnesses by repo, whichever project is picked.
    func harness(repo: String) -> HarnessConfig? { allHarnesses.first { $0.repo == repo } }

    /// Narrows to a project: its repos (none leaves every repo in) and
    /// harness. Its own settings are laid on by `OrgConfigStore`.
    mutating func apply(_ project: RepoProject) {
        scope = project
        if !project.repos.isEmpty { focusRepos = Set(project.repos) }
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
        // Projects kept here before each was its own harness: their
        // harnesses become projects.
        let legacy = (try? container.decodeIfPresent([LegacyProject].self, forKey: .repoProjects)) ?? nil
        for setup in (legacy ?? []).compactMap(\.harness) { addHarness(HarnessConfig(repo: setup.repo, branch: setup.branch)) }
        committedDateField = try container.decodeIfPresent(String.self, forKey: .committedDateField)
    }

    var isEmpty: Bool { excludedRepos.isEmpty && excludedAuthors.isEmpty && includedAuthors.isEmpty && reposWithoutReview.isEmpty && investments == nil && issueWorkflow == nil && workWeek == nil && leave == nil && harness == nil && otherHarnesses.isEmpty && fieldViews.isEmpty && goals == nil && authoring == nil && recap == nil && scorecard == nil && repoProjects.isEmpty && committedDateField == nil }

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
/// An org with a harness keeps its team data in its projects' harnesses
/// (`HarnessTeamStore`): the org-wide parts (views, working week, leave
/// policy, exclusions, drafting prompts) in the home project's, and each
/// project's own (investments, issue workflow, goals, scorecard, recap
/// cadence, committed date field, name and repos) in its own; changes wait
/// to be committed there. Which harnesses are its projects stays the
/// user's own.
///
/// The app shares one store, on the home project. A main window puts its
/// project's store (`scoped`) in its environment instead: the same
/// settings, read with that project's laid over them, and changes to the
/// project's own written to its harness.
@Observable
final class OrgConfigStore {
    /// The settings themselves, shared by every window's store.
    @Observable
    final class Storage {
        var configs: [String: OrgConfig]
        @ObservationIgnored let database: UserDatabase
        @ObservationIgnored var team: HarnessTeamStore?
        @ObservationIgnored weak var root: OrgConfigStore?
        @ObservationIgnored var scopes: [String: OrgConfigStore] = [:]

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
    /// The project the window's picked (`RepoProject.id`, its harness's
    /// repo); nil for the store the app shares, which reads home's.
    let workspace: String?

    init(database: UserDatabase) {
        storage = Storage(database: database)
        workspace = nil
        storage.root = self
    }

    private init(storage: Storage, workspace: String) {
        self.storage = storage
        self.workspace = workspace
    }

    var configs: [String: OrgConfig] { storage.configs }

    var team: HarnessTeamStore? {
        get { storage.team }
        set { storage.team = newValue }
    }

    /// The store the app shares, on the home project: anything outside a
    /// main window.
    var root: OrgConfigStore { storage.root ?? self }

    /// A window's store for a project; nil is the one the app shares.
    func scoped(_ workspace: String?) -> OrgConfigStore {
        guard let workspace else { return root }
        if let store = storage.scopes[workspace] { return store }
        let store = OrgConfigStore(storage: storage, workspace: workspace)
        storage.scopes[workspace] = store
        return store
    }

    /// The settings, with the window's project laid over them: its own
    /// settings from its harness, and its repos.
    func config(for org: String) -> OrgConfig {
        var config = baseConfig(for: org)
        guard let project = findProject(workspace, in: config) else { return config }
        if let team = storage.team { config = team.data(for: org, in: project.harness).appliedProject(to: config) }
        config.apply(project)
        return config
    }

    /// The org-wide settings as saved, with no project laid over them: this
    /// device's for an org with no harness, else the home harness's with
    /// every project listed.
    func baseConfig(for org: String) -> OrgConfig {
        let own = storage.configs[org] ?? OrgConfig()
        guard let team = storage.team, let home = own.harness else { return own }
        var config = team.data(for: org, in: home).appliedOrgWide(to: own)
        config.investments = nil
        config.issueWorkflow = nil
        config.goals = nil
        config.recap = nil
        config.scorecard = nil
        config.committedDateField = nil
        config.repoProjects = projects(org, own: own, team: team)
        return config
    }

    /// A project per harness, as each harness describes itself
    /// (`project.json`), else as the old list of projects did, else named
    /// after its repo with every repo.
    private func projects(_ org: String, own: OrgConfig, team: HarnessTeamStore) -> [RepoProject] {
        let setups = own.projectHarnesses
        let legacy = setups.lazy.compactMap { team.data(for: org, in: $0).legacyProjects }.first ?? []
        return setups.map { setup in
            if let file = team.data(for: org, in: setup).project {
                return RepoProject(harness: setup, name: file.name, repos: file.repos, boardsRepo: file.boardsRepo)
            }
            let old = legacy.first { $0.harness?.repo == setup.repo }
            return RepoProject(harness: setup, name: old?.name ?? setup.name, repos: old?.repos ?? [], boardsRepo: old?.boardsRepo)
        }
    }

    /// The project picked, else home.
    private func findProject(_ id: String?, in config: OrgConfig) -> RepoProject? {
        id.flatMap { id in config.repoProjects.first { $0.id == id } } ?? config.repoProjects.first
    }

    /// The window's project: the one picked, else home; nil with no harness.
    func currentProject(_ org: String) -> RepoProject? {
        findProject(workspace, in: baseConfig(for: org))
    }

    /// The org's project harnesses, home first, from the user's own
    /// settings, so they don't move with the team's.
    func harnesses(for org: String) -> [HarnessConfig] { storage.configs[org]?.projectHarnesses ?? [] }

    /// Every org back to the defaults.
    func clear() {
        storage.configs = [:]
        storage.database.deleteAllConfigs()
    }

    /// Changes the settings as the window sees them: the org-wide parts
    /// in the home harness, the project's own in its harness.
    func update(_ org: String, _ change: (inout OrgConfig) -> Void) {
        let before = config(for: org)
        var after = before
        change(&after)
        guard after != before else { return }
        guard let team, team.keepsData(org) else {
            return saveOwn(org) { own in
                own = after
                own.focusRepos = nil
                own.scope = nil
            }
        }
        team.stage(org: org, project: currentProject(org)?.harness, HarnessTeamData.changedFiles(from: before, to: after))
        // Only which harnesses are the user's own here.
        if after.harness != before.harness || after.otherHarnesses != before.otherHarnesses {
            saveOwn(org) { own in
                own.harness = after.harness
                own.otherHarnesses = after.otherHarnesses
            }
        }
    }

    /// Changes which harnesses are the org's projects (adding, removing,
    /// home, a branch): the user's own, whatever the team's data says.
    func updateHarnesses(_ org: String, _ change: (inout OrgConfig) -> Void) {
        saveOwn(org) { own in
            var config = own
            change(&config)
            own.harness = config.harness
            own.otherHarnesses = config.otherHarnesses
        }
    }

    /// Changes a project's name, repos or boards, in its harness.
    func updateProject(_ id: String, in org: String, _ change: (inout RepoProject) -> Void) {
        guard let team, let project = baseConfig(for: org).repoProjects.first(where: { $0.id == id }) else { return }
        var after = project
        change(&after)
        guard after.file != project.file else { return }
        team.stage(org: org, project: project.harness, [TeamFile.project: TeamCoding.encode(after.file)])
    }

    /// Harnesses projects named in the old list of projects (in the org's
    /// harness, `repo-projects.json`) become projects of their own here,
    /// once the home harness is indexed; until then, at the next launch.
    func adoptProjects() {
        guard let team else { return }
        for (org, own) in storage.configs {
            guard let home = own.harness, team.harness.index(for: org, home) != nil else { continue }
            let named = (team.data(for: org, in: home).legacyProjects ?? []).compactMap(\.harness)
            let missing = named.filter { setup in !own.projectHarnesses.contains { $0.repo == setup.repo } }
            guard !missing.isEmpty else { continue }
            saveOwn(org) { own in
                for setup in missing { own.addHarness(HarnessConfig(repo: setup.repo, branch: setup.branch)) }
            }
        }
    }

    /// Writes this device's settings for the org: everything for an org
    /// with no harness, else which harnesses are its projects.
    private func saveOwn(_ org: String, _ change: (inout OrgConfig) -> Void) {
        let before = storage.configs[org] ?? OrgConfig()
        var config = before
        change(&config)
        config.repoProjects = []
        guard config != before else { return }
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
