import SwiftUI

/// Sort key for a stats column. Text sorts case-insensitively.
enum StatsSortKey: Comparable {
    case number(Double)
    case text(String)
}

struct StatsColumn<Row> {
    let id: String
    let title: String
    /// Shown when hovering the column header.
    let help: String
    /// Fixed width, or nil for the one flexible column.
    var width: CGFloat?
    var minWidth: CGFloat = 0
    var alignment: Alignment = .leading
    /// Consecutive columns with the same group share a header above them.
    var group: String?
    let sortKey: (Row) -> StatsSortKey
    let cell: (Row) -> AnyView
}

struct StatsSort: Equatable {
    var columnID: String
    var ascending: Bool
}

/// A table laid out by hand rather than with `Table`, so it can have a
/// grouped header row, header tooltips and rows sized to their content.
/// Click a header to sort; click again to reverse.
struct StatsTable<Row: Identifiable>: View {
    let rows: [Row]
    let columns: [StatsColumn<Row>]
    /// Nil keeps `rows` in the order given.
    @Binding var sort: StatsSort?
    let selectedID: Row.ID?
    let onSelect: (Row) -> Void
    var contextMenu: ((Row) -> AnyView)?
    /// The page a row opens, for Open in New Tab and Window in its menu.
    var destination: ((Row) -> DetailSelection?)?

    private let rowHeight: CGFloat = 36
    private let cellPadding: CGFloat = 10
    /// Room at the right of every header for the sort chevron, so it never
    /// crowds the title.
    private let sortSlot: CGFloat = 12

    var body: some View {
        ScrollView(.horizontal) {
            VStack(spacing: 0) {
                if columns.contains(where: { $0.group != nil }) {
                    groupHeader
                }
                columnHeader
                Divider()
                ForEach(Array(sortedRows.enumerated()), id: \.element.id) { index, row in
                    rowView(row, striped: index.isMultiple(of: 2) == false)
                }
            }
            .containerRelativeFrame(.horizontal) { visible, _ in max(visible, minimumWidth) }
        }
        .scrollIndicators(.automatic)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }

    // MARK: Layout

    private var minimumWidth: CGFloat {
        columns.reduce(0) { $0 + (columnWidth(of: $1) ?? $1.minWidth) }
            + CGFloat(columns.indices.filter(startsGroup).count) * groupGap
    }

    /// Space between column groups, with a line down its middle.
    private let groupGap: CGFloat = 20

    /// A fixed column's width plus its chevron slot.
    private func columnWidth(of column: StatsColumn<Row>) -> CGFloat? {
        column.width.map { $0 + sortSlot }
    }

    /// Frames a cell (or a span of cells) to its column width.
    @ViewBuilder
    private func sized<Content: View>(_ column: StatsColumn<Row>, width: CGFloat? = nil, @ViewBuilder _ content: () -> Content) -> some View {
        if let fixed = width ?? columnWidth(of: column) {
            content().frame(width: fixed, alignment: column.alignment)
        } else {
            content().frame(minWidth: column.minWidth, maxWidth: .infinity, alignment: column.alignment)
        }
    }

    private func startsGroup(_ index: Int) -> Bool {
        index > 0 && columns[index].group != nil && columns[index].group != columns[index - 1].group
    }

    private var groupSpans: [(title: String?, columns: [StatsColumn<Row>], startIndex: Int)] {
        var spans: [(title: String?, columns: [StatsColumn<Row>], startIndex: Int)] = []
        for (index, column) in columns.enumerated() {
            if let last = spans.last, last.title == column.group {
                spans[spans.count - 1].columns.append(column)
            } else {
                spans.append((column.group, [column], index))
            }
        }
        return spans
    }

    // MARK: Headers

    private var groupHeader: some View {
        HStack(spacing: 0) {
            ForEach(groupSpans, id: \.startIndex) { span in
                let fixedWidth = span.columns.allSatisfy { $0.width != nil }
                    ? span.columns.reduce(0) { $0 + (columnWidth(of: $1) ?? 0) }
                    : nil
                if startsGroup(span.startIndex) { gutter }
                Group {
                    if let title = span.title {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                            Capsule()
                                .fill(.quaternary)
                                .frame(height: 2)
                        }
                        .padding(.horizontal, cellPadding)
                    } else {
                        Color.clear
                    }
                }
                .frame(
                    minWidth: fixedWidth ?? span.columns.reduce(0) { $0 + (columnWidth(of: $1) ?? $1.minWidth) },
                    maxWidth: fixedWidth ?? .infinity
                )
                .frame(width: fixedWidth)
            }
        }
        .frame(height: 30)
    }

    private var columnHeader: some View {
        HStack(spacing: 0) {
            ForEach(Array(columns.enumerated()), id: \.element.id) { index, column in
                if startsGroup(index) { gutter }
                sized(column) {
                    Button {
                        toggleSort(column)
                    } label: {
                        // One line; the sort chevron sits at the far right of
                        // the cell, in its slot, so sorting never shifts or
                        // wraps the title.
                        // Titles always read from the left, whatever the
                        // column's alignment.
                        Text(column.title)
                            .lineLimit(1)
                            .fixedSize()
                            .font(.callout.weight(.medium))
                            .foregroundStyle(sort?.columnID == column.id ? .primary : .secondary)
                            .padding(.leading, cellPadding)
                            .padding(.trailing, cellPadding + sortSlot)
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
                }

            }
        }
        .frame(height: 30)
    }

    private func toggleSort(_ column: StatsColumn<Row>) {
        if sort?.columnID == column.id {
            sort?.ascending.toggle()
        } else {
            // Names read best A to Z; numbers are most useful biggest first.
            sort = StatsSort(columnID: column.id, ascending: column.width == nil)
        }
    }

    // MARK: Rows

    private var sortedRows: [Row] {
        guard let sort, let column = columns.first(where: { $0.id == sort.columnID }) else { return rows }
        return rows.enumerated()
            .sorted { a, b in
                let keyA = column.sortKey(a.element)
                let keyB = column.sortKey(b.element)
                if keyA == keyB { return a.offset < b.offset }
                return sort.ascending ? keyA < keyB : keyA > keyB
            }
            .map(\.element)
    }

    private func rowView(_ row: Row, striped: Bool) -> some View {
        let isSelected = row.id == selectedID
        return Button {
            onSelect(row)
        } label: {
            HStack(spacing: 0) {
                ForEach(Array(columns.enumerated()), id: \.element.id) { index, column in
                    if startsGroup(index) { gutter }
                    sized(column) {
                        column.cell(row)
                            .padding(.horizontal, cellPadding)
                    }
                }
            }
            .frame(height: rowHeight)
            .background(
                isSelected
                    ? AnyShapeStyle(Color.accentColor.opacity(0.22))
                    : striped ? AnyShapeStyle(.quaternary.opacity(0.35)) : AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let page = destination?(row) { OpenElsewhereItems(page) }
            contextMenu?(row)
        }
    }

    /// The gap before a column group, with a line down its middle that
    /// runs unbroken from the group title to the last row.
    private var gutter: some View {
        Rectangle()
            .fill(Color.separatorLine)
            .frame(width: 1)
            .frame(width: groupGap)
            .frame(maxHeight: .infinity)
    }
}
