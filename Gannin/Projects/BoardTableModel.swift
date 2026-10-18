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
