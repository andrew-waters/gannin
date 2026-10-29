import SwiftUI

// MARK: - Table

private enum BoardTableMetrics {
    static let rowHeight: CGFloat = 36
    static let cellPadding: CGFloat = 10
    /// How far a sub-issue's title is indented per level under its parent.
    static let indent: CGFloat = 20
    /// Room at the right of every header for the sort chevron.
    static let sortSlot: CGFloat = 12

    static func width(of column: BoardTableColumn) -> CGFloat? {
        column.width.map { $0 + sortSlot }
    }

    static func minimumWidth(_ columns: [BoardTableColumn]) -> CGFloat {
        columns.reduce(0) { $0 + (width(of: $1) ?? $1.minWidth) } + 16
    }
}

/// Frames a cell to its column's width, or lets the flexible column fill
/// what's left. Clipped, so a cell too wide for its column can't push the
/// ones after it along.
private struct ColumnFrame: ViewModifier {
    let column: BoardTableColumn

    func body(content: Content) -> some View {
        if let fixed = BoardTableMetrics.width(of: column) {
            content.frame(width: fixed, alignment: .leading).clipped()
        } else {
            content.frame(minWidth: column.minWidth, maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Rows grouped into sections, a column per visible field.
///
/// The header, group headers and rows are views of their own that take
/// only comparable values and are marked `.equatable()`, so a change to one
/// row, or to the table's own state, redraws only what it affects.
struct BoardTableView: View {
    let board: Board
    let items: [BoardItem]
    let groupBy: String?
    let visibleFields: [String]
    let open: (BoardItem) -> Void
    @Environment(\.currentOrg) private var org

    @State private var sort: StatsSort?
    @State private var collapsed: Set<String> = []

    // One flat list of group headers and rows in a single lazy stack, rather
    // than a `StatsTable` per group: a table lays out all of its rows at
    // once, which froze the app for seconds on a board of thousands of items.
    var body: some View {
        let columns = BoardTableColumn.columns(visibleFields: visibleFields)
        let sortKey = sort.flatMap { sort in columns.first { $0.id == sort.columnID }?.sortKey }
        let entries = BoardTableModel.entries(
            groups: BoardLayout.groups(items, by: groupBy, board: board),
            showsHeaders: groupBy != nil,
            collapsed: collapsed,
            sortKey: sortKey,
            ascending: sort?.ascending ?? true
        )
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                Section {
                    ForEach(entries) { entry in
                        switch entry {
                        case .header(let group):
                            BoardGroupHeader(
                                board: board, field: groupBy ?? "", group: group,
                                isCollapsed: collapsed.contains(group.id), toggle: toggleGroup
                            )
                            .equatable()
                        case .row(let item, _, let striped, let depth):
                            BoardTableRow(board: board, item: item, columns: columns, striped: striped, depth: depth, org: org, open: open)
                                .equatable()
                        }
                    }
                } header: {
                    BoardColumnHeader(columns: columns, sort: sort, toggleSort: toggleSort).equatable()
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 20)
            .containerRelativeFrame(.horizontal) { visible, _ in max(visible, BoardTableMetrics.minimumWidth(columns)) }
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func toggleGroup(_ id: String) {
        if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
    }

    /// Click a header to sort every group by it; click again to reverse.
    private func toggleSort(_ column: BoardTableColumn) {
        if sort?.columnID == column.id {
            sort?.ascending.toggle()
        } else {
            // Names read best A to Z; numbers are most useful biggest first.
            sort = StatsSort(columnID: column.id, ascending: column.width == nil)
        }
    }
}

// The closures below are left out of `==` on purpose: they only reach back
// into the table's state or the page's `open`, which don't change what is drawn.

private struct BoardGroupHeader: View, Equatable {
    let board: Board
    let field: String
    let group: BoardLayout.Group
    let isCollapsed: Bool
    let toggle: (String) -> Void

    static func == (a: Self, b: Self) -> Bool {
        a.board == b.board && a.field == b.field && a.isCollapsed == b.isCollapsed
            && a.group.id == b.group.id && a.group.value == b.group.value && a.group.items.count == b.group.items.count
    }

    var body: some View {
        Button {
            toggle(group.id)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .foregroundStyle(.secondary)
                FieldValueLabel(board: board, field: field, value: group.value, fallback: group.name)
                    .font(.headline)
                Text("\(group.items.count)").foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.horizontal, 8)
            .padding(.top, 14)
            .padding(.bottom, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct BoardColumnHeader: View, Equatable {
    let columns: [BoardTableColumn]
    let sort: StatsSort?
    let toggleSort: (BoardTableColumn) -> Void

    static func == (a: Self, b: Self) -> Bool {
        a.columns == b.columns && a.sort == b.sort
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(columns) { column in
                    Button {
                        toggleSort(column)
                    } label: {
                        Text(column.title)
                            .lineLimit(1)
                            .fixedSize()
                            .font(.callout.weight(.medium))
                            .foregroundStyle(sort?.columnID == column.id ? .primary : .secondary)
                            .padding(.leading, BoardTableMetrics.cellPadding)
                            .padding(.trailing, BoardTableMetrics.cellPadding + BoardTableMetrics.sortSlot)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .overlay(alignment: .trailing) {
                                if sort?.columnID == column.id {
                                    Image(systemName: sort?.ascending == true ? "chevron.up" : "chevron.down")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(.primary)
                                        .fixedSize()
                                        .padding(.trailing, 6)
                                }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(column.help)
                    .modifier(ColumnFrame(column: column))
                }
            }
            .frame(height: 30)
            Divider()
        }
        .background(.background)
    }
}

private struct BoardTableRow: View, Equatable {
    let board: Board
    let item: BoardItem
    let columns: [BoardTableColumn]
    let striped: Bool
    let depth: Int
    let org: String?
    let open: (BoardItem) -> Void

    static func == (a: Self, b: Self) -> Bool {
        a.striped == b.striped && a.depth == b.depth && a.org == b.org && a.columns == b.columns && a.item == b.item && a.board == b.board
    }

    var body: some View {
        Button {
            open(item)
        } label: {
            HStack(spacing: 0) {
                ForEach(columns) { column in
                    // Color.clear keeps the column's width when a cell
                    // draws nothing, which SwiftUI would otherwise drop,
                    // frame and all, shifting the rest.
                    ZStack(alignment: .leading) {
                        Color.clear
                        BoardTableCell(board: board, item: item, column: column)
                            .padding(.leading, column.isTitle ? CGFloat(depth) * BoardTableMetrics.indent : 0)
                            .padding(.horizontal, BoardTableMetrics.cellPadding)
                    }
                    .modifier(ColumnFrame(column: column))
                }
            }
            .frame(height: BoardTableMetrics.rowHeight)
            .background(striped ? AnyShapeStyle(.quaternary.opacity(0.35)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let page = org.flatMap(item.page) { OpenElsewhereItems(page) }
        }
    }
}

private struct BoardTableCell: View {
    let board: Board
    let item: BoardItem
    let column: BoardTableColumn

    var body: some View {
        if column.isTitle {
            ItemTitleCell(item: item)
        } else {
            FieldCell(board: board, item: item, field: column.id)
        }
    }
}

/// The item's type and state icon, title, and repo#number.
private struct ItemTitleCell: View {
    let item: BoardItem

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon.0).foregroundStyle(icon.1).frame(width: 16)
            Text(item.title).lineLimit(1)
            if let repo = item.repo, let number = item.number {
                Text("\(repo.split(separator: "/").last.map(String.init) ?? repo)#\(number)")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var icon: (String, Color) {
        switch (item.kind, item.state) {
        case (.pullRequest, "MERGED"): ("arrow.triangle.merge", .purple)
        case (.pullRequest, "CLOSED"): ("arrow.triangle.pull", .red)
        case (.pullRequest, _): ("arrow.triangle.pull", .green)
        case (.issue, "CLOSED"): ("checkmark.circle", .purple)
        case (.issue, _): ("smallcircle.filled.circle", .green)
        default: ("doc.text", .secondary)
        }
    }
}
