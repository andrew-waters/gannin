import Foundation

/// One line of the board table: a group's header or one of its items.
enum BoardTableEntry: Identifiable {
    case header(BoardLayout.Group)
    /// `depth` is 0 for a top-level item and one more for each parent above it.
    case row(BoardItem, group: String, striped: Bool, depth: Int)

    /// Prefixed, so a group named like an item ID can't collide with it.
    var id: String {
        switch self {
        case .header(let group): "header:\(group.id)"
        case .row(let item, let group, _, _): "row:\(group):\(item.id)"
        }
    }
}

/// A column of the board table: the Title column, then one per visible
/// field. Plain values, so a row can compare its columns to skip redrawing.
struct BoardTableColumn: Equatable, Identifiable {
    let id: String
    let title: String
    let help: String
    /// Nil for the one flexible column.
    let width: CGFloat?
    let minWidth: CGFloat

    static let title = BoardTableColumn(id: "title", title: "Title", help: "Click a row to open it", width: nil, minWidth: 280)

    var isTitle: Bool { id == Self.title.id }

    static func columns(visibleFields: [String]) -> [BoardTableColumn] {
        [title] + visibleFields
            .filter { $0.caseInsensitiveCompare(Self.title.title) != .orderedSame }
            .map { BoardTableColumn(field: $0) }
    }

    func sortKey(_ item: BoardItem) -> StatsSortKey {
        if isTitle { return .text(item.title.lowercased()) }
        switch item.value(id) {
        case .number(let n): return .number(n)
        case .option(_, let p): return .number(Double(p))
        case .iteration(_, let start): return .number(start.timeIntervalSince1970)
        case .date(let d): return .number(d.timeIntervalSince1970)
        case .text(let t): return .text(t.lowercased())
        case .options(let names): return .text(names.joined(separator: ", ").lowercased())
        case nil: return .text("\u{10FFFF}")
        }
    }
}

extension BoardTableColumn {
    init(field: String) {
        let width: CGFloat = switch field.lowercased() {
        case "assignees": 90
        case "labels": 220
        case "parent issue": 200
        default: 140
        }
        self.init(id: field, title: field, help: field, width: width, minWidth: 0)
    }
}

enum BoardTableModel {
    /// The table as one flat list, so a lazy stack can build only the lines
    /// on screen. Each group is sorted on its own, keeping the order given
    /// for ties, and striped from its own first row. A collapsed group keeps
    /// its header and drops its rows; without `showsHeaders` there are no
    /// headers at all. A sub-issue whose parent is in the same group sits
    /// directly under it, so each level is sorted on its own; one whose
    /// parent is in another group, or not on the board, stays top-level.
    static func entries(
        groups: [BoardLayout.Group],
        showsHeaders: Bool,
        collapsed: Set<String>,
        sortKey: ((BoardItem) -> StatsSortKey)?,
        ascending: Bool
    ) -> [BoardTableEntry] {
        var entries: [BoardTableEntry] = []
        for group in groups {
            if showsHeaders { entries.append(.header(group)) }
            guard !collapsed.contains(group.id) else { continue }
            var index = 0
            for (item, depth) in nested(group.items, by: sortKey, ascending: ascending) {
                entries.append(.row(item, group: group.id, striped: !index.isMultiple(of: 2), depth: depth))
                index += 1
            }
        }
        return entries
    }

    /// The group's items depth first, each with its depth.
    private static func nested(_ items: [BoardItem], by sortKey: ((BoardItem) -> StatsSortKey)?, ascending: Bool) -> [(BoardItem, Int)] {
        let contentIDs = Set(items.compactMap(\.contentID))
        var childrenOf: [String: [BoardItem]] = [:]
        var roots: [BoardItem] = []
        for item in items {
            if let parent = item.parentID, parent != item.contentID, contentIDs.contains(parent) {
                childrenOf[parent, default: []].append(item)
            } else {
                roots.append(item)
            }
        }
        guard !childrenOf.isEmpty else { return sorted(items, by: sortKey, ascending: ascending).map { ($0, 0) } }
        var result: [(BoardItem, Int)] = []
        func append(_ item: BoardItem, depth: Int) {
            result.append((item, depth))
            guard let id = item.contentID, let children = childrenOf[id] else { return }
            for child in sorted(children, by: sortKey, ascending: ascending) { append(child, depth: depth + 1) }
        }
        for root in sorted(roots, by: sortKey, ascending: ascending) { append(root, depth: 0) }
        // Items that name each other as parents are never reached from a
        // root; list them flat rather than drop them.
        if result.count != items.count {
            let placed = Set(result.map(\.0.id))
            for item in sorted(items.filter { !placed.contains($0.id) }, by: sortKey, ascending: ascending) { result.append((item, 0)) }
        }
        return result
    }

    private static func sorted(_ items: [BoardItem], by sortKey: ((BoardItem) -> StatsSortKey)?, ascending: Bool) -> [BoardItem] {
        guard let sortKey else { return items }
        // Keys are read once per item, not once per comparison.
        return items.enumerated()
            .map { (offset: $0.offset, item: $0.element, key: sortKey($0.element)) }
            .sorted { a, b in
                if a.key == b.key { return a.offset < b.offset }
                return ascending ? a.key < b.key : a.key > b.key
            }
            .map(\.item)
    }
}
