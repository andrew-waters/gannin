import Foundation

// Investment balance: which kind of work merged PRs are, by category rules
// in the spirit of Swarmia's investment categories.
//
// A category matches when any of its rules does, and a rule needs all of its
// conditions. A PR's category, in order: a manual choice; the top-most
// category matching the PR itself; then one matching an issue it closes;
// then one matching that issue's parent; otherwise uncategorised.

struct InvestmentCondition: Codable, Hashable, Identifiable {
    enum Field: String, Codable, CaseIterable, Identifiable {
        case label, title, branch, repository, author, issueType, milestone

        var id: Self { self }

        var name: String {
            switch self {
            case .label: "Label"
            case .title: "Title"
            case .branch: "Branch"
            case .repository: "Repository"
            case .author: "Author"
            case .issueType: "Issue type"
            case .milestone: "Milestone"
            }
        }
    }

    enum Operator: String, Codable, CaseIterable, Identifiable {
        case isEqual, contains, startsWith, matches

        var id: Self { self }

        var name: String {
            switch self {
            case .isEqual: "is"
            case .contains: "contains"
            case .startsWith: "starts with"
            case .matches: "matches regex"
            }
        }
    }

    var id = UUID()
    var field: Field
    var op: Operator
    var value: String

    /// Case-insensitive. An empty value never matches, so a half-written
    /// rule doesn't swallow everything.
    func matches(_ item: InvestmentItem) -> Bool {
        let target = value.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return false }
        return item.values(for: field).contains { candidate in
            switch op {
            case .isEqual: candidate.caseInsensitiveCompare(target) == .orderedSame
            case .contains: candidate.localizedCaseInsensitiveContains(target)
            case .startsWith: candidate.lowercased().hasPrefix(target.lowercased())
            case .matches: InvestmentRegex.matches(target, candidate)
            }
        }
    }
}

struct InvestmentRule: Codable, Hashable, Identifiable {
    var id = UUID()
    var conditions: [InvestmentCondition]

    func matches(_ item: InvestmentItem) -> Bool {
        !conditions.isEmpty && conditions.allSatisfy { $0.matches(item) }
    }
}

struct InvestmentCategory: Codable, Hashable, Identifiable {
    /// Categorical colour slots in the dataviz palette's fixed order.
    static let slotCount = 8

    var id = UUID()
    var name: String
    var details: String
    /// 0-7; follows the category, so reordering never repaints it.
    var slot: Int
    var rules: [InvestmentRule]

    func matches(_ item: InvestmentItem) -> Bool {
        rules.contains { $0.matches(item) }
    }
}

struct InvestmentConfig: Codable, Hashable {
    var categories: [InvestmentCategory]
    /// PR node ID to category ID, chosen by hand. Wins over the rules.
    var manual: [String: UUID] = [:]

    static var `default`: InvestmentConfig { InvestmentConfig(categories: InvestmentPreset.balance.categories) }

    func category(id: UUID) -> InvestmentCategory? {
        categories.first { $0.id == id }
    }

    /// The first colour slot no category uses, if any.
    var freeSlot: Int? {
        let used = Set(categories.map(\.slot))
        return (0..<InvestmentCategory.slotCount).first { !used.contains($0) }
    }

    /// Why a PR landed where it did, for tooltips and the drill column.
    enum Source: String {
        case manual = "Chosen by hand"
        case pullRequest = "Matched on the PR"
        case issue = "Matched on a linked issue"
        case parent = "Matched on a linked issue's parent"
    }

    func categorise(_ pr: MetricPullRequest) -> (category: InvestmentCategory, source: Source)? {
        if let id = manual[pr.id], let category = category(id: id) {
            return (category, .manual)
        }
        let levels: [(Source, [InvestmentItem])] = [
            (.pullRequest, [InvestmentItem(pr)]),
            (.issue, pr.linkedIssues.map { InvestmentItem($0.issue) }),
            (.parent, pr.linkedIssues.compactMap(\.parent).map(InvestmentItem.init)),
        ]
        for (source, items) in levels where !items.isEmpty {
            if let category = categories.first(where: { category in items.contains(where: category.matches) }) {
                return (category, source)
            }
        }
        return nil
    }
}

/// The fields of a PR or issue that conditions test. Issue-only fields are
/// empty on a PR and PR-only ones on an issue.
struct InvestmentItem {
    var labels: [String] = []
    var title: String
    var branch: String?
    var repository: String
    var author: String?
    var issueType: String?
    var milestone: String?

    init(_ pr: MetricPullRequest) {
        labels = pr.labels
        title = pr.title
        branch = pr.branch
        repository = pr.repo
        author = pr.author?.login
    }

    init(_ issue: MetricIssue) {
        labels = issue.labels
        title = issue.title
        repository = issue.repo
        issueType = issue.issueType
        milestone = issue.milestone
    }

    func values(for field: InvestmentCondition.Field) -> [String] {
        switch field {
        case .label: labels
        case .title: [title]
        case .branch: branch.map { [$0] } ?? []
        case .repository: [repository, repository.split(separator: "/").last.map(String.init) ?? repository]
        case .author: author.map { [$0] } ?? []
        case .issueType: issueType.map { [$0] } ?? []
        case .milestone: milestone.map { [$0] } ?? []
        }
    }
}

/// Compiled regexes, cached: rules run over every PR on each redraw.
private enum InvestmentRegex {
    nonisolated(unsafe) private static var cache: [String: NSRegularExpression?] = [:]

    static func matches(_ pattern: String, _ text: String) -> Bool {
        let regex: NSRegularExpression?
        if let cached = cache[pattern] {
            regex = cached
        } else {
            regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            cache[pattern] = regex
        }
        guard let regex else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}

// MARK: - Presets

enum InvestmentPreset: String, CaseIterable, Identifiable {
    case balance = "Balance framework"
    case conventionalCommits = "Conventional Commits"

    var id: Self { self }

    var summary: String {
        switch self {
        case .balance: "New things, improving things, keeping the lights on and productivity, from common labels, issue types and commit-style titles."
        case .conventionalCommits: "One category per commit type family, from titles like \"feat:\" and \"fix(api):\"."
        }
    }

    var categories: [InvestmentCategory] {
        switch self {
        case .balance:
            [
                category("New things", "New products, features and integrations.", slot: 0, [
                    [.init(field: .label, op: .matches, value: "^(feature|new feature|enhancement request)$")],
                    [.init(field: .issueType, op: .isEqual, value: "Feature")],
                    [.init(field: .title, op: .matches, value: Self.commitType("feat"))],
                    [.init(field: .branch, op: .startsWith, value: "feat")],
                ]),
                category("Improving things", "Making existing features better: performance, reliability, security, refactoring.", slot: 1, [
                    [.init(field: .label, op: .matches, value: "^(enhancement|improvement|refactor|performance|security|tech debt)$")],
                    [.init(field: .title, op: .matches, value: Self.commitType("refactor|perf"))],
                ]),
                category("Keeping the lights on", "Bugs, incidents, dependency updates and other upkeep.", slot: 2, [
                    [.init(field: .label, op: .matches, value: "^(bug|incident|hotfix|dependencies|security fix)$")],
                    [.init(field: .issueType, op: .isEqual, value: "Bug")],
                    [.init(field: .title, op: .matches, value: Self.commitType("fix|revert"))],
                    [.init(field: .branch, op: .matches, value: "^(dependabot|renovate)/")],
                ]),
                category("Productivity", "Developer tooling, CI, tests, docs and build.", slot: 3, [
                    [.init(field: .label, op: .matches, value: "^(ci|build|tooling|devex|documentation|tests?)$")],
                    [.init(field: .title, op: .matches, value: Self.commitType("chore|ci|build|test|docs|style"))],
                ]),
            ]
        case .conventionalCommits:
            [
                category("Features", "feat", slot: 0, [[.init(field: .title, op: .matches, value: Self.commitType("feat"))]]),
                category("Fixes", "fix, revert", slot: 1, [[.init(field: .title, op: .matches, value: Self.commitType("fix|revert"))]]),
                category("Refactoring and performance", "refactor, perf", slot: 2, [[.init(field: .title, op: .matches, value: Self.commitType("refactor|perf"))]]),
                category("Maintenance", "chore, ci, build, test, docs, style", slot: 3, [[.init(field: .title, op: .matches, value: Self.commitType("chore|ci|build|test|docs|style"))]]),
            ]
        }
    }

    /// `type:`, `type(scope):` or `type!:` at the start of a title.
    private static func commitType(_ types: String) -> String {
        "^(\(types))(\\([^)]*\\))?!?:"
    }

    private func category(_ name: String, _ details: String, slot: Int, _ rules: [[InvestmentCondition]]) -> InvestmentCategory {
        InvestmentCategory(name: name, details: details, slot: slot, rules: rules.map { InvestmentRule(conditions: $0) })
    }
}
