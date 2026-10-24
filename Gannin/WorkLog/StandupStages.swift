import Foundation

/// How a team runs its standup (Rituals › Standup): the style it opens on,
/// which stage each of the workflow board's statuses falls in, and the label
/// that marks an issue for discussion. Kept in the project's harness
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
        case hidden

        var id: Self { self }

        var name: String {
            switch self {
            case .done: "Done"
            case .review: "In review"
            case .progress: "In progress"
            case .hidden: "Not shown"
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

    init(style: Style? = nil, stages: [String: Stage] = [:], discussionLabel: String? = nil) {
        self.style = style
        self.stages = stages
        self.discussionLabel = discussionLabel
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        style = (try? container.decodeIfPresent(String.self, forKey: .style)).flatMap(Style.init(rawValue:))
        let stages = (try? container.decodeIfPresent([String: String].self, forKey: .stages)) ?? [:]
        self.stages = stages.compactMapValues(Stage.init(rawValue:))
        discussionLabel = try? container.decodeIfPresent(String.self, forKey: .discussionLabel)
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
    func stage(for status: String, workflow: IssueWorkflow) -> Stage {
        stages.first { $0.key.caseInsensitiveCompare(status) == .orderedSame }?.value ?? Self.guess(status, workflow: workflow)
    }

    /// Done-like names are done and review names in review (before in
    /// progress, as a team may count review towards cycle time); the issue
    /// workflow's in-progress statuses, and names saying so, are in progress.
    static func guess(_ status: String, workflow: IssueWorkflow) -> Stage {
        let name = status.lowercased()
        if ["done", "complete", "shipped", "released", "closed"].contains(where: name.contains) { return .done }
        if name.contains("review") { return .review }
        if workflow.isInProgress(status) || name.contains("progress") || name.contains("doing") { return .progress }
        return .hidden
    }
}

/// The workflow board as a standup walks it, column by column: what's been
/// done since the last working day and what needs discussing, what's in
/// review, what's in progress, and what's waiting for triage (the same
/// issues as Prioritisation's, `TriageQueue.untriaged`).
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
        /// When it got here: closed or moved to Done, for done; its last
        /// move on the board, else when it was opened.
        let since: Date
        let needsDiscussion: Bool

        var id: String { record.id }
    }

    let since: Date
    /// Issues with the discussion label: open ones whatever their column,
    /// and those completed since. Shown first under Done, and open ones in
    /// their own column too; never in Done's own list as well.
    private(set) var discussion: [Item] = []
    private(set) var columns: [Column: [Item]] = [:]

    func items(_ column: Column) -> [Item] { columns[column] ?? [] }

    /// How many the column shows: done counts what's to discuss as well.
    func count(_ column: Column) -> Int {
        items(column).count + (column == .done ? discussion.count : 0)
    }

    var isEmpty: Bool { discussion.isEmpty && columns.values.allSatisfy(\.isEmpty) }

    /// `issues` are those the workload counts (`TriageQueue.counted`), open
    /// and closed; done is what was completed, or moved to a done status, at
    /// or after `since`.
    init(issues: [IssueRecord], board: Int, config: OrgConfig, since: Date) {
        self.since = since
        let standup = config.standupConfig
        let workflow = config.workflow
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
            case .done:
                // Only what moved there since; older Done is old news. To
                // discuss lists it already.
                if !discussed, let lastMove, lastMove.at >= since, lastMove.status.caseInsensitiveCompare(status) == .orderedSame {
                    columns[.done, default: []].append(item)
                }
            case .review: columns[.review, default: []].append(item)
            case .progress: columns[.progress, default: []].append(item)
            case .hidden: break
            }
        }
        for issue in issues where issue.isCompleted {
            guard let closed = issue.closedAt, closed >= since else { continue }
            let discussed = standup.isDiscussed(issue)
            let item = Item(record: issue, status: nil, isOnBoard: issue.fields(onProject: board) != nil, since: closed, needsDiscussion: discussed)
            if discussed { discussion.append(item) } else { columns[.done, default: []].append(item) }
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
    }

    /// Only the issues assigned to `login`.
    func assigned(to login: String) -> StandupBoard {
        var board = self
        board.discussion = discussion.filter { $0.record.assignees.contains(login) }
        board.columns = columns.mapValues { $0.filter { $0.record.assignees.contains(login) } }
        return board
    }
}
