import SwiftUI

// MARK: - Table

/// Rows grouped into sections, a column per visible field.
struct BoardTableView: View {
    let board: Board
    let items: [BoardItem]
    let groupBy: String?
    let visibleFields: [String]
    let open: (BoardItem) -> Void
    @Environment(\.currentOrg) private var org

    @State private var sort: StatsSort?
    @State private var collapsed: Set<String> = []

    var body: some View {
        let groups = BoardLayout.groups(items, by: groupBy, board: board)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(groups) { group in
                    if groupBy != nil {
                        Button {
                            if collapsed.contains(group.id) { collapsed.remove(group.id) } else { collapsed.insert(group.id) }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .rotationEffect(.degrees(collapsed.contains(group.id) ? 0 : 90))
                                    .foregroundStyle(.secondary)
                                FieldValueLabel(board: board, field: groupBy ?? "", value: group.value, fallback: group.name)
                                    .font(.headline)
                                Text("\(group.items.count)").foregroundStyle(.secondary).monospacedDigit()
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 14)
                            .padding(.bottom, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if !collapsed.contains(group.id) {
                        StatsTable(rows: group.items, columns: columns, sort: $sort, selectedID: nil, onSelect: open, destination: { item in org.flatMap(item.page) })
                            .padding(.horizontal, 8)
                    }
                }
            }
            .padding(.bottom, 20)
        }
    }

    private var columns: [StatsColumn<BoardItem>] {
        var columns = [
            StatsColumn<BoardItem>(
                id: "title", title: "Title", help: "Click a row to open it", width: nil, minWidth: 280,
                sortKey: { .text($0.title.lowercased()) },
                cell: { item in AnyView(ItemTitleCell(item: item)) }
            ),
        ]
        for field in visibleFields where field.caseInsensitiveCompare("Title") != .orderedSame {
            columns.append(column(for: field))
        }
        return columns
    }

    private func column(for field: String) -> StatsColumn<BoardItem> {
        let width: CGFloat = switch field.lowercased() {
        case "assignees": 90
        case "labels": 220
        case "parent issue": 200
        default: 140
        }
        return StatsColumn(
            id: field, title: field, help: field, width: width,
            sortKey: { item in
                switch item.value(field) {
                case .number(let n): .number(n)
                case .option(_, let p): .number(Double(p))
                case .iteration(_, let start): .number(start.timeIntervalSince1970)
                case .date(let d): .number(d.timeIntervalSince1970)
                case .text(let t): .text(t.lowercased())
                case .options(let names): .text(names.joined(separator: ", ").lowercased())
                case nil: .text("\u{10FFFF}")
                }
            },
            cell: { item in AnyView(FieldCell(board: board, item: item, field: field)) }
        )
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

/// One field's value in a table cell or on a card.
struct FieldCell: View {
    let board: Board
    let item: BoardItem
    let field: String

    var body: some View {
        switch field.lowercased() {
        case "assignees":
            AvatarStack(people: item.assignees, size: 20)
        case "labels":
            HStack(spacing: 4) {
                ForEach(item.labels.prefix(3), id: \.self) { LabelChip(label: $0) }
            }
            .lineLimit(1)
        case "sub-issues progress":
            if let progress = item.subIssuesProgress {
                HStack(spacing: 6) {
                    ProgressView(value: progress, total: 100).frame(width: 50)
                    Text("\(Int(progress))%").monospacedDigit().foregroundStyle(.secondary)
                }
            }
        default:
            FieldValueLabel(board: board, field: field, value: item.value(field), fallback: nil)
                .lineLimit(1)
        }
    }
}

/// A value with its single-select colour dot, as GitHub shows it.
struct FieldValueLabel: View {
    let board: Board
    let field: String
    let value: IssueFieldValue?
    let fallback: String?

    var body: some View {
        if let value {
            HStack(spacing: 5) {
                if case .option(let name, _) = value {
                    Circle()
                        .fill(BoardLayout.color(board.field(named: field)?.options.first { $0.name == name }?.color))
                        .frame(width: 8, height: 8)
                }
                Text(value.display)
            }
        } else if let fallback {
            Text(fallback).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Board

/// Columns by a single-select or iteration field in board order, optionally
/// split into swimlanes; cards show the view's fields.
struct BoardColumnsView: View {
    let board: Board
    let items: [BoardItem]
    let columnBy: String
    let swimlaneBy: String?
    let visibleFields: [String]
    let open: (BoardItem) -> Void
    @Environment(\.currentOrg) private var org

    private static let columnWidth: CGFloat = 290

    var body: some View {
        let lanes = BoardLayout.groups(items, by: swimlaneBy, board: board)
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(lanes) { lane in
                    VStack(alignment: .leading, spacing: 8) {
                        if swimlaneBy != nil {
                            HStack(spacing: 6) {
                                FieldValueLabel(board: board, field: swimlaneBy ?? "", value: lane.value, fallback: lane.name)
                                    .font(.headline)
                                Text("\(lane.items.count)").foregroundStyle(.secondary)
                            }
                        }
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(BoardLayout.groups(lane.items, by: columnBy, board: board, includeEmptyOptions: true)) { column in
                                columnView(column)
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    private func columnView(_ column: BoardLayout.Group) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                FieldValueLabel(board: board, field: columnBy, value: column.value, fallback: column.name)
                    .font(.callout.weight(.semibold))
                Text("\(column.items.count)").foregroundStyle(.secondary).monospacedDigit()
                Spacer()
            }
            .padding(.horizontal, 4)
            LazyVStack(spacing: 8) {
                ForEach(column.items) { item in
                    card(item)
                }
            }
        }
        .padding(8)
        .frame(width: Self.columnWidth, alignment: .top)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private func card(_ item: BoardItem) -> some View {
        let fields = visibleFields.filter {
            !["title", "assignees", columnBy.lowercased()].contains($0.lowercased())
                && item.value($0) != nil
        }
        return Button { open(item) } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if let repo = item.repo, let number = item.number {
                        Text("\(repo.split(separator: "/").last.map(String.init) ?? repo)#\(number)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    AvatarStack(people: item.assignees, size: 18)
                }
                Text(item.title)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                if !fields.isEmpty {
                    FlowRow(spacing: 4) {
                        ForEach(fields, id: \.self) { field in
                            FieldCell(board: board, item: item, field: field)
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary.opacity(0.6), in: Capsule())
                        }
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let page = org.flatMap(item.page) { OpenElsewhereItems(page) }
        }
    }
}

/// Lays children out left to right, wrapping onto new lines.
struct FlowRow: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                y += lineHeight + spacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: min(widest, width), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += lineHeight + spacing
                x = bounds.minX
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

// MARK: - Insights

/// Time in each status on this board, from the status history the Issues
/// page fetches, and how many of the view's items sit in each status now.
struct BoardInsightsView: View {
    @Environment(IssueStore.self) private var issueStore
    @SceneStorage(MetricsStore.windowKey) private var windowDays = MetricsStore.defaultWindowDays
    let org: String
    let board: Board
    let items: [BoardItem]

    private struct Row: Identifiable {
        let status: String
        let color: String?
        let now: Int
        let time: DurationStat
        var id: String { status }
    }

    var body: some View {
        let rows = rows()
        let scale = BarScale(rows.compactMap(\.time.median))
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Time in each status over \(MetricsWindow(code: windowDays).span), from the issues' board history, and how many of this view's items sit in each status now. Spells still running aren't counted in the time.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if issueStore.history(for: org) == nil {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading issue history").foregroundStyle(.secondary)
                    }
                }
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                    GridRow {
                        Text("Status").foregroundStyle(.secondary)
                        Text("Now").foregroundStyle(.secondary)
                        Text("Median time").foregroundStyle(.secondary)
                        Text("p75").foregroundStyle(.secondary)
                        Text("Spells").foregroundStyle(.secondary)
                    }
                    .font(.callout.weight(.medium))
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(rows) { row in
                        GridRow {
                            HStack(spacing: 6) {
                                Circle().fill(BoardLayout.color(row.color)).frame(width: 8, height: 8)
                                Text(row.status)
                            }
                            Text("\(row.now)").monospacedDigit()
                            BarCell(value: row.time.median, scale: scale).frame(width: 220)
                            Text(row.time.p75?.compactDuration ?? "-").monospacedDigit().foregroundStyle(.secondary)
                            Text("\(row.time.count)").monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await issueStore.sync(org, windowDays: MetricsWindow(code: windowDays).syncDays()) }
    }

    private func rows() -> [Row] {
        let status = board.field(named: "Status")
        let windowStart = MetricsWindow(code: windowDays).interval().start
        var spells: [String: [TimeInterval]] = [:]
        for record in issueStore.history(for: org)?.issues.values.map({ $0 }) ?? [] {
            let changes = record.statusChanges.filter { $0.projectNumber == board.number }
            for (index, change) in changes.enumerated() {
                let end = index + 1 < changes.count ? changes[index + 1].at : record.closedAt
                guard let end, end >= windowStart else { continue }
                spells[change.status, default: []].append(end.timeIntervalSince(change.at))
            }
        }
        let now = Dictionary(grouping: items.compactMap { $0.value("Status")?.display }, by: { $0 }).mapValues(\.count)
        let names = (status?.options.map(\.name) ?? []) + Set(spells.keys).union(now.keys).subtracting(status?.options.map(\.name) ?? []).sorted()
        return names.map { name in
            Row(status: name, color: status?.options.first { $0.name == name }?.color, now: now[name] ?? 0, time: DurationStat(spells[name] ?? []))
        }
    }
}
