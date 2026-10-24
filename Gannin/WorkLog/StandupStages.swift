import Foundation

/// How a team runs its standup (Rituals › Standup): the style it opens on,
/// which stage each of the workflow board's statuses falls in, the label
/// that marks an issue for discussion, and how Up next finds work. Kept in the project's harness
/// (`.gannin/standup.json`) and read leniently: a style or stage this Gannin
/// doesn't know reads as the default, so the rest of the file isn't lost.
struct StandupConfig: Codable, Hashable {
    enum Style: String, Codable, CaseIterable, Identifiable {
        /// The board column by column: done and to discuss, in review, in
        /// progress, triage.
        case board
        /// One person at a time: their tickets by stage, and their day.
        case people
        /// The issues closed that day, by investment category.
        case changelog
        /// Each person's day and tickets as Markdown, for a standup that's
        /// posted rather than met.
        case written

        var id: Self { self }

        var name: String {
            switch self {
            case .board: "Walk the Board"
            case .people: "Person by Person"
            case .changelog: "Changelog"
            case .written: "Written"
            }
        }
    }

    /// Where a status's issues show; `hidden` leaves them off the standup.
    enum Stage: String, Codable, CaseIterable, Identifiable {
        case done
        case review
        case progress
        /// Up next's backlog, offered to whoever needs work.
        case backlog
        case hidden

        var id: Self { self }

        var name: String {
            switch self {
            case .done: "Done"
            case .review: "In review"
            case .progress: "In progress"
            case .backlog: "Backlog"
            case .hidden: "Not shown"
            }
        }
    }

    /// Who Up next says needs work.
    enum NeedsWork: String, Codable, CaseIterable, Identifiable {
        case nothingInProgress
        /// Review counts as work too.
        case nothingInProgressOrReview

        var id: Self { self }

        var name: String {
            switch self {
            case .nothingInProgress: "Nothing in progress"
            case .nothingInProgressOrReview: "Nothing in progress or in review"
            }
        }
    }

    static let defaultDiscussionLabel = "needs discussion"

    /// Nil opens on Walk the Board.
    var style: Style?
    /// Stage by status, as the board names it. A status missing here is
    /// guessed from its name (`guess`).
    var stages: [String: Stage] = [:]
    /// Nil or blank means `needs discussion`.
    var discussionLabel: String?
    /// The board field the backlog is sorted by; nil is oldest first.
    var backlogField: String?
    /// Sorts the backlog highest value first; nil or false is lowest first.
    var backlogHighestFirst: Bool?
    /// Nil is nothing in progress.
    var needsWork: NeedsWork?

    init(
        style: Style? = nil, stages: [String: Stage] = [:], discussionLabel: String? = nil,
        backlogField: String? = nil, backlogHighestFirst: Bool? = nil, needsWork: NeedsWork? = nil
    ) {
        self.style = style
        self.stages = stages
        self.discussionLabel = discussionLabel
        self.backlogField = backlogField
        self.backlogHighestFirst = backlogHighestFirst
        self.needsWork = needsWork
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        style = (try? container.decodeIfPresent(String.self, forKey: .style)).flatMap(Style.init(rawValue:))
        let stages = (try? container.decodeIfPresent([String: String].self, forKey: .stages)) ?? [:]
        self.stages = stages.compactMapValues(Stage.init(rawValue:))
        discussionLabel = try? container.decodeIfPresent(String.self, forKey: .discussionLabel)
        backlogField = try? container.decodeIfPresent(String.self, forKey: .backlogField)
        backlogHighestFirst = try? container.decodeIfPresent(Bool.self, forKey: .backlogHighestFirst)
        needsWork = (try? container.decodeIfPresent(String.self, forKey: .needsWork)).flatMap(NeedsWork.init(rawValue:))
    }

    var openingStyle: Style { style ?? .board }

    /// The label that marks an issue for discussion.
    var discussion: String {
        let label = discussionLabel?.trimmingCharacters(in: .whitespaces) ?? ""
        return label.isEmpty ? Self.defaultDiscussionLabel : label
    }

    func isDiscussed(_ issue: IssueRecord) -> Bool {
        issue.labels.contains { $0.caseInsensitiveCompare(discussion) == .orderedSame }
    }

    /// The status's stage: the team's choice, else a guess from its name.
    /// The exact name first, then the first case-insensitive match by name,
    /// so keys differing only by case (two Macs' edits merged) always give
    /// the same stage.
    func stage(for status: String, workflow: IssueWorkflow) -> Stage {
        if let stage = stages[status] { return stage }
        let key = stages.keys.sorted().first { $0.caseInsensitiveCompare(status) == .orderedSame }
        return key.flatMap { stages[$0] } ?? Self.guess(status, workflow: workflow)
    }

    /// Done-like names are done and review names in review (before in
    /// progress, as a team may count review towards cycle time); the issue
    /// workflow's in-progress statuses, and names saying so, are in progress;
    /// names like Backlog, Todo or Ready are the backlog.
    static func guess(_ status: String, workflow: IssueWorkflow) -> Stage {
        let name = status.lowercased()
        if ["done", "complete", "shipped", "released", "closed"].contains(where: name.contains) { return .done }
        if name.contains("review") { return .review }
        if workflow.isInProgress(status) || name.contains("progress") || name.contains("doing") { return .progress }
        if ["backlog", "todo", "to do", "ready", "next"].contains(where: name.contains) { return .backlog }
        return .hidden
    }
}

/// The workflow board as a standup walks it, column by column: what's in a
/// done status and what needs discussing, what's in review, what's in
/// progress, and what's waiting for triage (the same issues as
/// Prioritisation's, `TriageQueue.untriaged`); then Up next, who needs work
/// and the backlog. Open issues only: closing an issue takes it off the
/// standup.
struct StandupBoard {
    enum Column: Int, CaseIterable, Identifiable {
        case done
        case review
        case progress
        case triage

        var id: Self { self }

        var title: String {
            switch self {
            case .done: "Done and needs discussion"
            case .review: "In review"
            case .progress: "In progress"
            case .triage: "Triage"
            }
        }

        var symbol: String {
            switch self {
            case .done: "checkmark.seal.fill"
            case .review: "eye.fill"
            case .progress: "hammer.fill"
            case .triage: "tray.fill"
            }
        }
    }

    struct Item: Identifiable, Hashable {
        let record: IssueRecord
        /// Its Status on the board; nil with none, or off the board.
        let status: String?
        let isOnBoard: Bool
        /// Its last move on the board, else when it was opened.
        let since: Date
        let needsDiscussion: Bool
        /// Its value of the backlog's sort field, for the backlog.
        var sortValue: IssueFieldValue? = nil

        var id: String { record.id }
    }

    /// Open issues with the discussion label, whatever their column. Shown
    /// first under Done and in their own column too; never in Done's own
    /// list as well.
    private(set) var discussion: [Item] = []
    private(set) var columns: [Column: [Item]] = [:]
    /// Open issues in a backlog status, in the team's order.
    private(set) var backlog: [Item] = []
    let needsWorkRule: StandupConfig.NeedsWork

    func items(_ column: Column) -> [Item] { columns[column] ?? [] }

    /// How many the column shows: done counts what's to discuss as well.
    func count(_ column: Column) -> Int {
        items(column).count + (column == .done ? discussion.count : 0)
    }

    var isEmpty: Bool { discussion.isEmpty && columns.values.allSatisfy(\.isEmpty) }

    /// `issues` are those the workload counts (`TriageQueue.counted`); closed
    /// ones are left out.
    init(issues: [IssueRecord], board: Int, config: OrgConfig) {
        let standup = config.standupConfig
        let workflow = config.workflow
        needsWorkRule = standup.needsWork ?? .nothingInProgress
        var positions: [String: Int] = [:]
        for issue in issues where issue.isOpen {
            let fields = issue.fields(onProject: board)
            let status = fields?.values["Status"]?.display
            if case .option(_, let position) = fields?.values["Status"] { positions[issue.id] = position }
            let lastMove = issue.statusChanges.filter { $0.projectNumber == board }.max { $0.at < $1.at }
            let discussed = standup.isDiscussed(issue)
            let item = Item(record: issue, status: status, isOnBoard: fields != nil, since: lastMove?.at ?? issue.createdAt, needsDiscussion: discussed)
            if discussed { discussion.append(item) }
            // No status is triage, below.
            guard let status else { continue }
            switch standup.stage(for: status, workflow: workflow) {
            // To discuss lists it already.
            case .done: if !discussed { columns[.done, default: []].append(item) }
            case .review: columns[.review, default: []].append(item)
            case .progress: columns[.progress, default: []].append(item)
            case .backlog:
                var item = item
                item.sortValue = standup.backlogField.flatMap { field in
                    fields?.values.first { $0.key.caseInsensitiveCompare(field) == .orderedSame }?.value
                }
                backlog.append(item)
            case .hidden: break
            }
        }
        columns[.triage] = TriageQueue.untriaged(issues, board: board).map { issue in
            Item(record: issue, status: nil, isOnBoard: issue.fields(onProject: board) != nil, since: issue.createdAt, needsDiscussion: standup.isDiscussed(issue))
        }

        // Done newest first; in review and in progress by board order, the
        // longest there first; to discuss, the longest waiting first.
        columns[.done]?.sort { $0.since > $1.since }
        for column in [Column.review, .progress] {
            columns[column]?.sort { a, b in
                let (pa, pb) = (positions[a.id] ?? .max, positions[b.id] ?? .max)
                return pa != pb ? pa < pb : a.since < b.since
            }
        }
        discussion.sort { $0.since < $1.since }
        backlog = Self.ordered(backlog, highestFirst: standup.backlogHighestFirst == true)
    }

    /// By the sort field's value, those without one last; the oldest first
    /// otherwise.
    static func ordered(_ items: [Item], highestFirst: Bool) -> [Item] {
        items.sorted { a, b in
            switch (a.sortValue, b.sortValue) {
            case (let x?, let y?) where IssueFieldValue.ascending(x, y) || IssueFieldValue.ascending(y, x):
                return highestFirst ? IssueFieldValue.ascending(y, x) : IssueFieldValue.ascending(x, y)
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.record.createdAt < b.record.createdAt
            }
        }
    }

    /// Someone with nothing to work on, as the team counts it, and the
    /// backlog already assigned to them.
    struct Idle: Identifiable {
        let login: String
        let backlog: [Item]

        var id: String { login }
    }

    /// Of `logins`, those who need work, in the order given.
    func needingWork(_ logins: [String]) -> [Idle] {
        let busy: [Column] = needsWorkRule == .nothingInProgressOrReview ? [.progress, .review] : [.progress]
        return logins.compactMap { login in
            let working = busy.contains { column in items(column).contains { $0.record.assignees.contains(login) } }
            return working ? nil : Idle(login: login, backlog: backlog.filter { $0.record.assignees.contains(login) })
        }
    }

    /// Only the issues assigned to `login`.
    func assigned(to login: String) -> StandupBoard {
        var board = self
        board.discussion = discussion.filter { $0.record.assignees.contains(login) }
        board.columns = columns.mapValues { $0.filter { $0.record.assignees.contains(login) } }
        board.backlog = backlog.filter { $0.record.assignees.contains(login) }
        return board
    }
}
