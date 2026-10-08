import Charts
import SwiftUI

// MARK: - Board

/// Columns by the first grouping, swimlanes by the second. A single-select
/// column field shows every option, empty ones too, so cards can be dragged
/// into any of them; dropping a card sets the column's value (and the lane's,
/// when that's a field too), confirmed first.
struct FieldBoard: View {
    let issues: [IssueRecord]
    let view: FieldView
    let context: FieldContext
    let definition: Board?
    let actions: FieldActions

    @State private var target: String?

    private static let columnWidth: CGFloat = 270

    var body: some View {
        let columnKey = view.dimensions[0]
        let laneKey = view.dimensions.count > 1 ? view.dimensions[1] : nil
        let columns = columnValues(columnKey)
        let lanes: [FieldValue?] = laneKey.map { key in FieldView.values(of: key, in: issues, context: context).map(Optional.some) } ?? [nil]
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(columns, id: \.self) { column in
                        columnHeader(column, key: columnKey)
                    }
                }
                ForEach(lanes, id: \.self) { lane in
                    VStack(alignment: .leading, spacing: 8) {
                        if let lane, let laneKey {
                            HStack(spacing: 6) {
                                Circle().fill(FieldColors.color(lane, key: laneKey, definition: definition)).frame(width: 8, height: 8)
                                Text(lane.title).font(.headline)
                                Text(laneKey.title).font(.caption).foregroundStyle(.tertiary)
                                Text(verbatim: "\(members(lane: lane, key: laneKey).count)").foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(columns, id: \.self) { column in
                                columnBody(column, columnKey: columnKey, lane: lane, laneKey: laneKey)
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    /// Every option of a single-select field in board order, then anything
    /// else the issues have; otherwise just what the issues have.
    private func columnValues(_ key: FieldKey) -> [FieldValue] {
        let present = FieldView.values(of: key, in: issues, context: context)
        guard let name = key.fieldName, let field = definition?.field(named: name), field.dataType == "SINGLE_SELECT" else { return present }
        let options = field.options.enumerated().map { FieldValue(name: $1.name, order: Double($0)) }
        let names = Set(options.compactMap(\.name))
        return options + present.filter { $0.name == nil || !names.contains($0.name ?? "") }
    }

    private func members(lane: FieldValue?, key: FieldKey?) -> [IssueRecord] {
        guard let lane, let key else { return issues }
        return issues.filter { key.values(of: $0, in: context).contains(lane) }
    }

    private func columnHeader(_ column: FieldValue, key: FieldKey) -> some View {
        let inColumn = issues.filter { key.values(of: $0, in: context).contains(column) }
        return HStack(spacing: 6) {
            Circle().fill(FieldColors.color(column, key: key, definition: definition)).frame(width: 9, height: 9)
            Text(column.title).fontWeight(.semibold).lineLimit(1)
            Spacer()
            if view.measure != .count {
                Text(view.measure.format(view.measure.value(inColumn, context: context)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(verbatim: "\(inColumn.count)").monospacedDigit().foregroundStyle(.secondary)
        }
        .frame(width: Self.columnWidth)
    }

    private func columnBody(_ column: FieldValue, columnKey: FieldKey, lane: FieldValue?, laneKey: FieldKey?) -> some View {
        let cards = members(lane: lane, key: laneKey).filter { columnKey.values(of: $0, in: context).contains(column) }
        let id = "\(column.name ?? "")\u{1}\(lane?.name ?? "")"
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(cards) { issue in
                FieldCard(issue: issue, signals: context.signals(issue), shown: FieldChips.values(issue, keys: view.shownFields, context: context), definition: definition)
                    .onTapGesture { actions.open(issue) }
                    .contextMenu { actions.setMenu([issue]) }
                    .draggable(issue.id)
            }
            if cards.isEmpty {
                Text("None").font(.caption).foregroundStyle(.tertiary).frame(maxWidth: .infinity, minHeight: 40)
            }
        }
        .padding(8)
        .frame(width: Self.columnWidth, alignment: .top)
        .background(Color.secondary.opacity(target == id ? 0.22 : 0.08), in: RoundedRectangle(cornerRadius: 10))
        .dropDestination(for: String.self) { ids, _ in
            drop(ids, column: column, columnKey: columnKey, lane: lane, laneKey: laneKey)
            return true
        } isTargeted: { isTargeted in
            if isTargeted { target = id } else if target == id { target = nil }
        }
    }

    /// Sets the column's field (and the lane's) on the dropped issues,
    /// confirmed first. Columns that aren't a board field can't take a drop.
    private func drop(_ ids: [String], column: FieldValue, columnKey: FieldKey, lane: FieldValue?, laneKey: FieldKey?) {
        let moved = issues.filter { ids.contains($0.id) }
        var changes: [FieldChange] = []
        if let field = columnKey.fieldName {
            changes += FieldChange.plan(moved, field: field, value: column.name, board: view.projectNumber)
        }
        if let lane, let field = laneKey?.fieldName {
            changes += FieldChange.plan(moved, field: field, value: lane.name, board: view.projectNumber)
        }
        if !changes.isEmpty { actions.propose(changes) }
    }
}

/// A card on the board: title, where it's from, how long it's been in its
/// status (coloured by how long), time in progress, flags and who has it.
struct FieldCard: View {
    let issue: IssueRecord
    let signals: IssueSignals
    /// The view's shown fields with this issue's values.
    var shown: [(key: FieldKey, values: [FieldValue])] = []
    var definition: Board?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(issue.title)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Text(verbatim: "\(issue.repo.split(separator: "/").last.map(String.init) ?? issue.repo)#\(issue.number)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                FlagBadge(flags: signals.flags)
            }
            if !shown.isEmpty {
                FieldChips(shown: shown, definition: definition)
            }
            HStack(spacing: 6) {
                if let time = signals.timeInStatus {
                    Text(time.compactDuration)
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(FieldColors.color(AgeBucket(seconds: time).value, key: .ageInStatus, definition: nil).opacity(0.25), in: Capsule())
                        .help("In \(signals.status ?? "this status") for \(time.compactDuration)")
                }
                if let inProgress = signals.inProgress {
                    Label(inProgress.compactDuration, systemImage: "clock")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help("\(inProgress.compactDuration) in progress so far")
                }
                Spacer(minLength: 0)
                AvatarStack(people: issue.assignees.map { Person(login: $0, name: nil, avatarUrl: URL(string: "https://github.com/\($0).png?size=64")) })
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.windowBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.separatorLine) }
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Table

/// One row an issue, a column per grouping, then how long it's sat and
/// what doesn't add up.
struct FieldTable: View {
    private struct Column: Identifiable {
        let id: Int
        let key: FieldKey
    }

    let issues: [IssueRecord]
    let view: FieldView
    let context: FieldContext
    @Binding var selected: Set<String>
    let actions: FieldActions
    /// Column order, widths and which are hidden, per view, on this Mac.
    @AppStorage private var storedColumns: Data

    init(issues: [IssueRecord], view: FieldView, context: FieldContext, selected: Binding<Set<String>>, actions: FieldActions) {
        self.issues = issues
        self.view = view
        self.context = context
        _selected = selected
        self.actions = actions
        _storedColumns = AppStorage(wrappedValue: Data(), "fieldViewColumns.\(view.id.uuidString)")
    }

    var body: some View {
        // The groupings, then the shown fields not already among them.
        let keys = view.dimensions + view.shownFields.filter { !view.dimensions.contains($0) }
        let columns = keys.enumerated().map { Column(id: $0, key: $1) }
        Table(issues, selection: $selected, columnCustomization: TableColumnStore.binding($storedColumns)) {
            TableColumn("Issue") { issue in
                VStack(alignment: .leading, spacing: 1) {
                    Text(issue.title).lineLimit(1)
                    Text(verbatim: "\(issue.repo)#\(issue.number)").font(.caption).foregroundStyle(.secondary)
                }
            }
            .width(min: 220, ideal: 360)
            .customizationID("issue")
            TableColumnForEach(columns) { column in
                TableColumn(column.key.title) { issue in
                    Text(column.key.values(of: issue, in: context).map(\.title).joined(separator: ", "))
                        .foregroundStyle(column.key.values(of: issue, in: context) == [.none] ? .secondary : .primary)
                        .lineLimit(1)
                }
                .width(min: 80, ideal: 120)
                .customizationID("field.\(column.key.title)")
            }
            TableColumn("In status") { issue in
                Text(context.signals(issue).timeInStatus?.compactDuration ?? "").monospacedDigit()
            }
            .width(min: 60, ideal: 80)
            .customizationID("inStatus")
            TableColumn("In progress") { issue in
                Text(context.signals(issue).inProgress?.compactDuration ?? "").monospacedDigit()
            }
            .width(min: 60, ideal: 80)
            .customizationID("inProgress")
            TableColumn("Attention") { issue in
                let flags = context.signals(issue).flags
                HStack(spacing: 4) {
                    FlagBadge(flags: flags)
                    Text(flags.map(\.rawValue).joined(separator: ", ")).lineLimit(1).foregroundStyle(.secondary)
                }
            }
            .width(min: 80, ideal: 160)
            .customizationID("attention")
            TableColumn("Assignees") { issue in
                AvatarStack(people: issue.assignees.map { Person(login: $0, name: nil, avatarUrl: URL(string: "https://github.com/\($0).png?size=64")) })
            }
            .width(min: 60, ideal: 90)
            .customizationID("assignees")
        }
        .contextMenu(forSelectionType: String.self) { ids in
            actions.setMenu(issues.filter { ids.contains($0.id) })
        } primaryAction: { ids in
            if let issue = issues.first(where: { ids.contains($0.id) }) { actions.open(issue) }
        }
    }
}

// MARK: - Grid

/// The first two groupings as a grid: rows by the first, columns by the
/// second, shaded by count, with the measure beneath when it isn't the
/// count, and totals. Clicking a cell picks it.
struct FieldGrid: View {
    let issues: [IssueRecord]
    let view: FieldView
    let context: FieldContext
    @Binding var cell: [FieldValue]?

    var body: some View {
        let rowKey = view.dimensions[0]
        let columnKey = view.dimensions[1]
        let rows = FieldView.values(of: rowKey, in: issues, context: context)
        let columns = FieldView.values(of: columnKey, in: issues, context: context)
        var members: [[FieldValue]: [IssueRecord]] = [:]
        for issue in issues {
            for row in Set(rowKey.values(of: issue, in: context)) {
                for column in Set(columnKey.values(of: issue, in: context)) {
                    members[[row, column], default: []].append(issue)
                }
            }
        }
        let busiest = max(members.values.map(\.count).max() ?? 1, 1)
        return ScrollView([.horizontal, .vertical]) {
            Grid(alignment: .center, horizontalSpacing: 2, verticalSpacing: 2) {
                GridRow {
                    Text("\(rowKey.title) by \(columnKey.title)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.leading)
                    ForEach(columns, id: \.self) { column in
                        Text(column.title)
                            .font(.caption)
                            .foregroundStyle(column == .none ? .secondary : .primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .frame(width: 84)
                    }
                    Text("Total").font(.caption.weight(.semibold)).frame(width: 60)
                }
                ForEach(rows, id: \.self) { row in
                    GridRow {
                        Text(row.title)
                            .foregroundStyle(row == .none ? .secondary : .primary)
                            .lineLimit(1)
                            .frame(maxWidth: 220, alignment: .leading)
                        ForEach(columns, id: \.self) { column in
                            cellView(row: row, column: column, issues: members[[row, column]] ?? [], busiest: busiest)
                        }
                        Text(verbatim: "\(issues.filter { rowKey.values(of: $0, in: context).contains(row) }.count)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 60)
                    }
                }
                GridRow {
                    Text("Total").font(.caption.weight(.semibold))
                    ForEach(columns, id: \.self) { column in
                        Text(verbatim: "\(issues.filter { columnKey.values(of: $0, in: context).contains(column) }.count)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 84)
                    }
                    Text(verbatim: "\(issues.count)").monospacedDigit().fontWeight(.semibold).frame(width: 60)
                }
            }
            .padding(16)
        }
    }

    private func cellView(row: FieldValue, column: FieldValue, issues: [IssueRecord], busiest: Int) -> some View {
        let isPicked = cell == [row, column]
        let count = issues.count
        let measure = view.measure == .count ? nil : view.measure.format(view.measure.value(issues, context: context))
        return Button {
            cell = isPicked ? nil : [row, column]
        } label: {
            VStack(spacing: 0) {
                Text(count == 0 ? "" : "\(count)").monospacedDigit()
                if let measure, count > 0 {
                    Text(measure).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .frame(width: 84, height: measure == nil ? 30 : 40)
            .background(Color.accentColor.opacity(count == 0 ? 0.04 : 0.12 + 0.6 * Double(count) / Double(busiest)), in: RoundedRectangle(cornerRadius: 4))
            .overlay {
                if isPicked { RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary, lineWidth: 1.5) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(count == 0)
        .help("\(row.title), \(column.title): \(count)")
    }
}

// MARK: - Aging

/// Work in progress by age, in the spirit of ActionableAgile: a dot per
/// issue in its column of the first grouping, as high as it's been there,
/// against how long completed issues took in progress (50th and 85th
/// percentiles). Dots past the 85th are the ones to talk about; they're
/// listed beneath, oldest first.
struct FieldAging: View {
    private struct Point: Identifiable {
        let issue: IssueRecord
        let column: Int
        let days: Double
        var id: String { issue.id }
    }

    let issues: [IssueRecord]
    let view: FieldView
    let context: FieldContext
    let history: IssueHistory?
    let workflow: IssueWorkflow
    let actions: FieldActions

    var body: some View {
        let key = view.dimensions[0]
        let columns = FieldView.values(of: key, in: issues, context: context)
        let points = points(key: key, columns: columns)
        let (p50, p85) = thresholds
        let late = points.filter { point in p85.map { point.days > $0 } ?? false }.sorted { $0.days > $1.days }
        VStack(spacing: 0) {
            Chart {
                ForEach(points) { point in
                    PointMark(
                        x: .value(key.title, Double(point.column) + jitter(point.issue.id)),
                        y: .value("Days", point.days)
                    )
                    .foregroundStyle(color(point.days, p50: p50, p85: p85))
                    .symbolSize(44)
                }
                if let p50 {
                    RuleMark(y: .value("50%", p50))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(.secondary)
                        .annotation(position: .top, alignment: .leading) {
                            Text("Half of completed issues took \(Self.days(p50)) in progress").font(.caption2).foregroundStyle(.secondary)
                        }
                }
                if let p85 {
                    RuleMark(y: .value("85%", p85))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(ChartPalette.critical)
                        .annotation(position: .top, alignment: .leading) {
                            Text("85% took up to \(Self.days(p85))").font(.caption2).foregroundStyle(ChartPalette.critical)
                        }
                }
            }
            .chartXScale(domain: -0.5...(Double(max(columns.count, 1)) - 0.5))
            .chartXAxis {
                AxisMarks(values: columns.indices.map(Double.init)) { value in
                    AxisValueLabel {
                        if let index = value.as(Double.self).map(Int.init), columns.indices.contains(index) {
                            Text(columns[index].title)
                        }
                    }
                }
            }
            .chartYAxisLabel("Days in \(key == .field("Status") ? "status" : key.title)")
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onTapGesture { location in
                            if let issue = nearest(to: location, in: points, proxy: proxy, geometry: geometry) { actions.open(issue) }
                        }
                }
            }
            .frame(minHeight: 280)
            .padding(16)
            Divider()
            List {
                Section(late.isEmpty ? "Nothing past the 85th percentile" : "Past the 85th percentile, oldest first") {
                    ForEach(late) { point in
                        FieldIssueRow(issue: point.issue, signals: context.signals(point.issue))
                            .contentShape(Rectangle())
                            .onTapGesture { actions.open(point.issue) }
                            .contextMenu { actions.setMenu([point.issue]) }
                    }
                }
            }
            .frame(minHeight: 160)
        }
    }

    /// Each issue in its (first) column, at its time there in days.
    private func points(key: FieldKey, columns: [FieldValue]) -> [Point] {
        issues.compactMap { issue in
            guard let value = key.values(of: issue, in: context).first, let column = columns.firstIndex(of: value) else { return nil }
            let seconds = context.signals(issue).timeInStatus ?? context.now.timeIntervalSince(issue.createdAt)
            return Point(issue: issue, column: column, days: seconds / 86_400)
        }
    }

    /// How long completed issues spent in progress, in days: the 50th and
    /// 85th percentiles, from the issue history.
    private var thresholds: (Double?, Double?) {
        let times = (history.map { Array($0.issues.values) } ?? [])
            .filter(\.isCompleted)
            .compactMap { IssueTiming($0, workflow: workflow, now: context.now).cycleTime }
            .map { $0 / 86_400 }
            .sorted()
        guard times.count >= 5 else { return (nil, nil) }
        func percentile(_ p: Double) -> Double { times[min(times.count - 1, Int(Double(times.count) * p))] }
        return (percentile(0.5), percentile(0.85))
    }

    private func color(_ days: Double, p50: Double?, p85: Double?) -> Color {
        guard let p50, let p85 else { return FieldColors.color(AgeBucket(seconds: days * 86_400).value, key: .ageInStatus, definition: nil) }
        return days <= p50 ? ChartPalette.good : days <= p85 ? ChartPalette.warning : ChartPalette.critical
    }

    /// A steady spread across the column, so dots of the same age don't
    /// sit on top of each other.
    private func jitter(_ id: String) -> Double {
        let sum = id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return Double(sum % 1000) / 1000 * 0.6 - 0.3
    }

    private func nearest(to location: CGPoint, in points: [Point], proxy: ChartProxy, geometry: GeometryProxy) -> IssueRecord? {
        guard let frame = proxy.plotFrame else { return nil }
        let origin = geometry[frame].origin
        var best: (IssueRecord, CGFloat)?
        for point in points {
            guard let position = proxy.position(for: (Double(point.column) + jitter(point.issue.id), point.days)) else { continue }
            let distance = hypot(position.x + origin.x - location.x, position.y + origin.y - location.y)
            if distance < 12, distance < (best?.1 ?? .infinity) { best = (point.issue, distance) }
        }
        return best?.0
    }

    private static func days(_ value: Double) -> String {
        value < 1 ? "under a day" : value < 1.5 ? "1 day" : "\(Int(value.rounded())) days"
    }
}

// MARK: - Writing

/// Confirms board field changes and writes them one at a time.
struct FieldWriteSheet: View {
    @Environment(AuthStore.self) private var auth
    @Environment(IssueStore.self) private var issues
    @Environment(ProjectStore.self) private var projects
    let org: String
    let changes: [FieldChange]
    let board: Board?
    let onClose: () -> Void

    var body: some View {
        let issueCount = Set(changes.map(\.issue.id)).count
        let single = Set(changes.map(\.summary)).count == 1
        BulkWriteSheet(
            title: issueCount == 1 ? "Change 1 issue on \(board?.title ?? "the board")?" : "Change \(issueCount) issues on \(board?.title ?? "the board")?",
            explanation: single
                ? "\(changes[0].summary) on each, on GitHub. Issues not on the board are added to it first."
                : "Each change is made on GitHub. Issues not on the board are added to it first.",
            action: changes.count == 1 ? "Write Change" : "Write \(changes.count) Changes",
            rows: changes.map { .init(id: $0.id, title: $0.issue.title, detail: "\($0.issue.repo)#\(String($0.issue.number)): \($0.summary)") }
        ) { row in
            guard let api = auth.api, let board else { throw InvestmentWriteError.message("Not signed in, or the board hasn't loaded") }
            guard let change = changes.first(where: { $0.id == row.id }) else { return }
            try await FieldWriter.set(
                change.field,
                to: change.value,
                on: change.issue,
                board: board.number,
                title: board.title,
                boardID: projects.boardLists[org]?.first { $0.number == board.number }?.id ?? board.id,
                org: org,
                api: api,
                issues: issues,
                projects: projects
            )
        } onClose: {
            onClose()
        }
    }
}

/// A table's column customisation (order, widths, hidden columns) kept as
/// JSON in `@AppStorage`, so it survives a relaunch.
enum TableColumnStore {
    static func binding<Row>(_ data: Binding<Data>) -> Binding<TableColumnCustomization<Row>> {
        Binding {
            (try? JSONDecoder().decode(TableColumnCustomization<Row>.self, from: data.wrappedValue)) ?? TableColumnCustomization()
        } set: { customization in
            data.wrappedValue = (try? JSONEncoder().encode(customization)) ?? Data()
        }
    }
}
