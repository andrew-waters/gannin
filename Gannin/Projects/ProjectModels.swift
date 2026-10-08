import Foundation

/// A GitHub project board: its fields and saved views.
struct Board: Codable, Hashable {
    let id: String
    let number: Int
    let title: String
    let url: URL
    let fields: [BoardField]
    let views: [BoardView]

    func field(named name: String) -> BoardField? {
        fields.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}

struct BoardField: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    /// GitHub's data type: TITLE, ASSIGNEES, SINGLE_SELECT, ITERATION and so on.
    let dataType: String
    /// Single- or multi-select options or iterations, in board order.
    let options: [BoardOption]
    /// An iteration field's length in days.
    var iterationDuration: Int?

    var isGroupable: Bool {
        ["SINGLE_SELECT", "ITERATION", "ASSIGNEES", "LABELS", "MILESTONE", "REPOSITORY", "TEXT", "NUMBER", "DATE"].contains(dataType)
    }
}

struct BoardOption: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    /// Single-select colour name (GRAY, BLUE, GREEN, and so on).
    let color: String?
    /// Iteration start.
    let start: Date?
    /// What the option means, as set on the board.
    var description: String?
    /// An iteration's length in days.
    var duration: Int?
}

/// A saved view: its layout, filter, grouping, sort and visible fields.
struct BoardView: Codable, Hashable, Identifiable {
    enum Layout: String, Codable, CaseIterable, Identifiable {
        case table = "Table"
        case board = "Board"
        case roadmap = "Roadmap"

        var id: Self { self }

        var systemImage: String {
            switch self {
            case .table: "tablecells"
            case .board: "rectangle.split.3x1"
            case .roadmap: "calendar.day.timeline.left"
            }
        }
    }

    struct Sort: Codable, Hashable {
        let field: String
        let descending: Bool
    }

    let id: String
    let number: Int
    let name: String
    let layout: Layout
    let filter: String
    /// Table sections, or board swimlanes.
    let groupBy: [String]
    /// Board columns.
    let columnBy: [String]
    let sortBy: [Sort]
    let visibleFields: [String]
}

/// An item on a board: an issue, a pull request or a draft.
struct BoardItem: Codable, Hashable, Identifiable {
    enum Kind: String, Codable {
        case issue = "ISSUE"
        case pullRequest = "PULL_REQUEST"
        case draft = "DRAFT_ISSUE"
        case redacted = "REDACTED"
    }

    let id: String
    let kind: Kind
    /// The issue or PR node ID.
    let contentID: String?
    let title: String
    let number: Int?
    let url: URL?
    let repo: String?
    /// OPEN, CLOSED or MERGED.
    let state: String?
    let assignees: [Person]
    let labels: [IssueLabel]
    let milestone: String?
    let parent: String?
    let subIssuesProgress: Double?
    let linkedPullRequests: Int
    let updatedAt: Date?
    /// Custom field values by field name.
    var values: [String: IssueFieldValue]

    /// A field's value for grouping, sorting and display, built-ins included.
    func value(_ field: String) -> IssueFieldValue? {
        switch field.lowercased() {
        case "title": return .text(title)
        case "assignees": return assignees.isEmpty ? nil : .text(assignees.map(\.login).joined(separator: ", "))
        case "labels": return labels.isEmpty ? nil : .text(labels.map(\.name).joined(separator: ", "))
        case "repository": return repo.map { .text($0) }
        case "milestone": return milestone.map { .text($0) }
        case "parent issue": return parent.map { .text($0) }
        case "sub-issues progress": return subIssuesProgress.map { .number($0) }
        case "linked pull requests": return linkedPullRequests > 0 ? .number(Double(linkedPullRequests)) : nil
        default: return values.first { $0.key.caseInsensitiveCompare(field) == .orderedSame }?.value
        }
    }
}

/// A view's items as last fetched: which items matched, in order, resolved
/// through `BoardCache.itemsByID`.
struct BoardItems: Codable {
    var fetchedAt: Date
    var ids: [String]
}

/// Everything saved for one board. Items are kept once, by ID, in
/// `itemsByID` and shared between filters' results, since views' filters
/// often overlap and would otherwise each store their own copy of the same
/// issue.
struct BoardCache: Codable {
    var board: Board
    var fetchedAt: Date
    var items: [String: BoardItems] = [:]
    var itemsByID: [String: BoardItem] = [:]

    /// The items matching `filter`, in the order last fetched.
    func resolvedItems(for filter: String) -> [BoardItem]? {
        items[filter]?.ids.compactMap { itemsByID[$0] }
    }

    /// Records what `filter` matched. Other filters listing an item that came
    /// back changed are marked stale, since it may no longer match them.
    mutating func merge(_ fetched: [BoardItem], for filter: String, at date: Date) {
        let changed = Set(fetched.compactMap { item in
            itemsByID[item.id].flatMap { $0 == item ? nil : item.id }
        })
        for item in fetched { itemsByID[item.id] = item }
        if !changed.isEmpty {
            for (other, result) in items where other != filter && result.ids.contains(where: changed.contains) {
                items[other]?.fetchedAt = .distantPast
            }
        }
        items[filter] = BoardItems(fetchedAt: date, ids: fetched.map(\.id))
        pruneOrphanedItems()
    }

    /// Drops items no filter currently references, so a view's result
    /// shrinking doesn't leave the items it dropped cached forever.
    private mutating func pruneOrphanedItems() {
        let referenced = Set(items.values.flatMap(\.ids))
        itemsByID = itemsByID.filter { referenced.contains($0.key) }
    }
}

extension BoardCache {
    private struct LegacyItems: Decodable {
        var fetchedAt: Date
        var items: [BoardItem]
    }

    /// Tolerates caches saved when each filter kept its own copy of its items.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        board = try container.decode(Board.self, forKey: .board)
        fetchedAt = try container.decode(Date.self, forKey: .fetchedAt)
        if let itemsByID = try container.decodeIfPresent([String: BoardItem].self, forKey: .itemsByID) {
            self.itemsByID = itemsByID
            items = try container.decodeIfPresent([String: BoardItems].self, forKey: .items) ?? [:]
        } else {
            let legacy = try container.decodeIfPresent([String: LegacyItems].self, forKey: .items) ?? [:]
            items = legacy.mapValues { BoardItems(fetchedAt: $0.fetchedAt, ids: $0.items.map(\.id)) }
            // Newest copy first, so the most recently fetched wins.
            for result in legacy.values.sorted(by: { $0.fetchedAt > $1.fetchedAt }) {
                for item in result.items where itemsByID[item.id] == nil { itemsByID[item.id] = item }
            }
        }
    }
}
