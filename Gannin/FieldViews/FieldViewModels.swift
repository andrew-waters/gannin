import Foundation

/// A saved way of looking at the org's issues: those on a board (or all of
/// them), filtered, grouped by any number of dimensions in turn, drawn in
/// one of several layouts with a measure beside each group. Gannin's own,
/// not a copy of a GitHub project view. Kept per org in
/// `OrgConfig.fieldViews`, so it syncs like the rest of the settings.
struct FieldView: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    /// The board whose fields can be grouped, filtered and set; nil is
    /// every stored issue, by their own attributes only.
    var projectNumber: Int?
    /// Grouped by the first, then within each by the next, and so on. The
    /// board's columns are the first, its swimlanes the second.
    var dimensions: [FieldKey]
    var filters: [FieldFilter] = []
    var state: FieldViewState = .open
    var layout: FieldViewLayout = .outline
    var measure: FieldMeasure = .count
    /// The issues' order, in every list, column and cell.
    var sort = FieldSort()
    /// The groups' order in the outline; the board's columns and the grid
    /// keep board order.
    var groupOrder: FieldGroupOrder = .value
    /// Shown on each card and row (and as table columns), in this order.
    var shownFields: [FieldKey] = []
}

/// What issues are ordered by. Issues without a value go last either way.
struct FieldSort: Codable, Hashable {
    enum By: Codable, Hashable {
        case created
        case title
        case number
        case timeInStatus
        case inProgress
        /// A board field, attribute or worked-out value, in its own order
        /// (board order for options, start for iterations).
        case key(FieldKey)

        static let basics: [By] = [.created, .title, .number, .timeInStatus, .inProgress]

        var title: String {
            switch self {
            case .created: "Created"
            case .title: "Title"
            case .number: "Number"
            case .timeInStatus: "Time in status"
            case .inProgress: "Time in progress"
            case .key(let key): key.title
            }
        }
    }

    var by: By = .created
    var descending = true

    /// Orders by `by`, with ties newest first so the order is stable.
    func sorted(_ issues: [IssueRecord], context: FieldContext) -> [IssueRecord] {
        func compare(_ a: IssueRecord, _ b: IssueRecord) -> Bool? {
            switch by {
            case .created:
                return a.createdAt == b.createdAt ? nil : a.createdAt < b.createdAt
            case .title:
                let order = a.title.localizedStandardCompare(b.title)
                return order == .orderedSame ? nil : order == .orderedAscending
            case .number:
                return a.number == b.number ? nil : a.number < b.number
            case .timeInStatus:
                return Self.compare(context.signals(a).timeInStatus, context.signals(b).timeInStatus, descending: descending)
            case .inProgress:
                return Self.compare(context.signals(a).inProgress, context.signals(b).inProgress, descending: descending)
            case .key(let key):
                let x = key.values(of: a, in: context).min() ?? .none
                let y = key.values(of: b, in: context).min() ?? .none
                if x == y { return nil }
                // No value last, whichever way round.
                if x == .none { return descending }
                if y == .none { return !descending }
                return x < y
            }
        }
        return issues.sorted { a, b in
            guard let ascending = compare(a, b) else { return a.createdAt > b.createdAt }
            return descending ? !ascending : ascending
        }
    }

    /// Missing values after present ones, whichever way round.
    private static func compare(_ a: TimeInterval?, _ b: TimeInterval?, descending: Bool) -> Bool? {
        switch (a, b) {
        case (nil, nil): return nil
        case (nil, _): return descending
        case (_, nil): return !descending
        case (let x?, let y?): return x == y ? nil : x < y
        }
    }
}

enum FieldGroupOrder: String, Codable, CaseIterable {
    case value = "Board order"
    case count = "Count"
    case measure = "Measure"
}

enum FieldViewState: String, Codable, CaseIterable {
    case open = "Open"
    case closed = "Closed"
    case all = "All"
}

enum FieldViewLayout: String, Codable, CaseIterable {
    case outline = "Outline"
    case board = "Board"
    case table = "Table"
    case grid = "Grid"
    case aging = "Aging"

    var systemImage: String {
        switch self {
        case .outline: "list.bullet.indent"
        case .board: "rectangle.split.3x1"
        case .table: "tablecells"
        case .grid: "square.grid.3x3"
        case .aging: "chart.dots.scatter"
        }
    }

    /// The grid needs a second dimension for its columns.
    func fits(dimensions: Int) -> Bool {
        self == .grid ? dimensions >= 2 : dimensions >= 1
    }
}

/// What a group's number says, beside its count.
enum FieldMeasure: String, Codable, CaseIterable {
    case count = "Count"
    /// How long the issues have been in their board status, median.
    case ageInStatus = "Time in status"
    /// Time in the org's in-progress statuses so far, median.
    case inProgress = "Time in progress"

    /// The group's value, in seconds for the times; nil when no issue has one.
    func value(_ issues: [IssueRecord], context: FieldContext) -> Double? {
        switch self {
        case .count:
            return Double(issues.count)
        case .ageInStatus:
            return Self.median(issues.compactMap { context.signals($0).timeInStatus })
        case .inProgress:
            return Self.median(issues.compactMap { context.signals($0).inProgress })
        }
    }

    func format(_ value: Double?) -> String {
        guard let value else { return "" }
        switch self {
        case .count: return String(Int(value))
        case .ageInStatus, .inProgress: return value.compactDuration
        }
    }

    private static func median(_ values: [TimeInterval]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.sorted()[values.count / 2]
    }
}

/// Only issues whose value for `key` is one of `values` (by name; nil in
/// the set is no value).
struct FieldFilter: Codable, Hashable, Identifiable {
    var id = UUID()
    var key: FieldKey
    var values: Set<String?>
}

/// Something an issue can be grouped or filtered by: one of the board's
/// fields by name, an attribute of the issue, or something Gannin works out
/// (how long it's sat, and whether the board and the code disagree).
enum FieldKey: Codable, Hashable {
    case field(String)
    case repository
    case issueType
    case assignee
    case label
    case milestone
    case author
    case linkedPullRequest
    case parent
    case subIssues
    case created
    case closed
    case attention
    case ageInStatus
    /// The harness's plans and requirements about the issue.
    case plan
    case requirement

    static let attributes: [FieldKey] = [.repository, .issueType, .assignee, .label, .milestone, .author, .linkedPullRequest, .parent, .subIssues, .created, .closed]
    static let derived: [FieldKey] = [.attention, .ageInStatus, .plan, .requirement]

    var title: String {
        switch self {
        case .field(let name): name
        case .repository: "Repository"
        case .issueType: "Type"
        case .assignee: "Assignee"
        case .label: "Label"
        case .milestone: "Milestone"
        case .author: "Opened by"
        case .linkedPullRequest: "Linked PR"
        case .parent: "Parent issue"
        case .subIssues: "Sub-issues"
        case .created: "Created"
        case .closed: "Closed"
        case .attention: "Attention"
        case .ageInStatus: "Time in status"
        case .plan: "Plan"
        case .requirement: "Requirement"
        }
    }

    /// The field's name on the board, for writing; nothing else is written
    /// from here.
    var fieldName: String? {
        if case .field(let name) = self { return name }
        return nil
    }

    /// The issue's values: one for most, several for assignees, labels and
    /// attention, and `.none` when it has none.
    func values(of issue: IssueRecord, in context: FieldContext) -> [FieldValue] {
        let found: [FieldValue]
        switch self {
        case .field(let name):
            let value = context.board.flatMap { issue.fields(onProject: $0)?.values[name] }
            // A multi-select issue is in each of its options' groups.
            if case .options(let names)? = value {
                found = names.enumerated().map { FieldValue(name: $1, order: Double($0)) }
            } else {
                found = value.map { [FieldValue($0)] } ?? []
            }
        case .repository:
            found = [FieldValue(name: issue.repo.split(separator: "/").last.map(String.init) ?? issue.repo)]
        case .issueType:
            found = issue.issueType.map { [FieldValue(name: $0)] } ?? []
        case .assignee:
            found = issue.assignees.map { FieldValue(name: $0) }
        case .label:
            found = issue.labels.map { FieldValue(name: $0) }
        case .milestone:
            found = issue.milestone.map { [FieldValue(name: $0)] } ?? []
        case .author:
            found = issue.author.map { [FieldValue(name: $0)] } ?? []
        case .linkedPullRequest:
            // Its PRs' states, most advanced first: merged, open, closed.
            let states = Set(issue.linkedPullRequests.map { $0.mergedAt != nil ? "MERGED" : $0.state })
            found = [("MERGED", "Merged PR", 0.0), ("OPEN", "Open PR", 1.0), ("CLOSED", "Closed PR", 2.0)]
                .filter { states.contains($0.0) }
                .map { FieldValue(name: $0.1, order: $0.2) }
        case .parent:
            found = issue.parentID.map { [FieldValue(name: context.parentTitle($0))] } ?? []
        case .subIssues:
            found = issue.subIssuesAddedAt.isEmpty ? [] : [FieldValue(name: "Has sub-issues")]
        case .created:
            found = [Self.month(issue.createdAt)]
        case .closed:
            found = issue.closedAt.map { [Self.month($0)] } ?? []
        case .attention:
            found = context.signals(issue).flags.map { FieldValue(name: $0.rawValue, order: Double($0.order)) }
        case .ageInStatus:
            found = context.signals(issue).timeInStatus.map { [AgeBucket(seconds: $0).value] } ?? []
        case .plan:
            found = context.documents(about: issue, kind: .plans)
        case .requirement:
            found = context.documents(about: issue, kind: .requirements)
        }
        return found.isEmpty ? [.none] : found
    }
}

extension FieldKey {
    /// "Sep 2026", ordered by date.
    static func month(_ date: Date) -> FieldValue {
        let start = Calendar.current.dateInterval(of: .month, for: date)?.start ?? date
        return FieldValue(name: start.formatted(.dateTime.month(.abbreviated).year()), order: start.timeIntervalSince1970)
    }
}

/// Time in status in bands, so it can be grouped and gridded.
enum AgeBucket: Int, CaseIterable {
    case day, fewDays, week, fortnight, month, older

    init(seconds: TimeInterval) {
        let days = seconds / 86_400
        switch days {
        case ..<1: self = .day
        case ..<3: self = .fewDays
        case ..<7: self = .week
        case ..<14: self = .fortnight
        case ..<30: self = .month
        default: self = .older
        }
    }

    var title: String {
        switch self {
        case .day: "Under a day"
        case .fewDays: "1 to 3 days"
        case .week: "3 to 7 days"
        case .fortnight: "1 to 2 weeks"
        case .month: "2 to 4 weeks"
        case .older: "Over a month"
        }
    }

    var value: FieldValue { FieldValue(name: title, order: Double(rawValue)) }
}

/// One value a group is for, ordered as the board orders it: options by
/// position, iterations by start, anything else by name; no value last.
struct FieldValue: Hashable, Comparable {
    static let none = FieldValue(name: nil, order: .infinity)

    /// nil is no value.
    let name: String?
    let order: Double

    init(name: String?, order: Double = 0) {
        self.name = name
        self.order = order
    }

    init(_ value: IssueFieldValue) {
        switch value {
        case .option(let name, let position): self.init(name: name, order: Double(position))
        case .iteration(let title, let start): self.init(name: title, order: start.timeIntervalSince1970)
        case .number(let number): self.init(name: value.display, order: number)
        case .date(let date): self.init(name: value.display, order: date.timeIntervalSince1970)
        case .text, .options: self.init(name: value.display)
        }
    }

    var title: String { name ?? "No value" }

    static func < (a: FieldValue, b: FieldValue) -> Bool {
        if a.order != b.order { return a.order < b.order }
        return (a.name ?? "").localizedStandardCompare(b.name ?? "") == .orderedAscending
    }
}

// MARK: - What Gannin works out

/// What a view needs beyond the issues: its board, the org's workflow (which
/// statuses are in progress) and the time now, with each issue's signals
/// worked out once.
final class FieldContext {
    let board: Int?
    let workflow: IssueWorkflow
    let now: Date
    /// For naming parent issues.
    private let history: IssueHistory?
    /// For the plans and requirements about each issue.
    private let harness: HarnessIndex?
    private var cache: [String: IssueSignals] = [:]

    init(board: Int?, workflow: IssueWorkflow, history: IssueHistory? = nil, harness: HarnessIndex? = nil, now: Date = .now) {
        self.board = board
        self.workflow = workflow
        self.history = history
        self.harness = harness
        self.now = now
    }

    /// Whether the harness has a document of this kind about the issue (not
    /// one that only mentions it): "Has plan", or nothing.
    func documents(about issue: IssueRecord, kind: HarnessKind) -> [FieldValue] {
        guard let harness else { return [] }
        let has = harness.matches(repo: issue.repo, number: issue.number)
            .contains { $0.isSubject && $0.document.kind == kind }
        return has ? [FieldValue(name: "Has \(kind.singular)")] : []
    }

    /// "#12 Title" when the history has the parent, else "Another issue".
    func parentTitle(_ id: String) -> String {
        guard let parent = history?.issues[id] else { return "Another issue" }
        return "#\(parent.number) \(parent.title)"
    }

    func signals(_ issue: IssueRecord) -> IssueSignals {
        if let cached = cache[issue.id] { return cached }
        let signals = IssueSignals(issue, board: board, workflow: workflow, now: now)
        cache[issue.id] = signals
        return signals
    }
}

/// How long an issue has sat, and where the board and the code disagree.
struct IssueSignals {
    /// Where the board and the code disagree, each with the move that
    /// would put it right.
    enum Flag: String, CaseIterable {
        case quiet = "Quiet in progress"
        case mergedNotDone = "PR merged, not done"
        case reviewWithoutPR = "In review, no open PR"
        case doneButOpen = "Done, still open"
        case closedNotDone = "Closed, not done"

        var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }

        var explanation: String {
            switch self {
            case .quiet: "In progress, with nothing on its PRs for five days"
            case .mergedNotDone: "Every linked PR has merged but the issue isn't done"
            case .reviewWithoutPR: "In a review status with no open PR"
            case .doneButOpen: "Done on the board but the issue is still open"
            case .closedNotDone: "Closed as completed but not done on the board"
            }
        }
    }

    static let quietAfter: TimeInterval = 5 * 86_400

    /// The board's Status, else the last status the history saw.
    let status: String?
    /// Since the last status change on the board (or since it was opened).
    let timeInStatus: TimeInterval?
    /// Time in in-progress statuses so far; nil when never started.
    let inProgress: TimeInterval?
    let flags: [Flag]

    init(_ issue: IssueRecord, board: Int?, workflow: IssueWorkflow, now: Date) {
        let changes = issue.statusChanges.filter { board == nil || $0.projectNumber == board }
        let boardStatus = board.flatMap { issue.fields(onProject: $0)?.values["Status"]?.display }
        status = boardStatus ?? changes.last?.status
        let since = changes.last?.at ?? (status == nil ? nil : issue.createdAt)
        timeInStatus = since.map { (issue.closedAt ?? now).timeIntervalSince($0) }
        var timingWorkflow = workflow
        if let board { timingWorkflow.projectNumber = board }
        let timing = IssueTiming(issue, workflow: timingWorkflow, now: now)
        inProgress = timing.cycleTime

        var flags: [Flag] = []
        let lower = status?.lowercased() ?? ""
        let isDone = ["done", "complete", "shipped", "released"].contains { lower.contains($0) }
        let isInProgress = status.map(workflow.isInProgress) ?? false
        let pullRequests = issue.linkedPullRequests
        if issue.isOpen {
            if isInProgress {
                let last = (pullRequests.flatMap(\.activityAt) + pullRequests.map(\.createdAt) + [since].compactMap { $0 }).max()
                if let last, now.timeIntervalSince(last) > Self.quietAfter { flags.append(.quiet) }
            }
            if !pullRequests.isEmpty, pullRequests.allSatisfy({ $0.mergedAt != nil }), !isDone { flags.append(.mergedNotDone) }
            if lower.contains("review"), !pullRequests.contains(where: { $0.state == "OPEN" }) { flags.append(.reviewWithoutPR) }
            if isDone { flags.append(.doneButOpen) }
        } else if issue.isCompleted, status != nil, !isDone {
            flags.append(.closedNotDone)
        }
        self.flags = flags
    }
}

// MARK: - Grouping

/// Issues sharing a value at one level, with the next dimension's groups
/// inside; the last level has none.
struct FieldGroup: Identifiable {
    /// The values from the top down to this group, so it's unique in the tree.
    let path: [FieldValue]
    let issues: [IssueRecord]
    let children: [FieldGroup]

    var value: FieldValue { path.last ?? .none }
    var id: String { path.map { $0.name ?? "\u{0}" }.joined(separator: "\u{1}") }

    /// Groups by the dimensions in turn. An issue with several values (two
    /// assignees, say) is in each of their groups.
    /// Issues keep their order within each group. Groups are in board
    /// order, or by size or the measure (largest first), with no value last.
    static func groups(
        _ issues: [IssueRecord],
        by dimensions: [FieldKey],
        context: FieldContext,
        order: FieldGroupOrder = .value,
        measure: FieldMeasure = .count,
        path: [FieldValue] = []
    ) -> [FieldGroup] {
        guard let key = dimensions.first else { return [] }
        var byValue: [FieldValue: [IssueRecord]] = [:]
        for issue in issues {
            for value in Set(key.values(of: issue, in: context)) { byValue[value, default: []].append(issue) }
        }
        let values: [FieldValue]
        switch order {
        case .value:
            values = byValue.keys.sorted()
        case .count, .measure:
            let score = byValue.mapValues { members in
                order == .count ? Double(members.count) : measure.value(members, context: context) ?? -1
            }
            values = byValue.keys.sorted { a, b in
                if (a == .none) != (b == .none) { return b == .none }
                let (x, y) = (score[a] ?? 0, score[b] ?? 0)
                return x == y ? a < b : x > y
            }
        }
        return values.map { value in
            let members = byValue[value] ?? []
            let rest = Array(dimensions.dropFirst())
            return FieldGroup(path: path + [value], issues: members, children: groups(members, by: rest, context: context, order: order, measure: measure, path: path + [value]))
        }
    }
}

extension FieldView {
    func context(workflow: IssueWorkflow, history: IssueHistory?, harness: HarnessIndex? = nil) -> FieldContext {
        FieldContext(board: projectNumber, workflow: workflow, history: history, harness: harness)
    }

    /// The stored issues the view covers: in its state, on its board when it
    /// has one, and passing every filter; in the view's order.
    func issues(in history: IssueHistory?, context: FieldContext) -> [IssueRecord] {
        guard let history else { return [] }
        let matching = history.issues.values
            .filter { issue in
                switch state {
                case .open: issue.isOpen
                case .closed: !issue.isOpen
                case .all: true
                }
            }
            .filter { issue in projectNumber.map { issue.fields(onProject: $0) != nil } ?? true }
            .filter { issue in
                filters.allSatisfy { filter in
                    filter.values.isEmpty || filter.key.values(of: issue, in: context).contains { filter.values.contains($0.name) }
                }
            }
        return sort.sorted(matching, context: context)
    }

    /// Every value `key` takes across `issues`, ordered, for filters, the
    /// grid's columns and the board's.
    static func values(of key: FieldKey, in issues: [IssueRecord], context: FieldContext) -> [FieldValue] {
        Set(issues.flatMap { key.values(of: $0, in: context) }).sorted()
    }

    /// The board's field names seen on its issues, for the pickers before
    /// the board's own definition has loaded.
    static func fieldNames(in history: IssueHistory?, board: Int) -> [String] {
        let records = history.map { Array($0.issues.values) } ?? []
        let names = records.compactMap { $0.fields(onProject: board) }.flatMap(\.values.keys)
        return Set(names).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

extension FieldView {
    /// Tolerates views saved before a field existed.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "View"
        projectNumber = try container.decodeIfPresent(Int.self, forKey: .projectNumber)
        dimensions = (try? container.decodeIfPresent([FieldKey].self, forKey: .dimensions)) ?? []
        filters = (try? container.decodeIfPresent([FieldFilter].self, forKey: .filters)) ?? []
        state = (try? container.decodeIfPresent(FieldViewState.self, forKey: .state)) ?? .open
        layout = (try? container.decodeIfPresent(FieldViewLayout.self, forKey: .layout)) ?? .outline
        measure = (try? container.decodeIfPresent(FieldMeasure.self, forKey: .measure)) ?? .count
        sort = (try? container.decodeIfPresent(FieldSort.self, forKey: .sort)) ?? FieldSort()
        groupOrder = (try? container.decodeIfPresent(FieldGroupOrder.self, forKey: .groupOrder)) ?? .value
        shownFields = (try? container.decodeIfPresent([FieldKey].self, forKey: .shownFields)) ?? []
    }
}
