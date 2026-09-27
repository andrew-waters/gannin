import Foundation

// Investment balance: which kind of work merged PRs are, by category rules
// in the spirit of Swarmia's investment categories.
//
// A category matches when any of its rules does, and a rule needs all of its
// conditions. Everything here is issues: an issue's category, in order, is a
// manual choice; the top-most category matching the issue; then one matching
// its parent; otherwise uncategorised.

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

    func matches(_ item: InvestmentItem) -> Bool {
        rules.contains { $0.matches(item) }
    }
}

struct InvestmentConfig: Codable, Hashable {
    var categories: [InvestmentCategory]
    /// Issue node ID to category ID, chosen by hand. Wins over the rules.
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

    /// Why an issue landed where it did, for tooltips.
    enum Source: String {
        case manual = "Chosen by hand"
        case issue = "Matched on the issue"
        case parent = "Matched on its parent"
    }

    /// An issue's category: chosen by hand, else the top-most category
    /// matching the issue, else one matching its parent, else none.
    func categorise(_ issue: IssueRecord, parent: IssueRecord?) -> (category: InvestmentCategory, source: Source)? {
        if let id = manual[issue.id], let category = category(id: id) {
            return (category, .manual)
        }
        let own = InvestmentItem(issue)
        if let category = categories.first(where: { $0.matches(own) }) {
            return (category, .issue)
        }
        if let parent {
            let inherited = InvestmentItem(parent)
            if let category = categories.first(where: { $0.matches(inherited) }) {
                return (category, .parent)
            }
        }
        return nil
    }
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
