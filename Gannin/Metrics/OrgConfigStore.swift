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
    /// The org's harnesses, repos of plans, requirements and skills beside
    /// the code, are equals, each for the repos it names (or any repo, for
    /// one naming none). This one is also where the team's data is kept;
    /// nil for none.
    var harness: HarnessConfig?
    /// The rest. The user's own, as `harness` is.
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
    /// Named groups of repos (a product, a side project), for focusing the
    /// whole app on one.
    var repoProjects: [RepoProject] = []
    /// The project in focus's repos, set by `OrgConfigStore.config(for:)`
    /// and never saved: everything outside them is left out as excluded
    /// repos are.
    var focusRepos: Set<String>?

    /// What views check a repo against: excluded, or outside the focus.
    var repoExclusion: RepoExclusion { RepoExclusion(excluded: excludedRepos, focus: focusRepos) }

    /// The scorecard's measurables, by cadence; nil until edited, when the
    /// goals stand in as weekly ones (`measurables`).
    var scorecard: [Measurable]?

    var leavePolicy: LeavePolicy { leave ?? LeavePolicy() }

    /// Every harness, the primary first.
    var harnesses: [HarnessConfig] {
        (harness.map { [$0] } ?? []) + otherHarnesses.filter { $0.repo != harness?.repo }
    }

    /// Where work in these repos runs: the first harness that names one
    /// of them, else one that names none (it takes any other repo), else
    /// the first.
    func harness(covering repos: [String]) -> HarnessConfig? {
        let all = harnesses
        for repo in repos {
            if let match = all.first(where: { $0.covers(repo) }) { return match }
        }
        return all.first { ($0.repos ?? []).isEmpty } ?? all.first
    }

    /// Makes another harness the one the team's data is read from (the
    /// first, in `harness`); the rest keep their order.
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

    /// Changes a harness, wherever it's kept.
    mutating func updateHarness(_ repo: String, _ change: (inout HarnessConfig) -> Void) {
        if harness?.repo == repo, var setup = harness {
            change(&setup)
            harness = setup
        } else if let index = otherHarnesses.firstIndex(where: { $0.repo == repo }) {
            change(&otherHarnesses[index])
        }
    }

    func harness(repo: String) -> HarnessConfig? { harnesses.first { $0.repo == repo } }

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
@Observable
final class OrgConfigStore {
    private(set) var configs: [String: OrgConfig]
    @ObservationIgnored private let database: UserDatabase
    @ObservationIgnored var team: HarnessTeamStore?

    init(database: UserDatabase) {
        self.database = database
        configs = database.loadConfigs()
        database.onRemoteChange { [weak self] in
            guard let self else { return }
            let loaded = database.loadConfigs()
            if loaded != configs { configs = loaded }
        }
    }

    func config(for org: String) -> OrgConfig {
        var config = baseConfig(for: org)
        if let id = focus[org], let project = config.repoProjects.first(where: { $0.id == id }) {
            config.focusRepos = Set(project.repos)
        }
        return config
    }

    /// The settings as saved, with no project in focus: for editing them.
    func baseConfig(for org: String) -> OrgConfig {
        let own = configs[org] ?? OrgConfig()
        return team?.data(for: org)?.applied(to: own) ?? own
    }

    // MARK: Focus

    /// The project each account's focused on, by ID; kept on this Mac.
    private(set) var focus: [String: UUID] = OrgConfigStore.loadFocus()

    private static let focusKey = "repoFocus"

    private static func loadFocus() -> [String: UUID] {
        (UserDefaults.standard.dictionary(forKey: focusKey) as? [String: String] ?? [:]).compactMapValues(UUID.init(uuidString:))
    }

    /// Focuses the account on a project's repos, or on everything (nil).
    func setFocus(_ id: UUID?, in org: String) {
        focus[org] = id
        UserDefaults.standard.set(focus.mapValues(\.uuidString), forKey: Self.focusKey)
    }

    func focusedProject(_ org: String) -> RepoProject? {
        focus[org].flatMap { id in baseConfig(for: org).repoProjects.first { $0.id == id } }
    }

    /// The org's harness, from the user's own settings.
    func harness(for org: String) -> HarnessConfig? { configs[org]?.harness }

    /// Every org back to the defaults.
    func clear() {
        configs = [:]
        database.deleteAllConfigs()
    }

    func update(_ org: String, _ change: (inout OrgConfig) -> Void) {
        let before = baseConfig(for: org)
        var config = before
        change(&config)
        // The focus is the window's view, not a setting.
        config.focusRepos = nil
        guard config != before else { return }
        if let team, team.keepsData(org) {
            team.stage(org: org, HarnessTeamData.changedFiles(from: before, to: config))
            // Only which harnesses are the user's own here.
            guard config.harness != before.harness || config.otherHarnesses != before.otherHarnesses else { return }
            var own = configs[org] ?? OrgConfig()
            own.harness = config.harness
            own.otherHarnesses = config.otherHarnesses
            configs[org] = own.isEmpty ? nil : own
            database.saveConfig(org: org, own.isEmpty ? nil : own)
            return
        }
        configs[org] = config.isEmpty ? nil : config
        database.saveConfig(org: org, config.isEmpty ? nil : config)
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
