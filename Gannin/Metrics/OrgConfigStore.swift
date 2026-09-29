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
    /// Investment categories; nil until edited, meaning the default preset.
    var investments: InvestmentConfig?
    /// How issues move through the org's board; nil means the defaults.
    var issueWorkflow: IssueWorkflow?
    /// Working days and hours; nil means Monday to Friday, 9 to 5.
    var workWeek: WorkWeek?

    var week: WorkWeek { workWeek ?? WorkWeek() }
    /// Holiday allowance and leave year; nil means 25 days from January.
    var leave: LeavePolicy?
    /// The repo of plans and requirements kept beside the code; nil for none.
    var harness: HarnessConfig?
    /// Saved field views, in sidebar order.
    var fieldViews: [FieldView] = []

    var leavePolicy: LeavePolicy { leave ?? LeavePolicy() }

    var workflow: IssueWorkflow { issueWorkflow ?? IssueWorkflow() }

    var investmentConfig: InvestmentConfig { investments ?? .default }

    init() {}

    /// Tolerates configs saved before a field existed.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        excludedRepos = try container.decodeIfPresent(Set<String>.self, forKey: .excludedRepos) ?? []
        excludedAuthors = try container.decodeIfPresent(Set<String>.self, forKey: .excludedAuthors) ?? []
        includedAuthors = try container.decodeIfPresent(Set<String>.self, forKey: .includedAuthors) ?? []
        investments = try container.decodeIfPresent(InvestmentConfig.self, forKey: .investments)
        issueWorkflow = try container.decodeIfPresent(IssueWorkflow.self, forKey: .issueWorkflow)
        workWeek = try container.decodeIfPresent(WorkWeek.self, forKey: .workWeek)
        leave = try container.decodeIfPresent(LeavePolicy.self, forKey: .leave)
        harness = try container.decodeIfPresent(HarnessConfig.self, forKey: .harness)
        fieldViews = try container.decodeIfPresent([FieldView].self, forKey: .fieldViews) ?? []
    }

    var isEmpty: Bool { excludedRepos.isEmpty && excludedAuthors.isEmpty && includedAuthors.isEmpty && investments == nil && issueWorkflow == nil && workWeek == nil && leave == nil && harness == nil && fieldViews.isEmpty }

    /// Automation accounts that are ordinary GitHub users (so GraphQL doesn't
    /// type them as `Bot`) usually follow these naming conventions.
    static func looksLikeBot(_ login: String) -> Bool {
        let lower = login.lowercased()
        return lower.hasSuffix("-bot") || lower.hasSuffix("[bot]")
    }

    func excludes(_ login: String) -> Bool {
        if excludedAuthors.contains(login) { return true }
        return Self.looksLikeBot(login) && !includedAuthors.contains(login)
    }
}

/// Each org's settings, in memory and written through to the synced
/// `UserDatabase`; loaded again when another device's changes arrive.
@Observable
final class OrgConfigStore {
    private(set) var configs: [String: OrgConfig]
    @ObservationIgnored private let database: UserDatabase

    init(database: UserDatabase) {
        self.database = database
        configs = database.loadConfigs()
        database.onRemoteChange { [weak self] in
            guard let self else { return }
            let loaded = database.loadConfigs()
            if loaded != configs { configs = loaded }
        }
    }

    func config(for org: String) -> OrgConfig { configs[org] ?? OrgConfig() }

    /// Every org back to the defaults.
    func clear() {
        configs = [:]
        database.deleteAllConfigs()
    }

    func update(_ org: String, _ change: (inout OrgConfig) -> Void) {
        let before = config(for: org)
        var config = before
        change(&config)
        guard config != before else { return }
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
