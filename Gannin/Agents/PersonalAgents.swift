import Foundation

/// Your own specialists, workflows, routing rules and defaults for an org:
/// kept in the user database beside stars, never in a harness, so a
/// specialist aimed at one person stays with whoever wrote it. Workflows
/// are per project (by harness repo), as the team's are; specialists are
/// for every project in the org.
nonisolated struct PersonalAgents: Codable, Hashable, Sendable {
    var specialists: [PersonalSpecialist] = []
    /// By harness repo: your workflows, your default for each activity
    /// (which can name a team workflow) and your routing rules (checked
    /// before the team's).
    var projects: [String: AgentWorkflows] = [:]

    init(specialists: [PersonalSpecialist] = [], projects: [String: AgentWorkflows] = [:]) {
        self.specialists = specialists
        self.projects = projects
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        specialists = (try? container.decodeIfPresent([Leniently<PersonalSpecialist>].self, forKey: .specialists))?.compactMap(\.value) ?? []
        projects = (try? container.decodeIfPresent([String: AgentWorkflows].self, forKey: .projects)) ?? [:]
    }

    var isEmpty: Bool {
        specialists.isEmpty && projects.values.allSatisfy { workflows in
            workflows.activities.values.allSatisfy { $0.workflows.isEmpty && $0.defaultWorkflow == nil && ($0.rules ?? []).isEmpty }
        }
    }

    mutating func save(_ specialist: PersonalSpecialist) {
        if let index = specialists.firstIndex(where: { $0.name == specialist.name }) {
            specialists[index] = specialist
        } else {
            specialists.append(specialist)
        }
    }
}

/// A specialist of your own: what a team one has, without the file.
nonisolated struct PersonalSpecialist: Codable, Hashable, Sendable {
    /// Its file-style name, `alex-coach`; steps name it with
    /// `HarnessSpecialist.personalPrefix` before it.
    var name: String
    var title: String
    var summary: String?
    var provider: String?
    var model: String?
    var focus: String?
    var soul: String

    /// As workflows and runs use it.
    var specialist: HarnessSpecialist {
        let reference = HarnessSpecialist.personalPrefix + name
        return HarnessSpecialist(path: reference, name: reference, title: title, summary: summary, provider: provider, model: model, focus: focus, soul: soul)
    }

    init(name: String, title: String, summary: String?, provider: String?, model: String?, focus: String?, soul: String) {
        self.name = name
        self.title = title
        self.summary = summary
        self.provider = provider
        self.model = model
        self.focus = focus
        self.soul = soul
    }

    /// Back from what the editor made.
    init(_ specialist: HarnessSpecialist) {
        let name = specialist.name.hasPrefix(HarnessSpecialist.personalPrefix) ? String(specialist.name.dropFirst(HarnessSpecialist.personalPrefix.count)) : specialist.name
        self.init(name: name, title: specialist.title, summary: specialist.summary, provider: specialist.provider, model: specialist.model, focus: specialist.focus, soul: specialist.soul)
    }
}

extension HarnessSpecialist {
    /// Before a personal specialist's name where a step names it: a team
    /// one's name is a file stem, so it can never start with this.
    nonisolated static let personalPrefix = "personal/"

    nonisolated var isPersonal: Bool { name.lowercased().hasPrefix(Self.personalPrefix) }
}

extension AgentStep {
    nonisolated var namesPersonalSpecialist: Bool { specialist?.lowercased().hasPrefix(HarnessSpecialist.personalPrefix) ?? false }
}

extension AgentWorkflow {
    /// It has a step with someone's own specialist, so it can't be the
    /// team's.
    nonisolated var usesPersonalSpecialist: Bool { steps.contains(where: \.namesPersonalSpecialist) }
}

extension AgentWorkflows {
    /// A team file that names a personal specialist, which must never be
    /// committed.
    nonisolated var usesPersonalSpecialist: Bool {
        activities.values.contains { $0.workflows.contains(where: \.usesPersonalSpecialist) }
    }
}

/// The workflows one person can run in a project: Gannin's own, the
/// team's (from the harness) and their own. Routing checks their rules,
/// then the team's, then their default; the team file's own default is
/// ignored, so someone new gets Gannin's until they pick one.
nonisolated struct WorkflowLibrary: Hashable, Sendable {
    var team: AgentWorkflows
    var personal: AgentWorkflows

    init(team: AgentWorkflows = AgentWorkflows(), personal: AgentWorkflows = AgentWorkflows()) {
        self.team = team
        self.personal = personal
    }

    /// Gannin's, the team's, then yours.
    func workflows(for activity: WorkflowActivity) -> [AgentWorkflow] {
        [AgentWorkflow.builtIn(activity)] + team[activity].workflows.filter { !$0.isBuiltIn } + personal[activity].workflows.filter { !$0.isBuiltIn }
    }

    func workflow(_ id: String, for activity: WorkflowActivity) -> AgentWorkflow? {
        workflows(for: activity).first { $0.id == id }
    }

    func isPersonal(_ id: String, for activity: WorkflowActivity) -> Bool {
        personal[activity].workflows.contains { $0.id == id }
    }

    /// Your default, else Gannin's.
    func defaultWorkflow(for activity: WorkflowActivity) -> AgentWorkflow {
        personal[activity].defaultWorkflow.flatMap { workflow($0, for: activity) } ?? .builtIn(activity)
    }

    /// Your rules then the team's, in the order they're checked.
    func rules(for activity: WorkflowActivity) -> [RoutingRule] {
        (personal[activity].rules ?? []) + (team[activity].rules ?? [])
    }

    /// The first matching rule's workflow (yours first, then the team's,
    /// skipping one whose workflow is gone; a team rule only ever sends to
    /// a team workflow), else your default.
    func resolve(_ activity: WorkflowActivity, for subject: WorkflowSubject?) -> AgentWorkflow {
        if activity.isRouted, let subject {
            for rule in personal[activity].rules ?? [] where rule.matches(subject) {
                if let workflow = workflow(rule.workflow, for: activity) { return workflow }
            }
            for rule in team[activity].rules ?? [] where rule.matches(subject) {
                if let workflow = team.workflow(rule.workflow, for: activity) { return workflow }
            }
        }
        return defaultWorkflow(for: activity)
    }
}

/// Everyone's own specialists and workflows on this Mac, by org, from the
/// user database.
@Observable
final class PersonalAgentsStore {
    private(set) var agents: [String: PersonalAgents]
    @ObservationIgnored private let database: UserDatabase

    init(database: UserDatabase) {
        self.database = database
        agents = database.loadPersonalAgents()
        database.onRemoteChange { [weak self] in
            guard let self else { return }
            let loaded = database.loadPersonalAgents()
            if loaded != agents { agents = loaded }
        }
    }

    /// Your specialists, by lower-cased reference (`personal/<name>`).
    func specialists(org: String) -> [String: HarnessSpecialist] {
        Dictionary((agents[org]?.specialists ?? []).map { ($0.specialist.name.lowercased(), $0.specialist) }, uniquingKeysWith: { first, _ in first })
    }

    func workflows(org: String, project: String) -> AgentWorkflows {
        agents[org]?.projects[project] ?? AgentWorkflows()
    }

    func change(org: String, _ edit: (inout PersonalAgents) -> Void) {
        var changed = agents[org] ?? PersonalAgents()
        edit(&changed)
        guard changed != agents[org] ?? PersonalAgents() else { return }
        agents[org] = changed.isEmpty ? nil : changed
        database.savePersonalAgents(org: org, changed.isEmpty ? nil : changed)
    }

    func changeWorkflows(org: String, project: String, _ edit: (inout AgentWorkflows) -> Void) {
        change(org: org) { agents in
            var workflows = agents.projects[project] ?? AgentWorkflows()
            edit(&workflows)
            agents.projects[project] = workflows.fileText == nil ? nil : workflows
        }
    }

    func deleteAll() {
        agents = [:]
        database.deleteAllPersonalAgents()
    }
}
