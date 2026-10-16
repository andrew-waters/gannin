import Foundation

/// One line of the board table: a group's header or one of its items.
enum BoardTableEntry: Identifiable {
    case header(BoardLayout.Group)
    case row(BoardItem, group: String, striped: Bool)

    /// Prefixed, so a group named like an item ID can't collide with it.
    var id: String {
        switch self {
        case .header(let group): "header:\(group.id)"
        case .row(let item, let group, _): "row:\(group):\(item.id)"
        }
    }
}

enum BoardTableModel {
    /// The table as one flat list, so a lazy stack can build only the lines
    /// on screen. Each group is sorted on its own, keeping the order given
    /// for ties, and striped from its own first row. A collapsed group keeps
    /// its header and drops its rows; without `showsHeaders` there are no
    /// headers at all.
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
            for (index, item) in sorted(group.items, by: sortKey, ascending: ascending).enumerated() {
                entries.append(.row(item, group: group.id, striped: !index.isMultiple(of: 2)))
            }
        }
        return entries
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
