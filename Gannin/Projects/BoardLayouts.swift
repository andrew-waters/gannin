import SwiftUI

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
    /// New Issue in a column, given its value (nil for the empty one).
    var add: ((IssueFieldValue?) -> Void)?
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
                if let add {
                    Button { add(column.value) } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("New issue in \(column.name)")
                }
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
    enum LineAlignment { case top, center }

    var spacing: CGFloat = 4
    var alignment: LineAlignment = .top

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
        // Centring needs each line's height before its first item is placed.
        var lines: [[(index: Int, size: CGSize)]] = [[]]
        var x = bounds.minX
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                lines.append([])
                x = bounds.minX
            }
            lines[lines.count - 1].append((index, size))
            x += size.width + spacing
        }
        var y = bounds.minY
        for line in lines {
            let lineHeight = line.map(\.size.height).max() ?? 0
            x = bounds.minX
            for (index, size) in line {
                let offset = alignment == .center ? (lineHeight - size.height) / 2 : 0
                subviews[index].place(at: CGPoint(x: x, y: y + offset), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += lineHeight + spacing
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
