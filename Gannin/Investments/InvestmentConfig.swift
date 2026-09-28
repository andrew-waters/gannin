import Foundation

// Investment balance: which kind of work issues are, in the spirit of
// Swarmia's investment categories.
//
// Each org says how it tracks investments (`InvestmentTracking`), and every
// read and write follows it. Tracked in Gannin, an issue's category is a
// choice made here, else the top-most category whose rules match it, else
// one matching its parent. Tracked in GitHub (a label per category, or an
// option of a board's single-select field), it's what GitHub says, else what
// its parent says; choosing a category writes that label or option back
// (after confirming), and the rules only suggest.

struct InvestmentCondition: Codable, Hashable, Identifiable {
    enum Field: String, Codable, CaseIterable, Identifiable {
        case label, title, branch, repository, author, issueType, milestone, projectField

        var id: Self { self }

        /// Fields rules offer. Branch and author are PR-only and stay only so
        /// older saved rules still decode; they never match.
        static let issueFields: [Field] = [.label, .title, .repository, .issueType, .milestone, .projectField]

        var name: String {
            switch self {
            case .label: "Label"
            case .title: "Title"
            case .branch: "Branch"
            case .repository: "Repository"
            case .author: "Author"
            case .issueType: "Issue type"
            case .milestone: "Milestone"
            case .projectField: "Project field"
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
    /// For `.projectField`: which board field, by name (Bucket, Horizon).
    var projectField: String?
    var op: Operator
    var value: String

    /// Case-insensitive. An empty value never matches, so a half-written
    /// rule doesn't swallow everything.
    func matches(_ item: InvestmentItem) -> Bool {
        let target = value.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return false }
        let candidates = field == .projectField
            ? projectField.flatMap { name in item.projectFields.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value }.map { [$0] } ?? []
            : item.values(for: field)
        return candidates.contains { candidate in
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
    /// Its label, or its option on the tracked board field, when the org
    /// tracks investments in GitHub.
    var githubValue: String?

    func matches(_ item: InvestmentItem) -> Bool {
        rules.contains { $0.matches(item) }
    }
}

/// Where an org keeps an issue's investment category.
enum InvestmentTracking: Codable, Hashable {
    /// Rules and choices made in Gannin; nothing is written to GitHub.
    case gannin
    /// A label per category.
    case labels
    /// A single-select field on one board, an option per category.
    case projectField(projectNumber: Int, projectTitle: String, field: String)

    var writesToGitHub: Bool { self != .gannin }

    var summary: String {
        switch self {
        case .gannin: "In Gannin"
        case .labels: "GitHub labels"
        case .projectField(_, let project, let field): "\(field) on \(project)"
        }
    }

    /// What a category's GitHub value is called here.
    var valueName: String {
        switch self {
        case .gannin: ""
        case .labels: "Label"
        case .projectField(_, _, let field): "\(field) option"
        }
    }
}

struct InvestmentConfig: Codable, Hashable {
    var categories: [InvestmentCategory]
    /// Issue node ID to category ID, chosen by hand. Wins over the rules.
    /// Only when tracked in Gannin.
    var manual: [String: UUID] = [:]
    /// Nil (older configs) is in Gannin.
    var tracking: InvestmentTracking?

    var trackedBy: InvestmentTracking { tracking ?? .gannin }

    static var `default`: InvestmentConfig { InvestmentConfig(categories: InvestmentPreset.balance.categories) }

    func category(id: UUID) -> InvestmentCategory? {
        categories.first { $0.id == id }
    }

    /// The first colour slot no category uses, if any.
    var freeSlot: Int? {
        let used = Set(categories.map(\.slot))
        return (0..<InvestmentCategory.slotCount).first { !used.contains($0) }
    }

    /// Why an issue landed where it did, for tooltips.
    enum Source: String {
        case manual = "Chosen by hand"
        case issue = "Matched on the issue"
        case parent = "Matched on its parent"
        case github = "From GitHub"
        case githubParent = "From its parent on GitHub"
    }

    /// An issue's category, as the org tracks it.
    func categorise(_ issue: IssueRecord, parent: IssueRecord?) -> (category: InvestmentCategory, source: Source)? {
        switch trackedBy {
        case .gannin:
            if let id = manual[issue.id], let category = category(id: id) {
                return (category, .manual)
            }
            if let category = suggest(issue) {
                return (category, .issue)
            }
            if let parent, let category = suggest(parent) {
                return (category, .parent)
            }
            return nil
        case .labels, .projectField:
            if let category = tracked(issue) { return (category, .github) }
            if let parent, let category = tracked(parent) { return (category, .githubParent) }
            return nil
        }
    }

    /// The top-most category whose rules match: the category when tracked
    /// in Gannin, a suggestion when tracked in GitHub.
    func suggest(_ issue: IssueRecord) -> InvestmentCategory? {
        let item = InvestmentItem(issue)
        return categories.first { $0.matches(item) }
    }

    /// The category GitHub says: the first whose label the issue has, or
    /// whose option it has on the tracked field.
    func tracked(_ issue: IssueRecord) -> InvestmentCategory? {
        let value: (InvestmentCategory) -> Bool
        switch trackedBy {
        case .gannin:
            return nil
        case .labels:
            value = { category in
                guard let label = category.githubValue, !label.isEmpty else { return false }
                return issue.labels.contains { $0.caseInsensitiveCompare(label) == .orderedSame }
            }
        case .projectField(let number, _, let field):
            let current = issue.fields(onProject: number)?.values.first { $0.key.caseInsensitiveCompare(field) == .orderedSame }?.value.display
            value = { category in
                guard let option = category.githubValue, let current else { return false }
                return option.caseInsensitiveCompare(current) == .orderedSame
            }
        }
        return categories.first(where: value)
    }

    /// The categories' GitHub values, for removing the others when one is set.
    var githubValues: [String] { categories.compactMap(\.githubValue).filter { !$0.isEmpty } }
}

/// The fields of an issue that conditions test.
struct InvestmentItem {
    var labels: [String] = []
    var title: String
    var repository: String
    var issueType: String?
    var milestone: String?
    var projectFields: [String: String] = [:]

    init(_ issue: IssueRecord) {
        labels = issue.labels
        title = issue.title
        repository = issue.repo
        issueType = issue.issueType
        milestone = issue.milestone
        for board in issue.projectFields {
            for (name, value) in board.values { projectFields[name] = value.display }
        }
    }

    func values(for field: InvestmentCondition.Field) -> [String] {
        switch field {
        case .label: labels
        case .title: [title]
        case .branch, .author: []
        case .repository: [repository, repository.split(separator: "/").last.map(String.init) ?? repository]
        case .issueType: issueType.map { [$0] } ?? []
        case .milestone: milestone.map { [$0] } ?? []
        case .projectField: []
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

    var id: Self { self }

    var summary: String {
        switch self {
        case .balance: "New things, improving things, keeping the lights on and productivity, from common issue labels and issue types."
        }
    }

    var categories: [InvestmentCategory] {
        switch self {
        case .balance:
            [
                category("New things", "New products, features and integrations.", slot: 0, [
                    [.init(field: .label, op: .matches, value: "^(feature|new feature|enhancement request)$")],
                    [.init(field: .issueType, op: .isEqual, value: "Feature")],
                ]),
                category("Improving things", "Making existing features better: performance, reliability, security, refactoring.", slot: 1, [
                    [.init(field: .label, op: .matches, value: "^(enhancement|improvement|refactor|performance|security|tech debt)$")],
                ]),
                category("Keeping the lights on", "Bugs, incidents, dependency updates and other upkeep.", slot: 2, [
                    [.init(field: .label, op: .matches, value: "^(bug|incident|hotfix|dependencies|security fix)$")],
                    [.init(field: .issueType, op: .isEqual, value: "Bug")],
                ]),
                category("Productivity", "Developer tooling, CI, tests, docs and build.", slot: 3, [
                    [.init(field: .label, op: .matches, value: "^(ci|build|tooling|devex|documentation|tests?)$")],
                ]),
            ]
        }
    }

    private func category(_ name: String, _ details: String, slot: Int, _ rules: [[InvestmentCondition]]) -> InvestmentCategory {
        InvestmentCategory(name: name, details: details, slot: slot, rules: rules.map { InvestmentRule(conditions: $0) })
    }
}
