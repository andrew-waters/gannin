import Foundation

/// The kinds of agent work Gannin runs, each through a workflow
/// (andrew-waters/gannin#466): a chain of stages of steps, each step an
/// agent (a specialist, or none for Gannin's own prompt) on a provider. An
/// activity with no workflow in the harness runs its built-in one, a
/// single step that behaves as the activity always has.
nonisolated enum WorkflowActivity: String, Codable, CaseIterable, Identifiable, Sendable {
    case review
    case work
    case quickChange = "quick-change"
    case ask
    case planning
    case refine

    var id: String { rawValue }

    /// As the app names it.
    var title: String {
        switch self {
        case .review: "Reviews"
        case .work: "Work on This"
        case .quickChange: "Quick Change"
        case .ask: "Ask"
        case .planning: "Planning"
        case .refine: "Design and Refine"
        }
    }

    /// Has one step a person types in (the session); a review's steps all
    /// run by themselves.
    var isInteractive: Bool { self != .review }

    /// Picks its workflow by routing rules: reviews by the PR, coding by
    /// the issue. The rest always run their default.
    var isRouted: Bool { self == .review || self == .work }
}

/// One step of a workflow: who does it (a specialist from the harness's
/// `specialists/`, by name, or Gannin's own prompt when none), on which
/// provider and model, with what focus, for how many rounds. Unset fields
/// fall back to the specialist's front matter, then to the app's settings.
nonisolated struct AgentStep: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var specialist: String?
    /// A `ProviderID`, kept as written so a newer build's isn't lost.
    var provider: String?
    var model: String?
    var focus: String?
    /// A review step's passes over the diff; one when unset.
    var rounds: Int?
    /// The session the user types in, in an interactive activity's
    /// workflow. Exactly one step there has it.
    var interactive: Bool?

    init(id: String = UUID().uuidString.lowercased(), specialist: String? = nil, provider: String? = nil, model: String? = nil, focus: String? = nil, rounds: Int? = nil, interactive: Bool? = nil) {
        self.id = id
        self.specialist = specialist
        self.provider = provider
        self.model = model
        self.focus = focus
        self.rounds = rounds
        self.interactive = interactive
    }

    var isInteractive: Bool { interactive == true }

    /// At least one, at most `maxRounds`.
    var roundCount: Int { min(max(rounds ?? 1, 1), Self.maxRounds) }

    static let maxRounds = 5
}

/// Steps that run side by side and join before the next stage. A step sees
/// the findings of earlier stages, not of the steps beside it.
nonisolated struct AgentStage: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var steps: [AgentStep]

    init(id: String = UUID().uuidString.lowercased(), steps: [AgentStep]) {
        self.id = id
        self.steps = steps
    }
}

nonisolated struct AgentWorkflow: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var stages: [AgentStage]

    init(id: String = UUID().uuidString.lowercased(), name: String, stages: [AgentStage]) {
        self.id = id
        self.name = name
        self.stages = stages
    }

    /// Every step, stage by stage.
    var steps: [AgentStep] { stages.flatMap(\.steps) }

    /// The step an interactive activity's session is.
    var interactiveStep: AgentStep? { steps.first(where: \.isInteractive) }

    /// One-shot steps before and after the interactive one.
    var stepsBefore: [AgentStep] {
        guard let index = stages.firstIndex(where: { $0.steps.contains(where: \.isInteractive) }) else { return [] }
        return stages[..<index].flatMap(\.steps)
    }

    var stepsAfter: [AgentStep] {
        guard let index = stages.firstIndex(where: { $0.steps.contains(where: \.isInteractive) }) else { return [] }
        return stages[(index + 1)...].flatMap(\.steps)
    }

    /// The id the built-in workflows share; never written to the harness.
    static let builtInID = "built-in"

    var isBuiltIn: Bool { id == Self.builtInID }

    /// What an activity runs when the harness gives it no workflow: one
    /// step, Gannin's own prompt on the provider and model in Settings.
    static func builtIn(_ activity: WorkflowActivity) -> AgentWorkflow {
        AgentWorkflow(
            id: builtInID, name: "Gannin's default",
            stages: [AgentStage(id: builtInID, steps: [AgentStep(id: builtInID, interactive: activity.isInteractive ? true : nil)])]
        )
    }

    /// Whether it does just what the activity does with no workflow: one
    /// step with no specialist, provider, model or focus of its own, one
    /// round. A run of it is today's, exactly.
    var isPlain: Bool {
        guard stages.count == 1, let step = stages.first?.steps.first, stages[0].steps.count == 1 else { return false }
        return step.specialist == nil && step.provider == nil && step.model == nil && (step.focus ?? "").isEmpty && step.roundCount == 1
    }
}

/// Sends a review or an issue to a workflow when it matches. Every list
/// set must match (any of its entries); a rule with none set matches all.
/// Reviews match on repo, author, labels and changed paths; coding on
/// repo, labels and issue type.
nonisolated struct RoutingRule: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var workflow: String
    /// `owner/name` or the name alone.
    var repos: [String]?
    /// Logins, without `@`.
    var authors: [String]?
    var labels: [String]?
    /// Globs on changed paths: `*` within a folder, `**` across them.
    var paths: [String]?
    var issueTypes: [String]?

    init(id: String = UUID().uuidString.lowercased(), workflow: String, repos: [String]? = nil, authors: [String]? = nil, labels: [String]? = nil, paths: [String]? = nil, issueTypes: [String]? = nil) {
        self.id = id
        self.workflow = workflow
        self.repos = repos
        self.authors = authors
        self.labels = labels
        self.paths = paths
        self.issueTypes = issueTypes
    }

    func matches(_ subject: WorkflowSubject) -> Bool {
        func any(_ list: [String]?, _ test: (String) -> Bool) -> Bool {
            let list = (list ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return list.isEmpty || list.contains(where: test)
        }
        return any(repos) { RoutingRule.sameRepo($0, subject.repo) }
            && any(authors) { author in subject.author.map { $0.caseInsensitiveCompare(author.trimmingPrefix("@")) == .orderedSame } ?? false }
            && any(labels) { label in subject.labels.contains { $0.caseInsensitiveCompare(label) == .orderedSame } }
            && any(paths) { glob in subject.paths.contains { Glob.matches(glob, $0) } }
            && any(issueTypes) { type in subject.issueType.map { $0.caseInsensitiveCompare(type) == .orderedSame } ?? false }
    }

    static func sameRepo(_ pattern: String, _ repo: String) -> Bool {
        let pattern = pattern.lowercased(), repo = repo.lowercased()
        return pattern == repo || pattern == repo.split(separator: "/").last.map(String.init)
    }
}

/// What a rule is matched against: a PR for a review, an issue for coding.
nonisolated struct WorkflowSubject: Hashable, Sendable {
    var repo: String
    var author: String?
    var labels: [String] = []
    var paths: [String] = []
    var issueType: String?
}

/// One activity's workflows, which is its default, and its routing rules
/// in order (the first match wins).
nonisolated struct ActivityWorkflows: Codable, Hashable, Sendable {
    var workflows: [AgentWorkflow]
    var defaultWorkflow: String?
    var rules: [RoutingRule]?

    init(workflows: [AgentWorkflow] = [], defaultWorkflow: String? = nil, rules: [RoutingRule]? = nil) {
        self.workflows = workflows
        self.defaultWorkflow = defaultWorkflow
        self.rules = rules
    }

    enum CodingKeys: String, CodingKey {
        case workflows
        case defaultWorkflow = "default"
        case rules
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A workflow a newer build wrote that this one can't read is left out
        // rather than losing the rest.
        workflows = (try? container.decodeIfPresent([Leniently<AgentWorkflow>].self, forKey: .workflows))?.compactMap(\.value) ?? []
        defaultWorkflow = try? container.decodeIfPresent(String.self, forKey: .defaultWorkflow)
        rules = (try? container.decodeIfPresent([Leniently<RoutingRule>].self, forKey: .rules))?.compactMap(\.value)
    }
}

/// The project's agent workflows, `.gannin/agent-workflows.json` in its
/// harness: per activity, by `WorkflowActivity` raw value. An activity a
/// newer build knows is kept as it is.
nonisolated struct AgentWorkflows: Codable, Hashable, Sendable {
    var activities: [String: ActivityWorkflows]

    init(activities: [String: ActivityWorkflows] = [:]) {
        self.activities = activities
    }

    /// The file is the activities by name, at its top level.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        activities = (try? container.decode([String: Leniently<ActivityWorkflows>].self))?.compactMapValues(\.value) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(activities)
    }

    subscript(activity: WorkflowActivity) -> ActivityWorkflows {
        get { activities[activity.rawValue] ?? ActivityWorkflows() }
        set { activities[activity.rawValue] = newValue }
    }

    /// The activity's workflows as offered: the built-in one first, then the
    /// harness's.
    func workflows(for activity: WorkflowActivity) -> [AgentWorkflow] {
        [AgentWorkflow.builtIn(activity)] + self[activity].workflows.filter { !$0.isBuiltIn }
    }

    func workflow(_ id: String, for activity: WorkflowActivity) -> AgentWorkflow? {
        workflows(for: activity).first { $0.id == id }
    }

    /// The activity's default: the one the harness names, else built in.
    func defaultWorkflow(for activity: WorkflowActivity) -> AgentWorkflow {
        self[activity].defaultWorkflow.flatMap { workflow($0, for: activity) } ?? .builtIn(activity)
    }

    /// The first rule that matches picks the workflow (skipping one whose
    /// workflow is gone), else the default. Activities that aren't routed
    /// run their default.
    func resolve(_ activity: WorkflowActivity, for subject: WorkflowSubject?) -> AgentWorkflow {
        if activity.isRouted, let subject {
            for rule in self[activity].rules ?? [] where rule.matches(subject) {
                if let workflow = workflow(rule.workflow, for: activity) { return workflow }
            }
        }
        return defaultWorkflow(for: activity)
    }
}

/// The most passes a run can make (steps times rounds), by provider and
/// model, for the run picker.
nonisolated struct PassCount: Hashable, Sendable {
    let label: String
    let passes: Int

    /// A review whose first stage has no Claude Code step gets Gannin's own
    /// step there too (its lead runs one), so that pass is counted.
    static func of(_ workflow: AgentWorkflow, specialists: [String: HarnessSpecialist], defaultModel: String?, activity: WorkflowActivity? = nil) -> [PassCount] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        var steps = workflow.steps
        if activity == .review, !workflow.isPlain, let first = workflow.stages.first, !first.steps.contains(where: { step in
            let specialist = step.specialist.flatMap { specialists[$0.lowercased()] }
            return ProviderID(name: step.provider ?? specialist?.provider)?.isInteractive ?? (step.provider ?? specialist?.provider == nil)
        }) {
            steps.insert(AgentStep(id: AgentWorkflow.builtInID), at: 0)
        }
        for step in steps {
            let specialist = step.specialist.flatMap { specialists[$0.lowercased()] }
            let provider = ProviderID(name: step.provider ?? specialist?.provider) ?? .claudeCode
            let model = (step.model ?? specialist?.model ?? (provider == .claudeCode ? defaultModel : nil)).flatMap { $0.isEmpty ? nil : $0 }
            let label = model.map { "\(provider.title), \($0)" } ?? provider.title
            if counts[label] == nil { order.append(label) }
            counts[label, default: 0] += step.isInteractive ? 1 : step.roundCount
        }
        return order.map { PassCount(label: $0, passes: counts[$0] ?? 0) }
    }
}

/// One item of a list, nil when it doesn't decode, so the rest still do.
private nonisolated struct Leniently<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}
