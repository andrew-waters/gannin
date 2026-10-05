import Foundation

/// An issue with the history issue metrics are built from: project status
/// changes, assignments, reopenings, sub-issues and the PRs that close it.
struct IssueRecord: Codable, Hashable, Identifiable {
    let id: String
    let number: Int
    let title: String
    let url: URL
    let repo: String
    /// Who opened it. Optional so records from before it was fetched still
    /// load; they gain it when next fetched.
    let author: String?
    let assignees: [String]
    /// A var so labels written from the app show before the next fetch.
    var labels: [String]
    let issueType: String?
    let milestone: String?
    /// The parent issue's node ID, for inheriting its investment category.
    let parentID: String?
    let createdAt: Date
    let closedAt: Date?
    /// COMPLETED, NOT_PLANNED or DUPLICATE when closed.
    let stateReason: String?
    /// A var so a status saved from the app shows before the next fetch.
    var statusChanges: [IssueStatusChange]
    let assignedAt: [Date]
    let reopenedAt: [Date]
    /// When each sub-issue was added, for scope creep.
    let subIssuesAddedAt: [Date]
    let linkedPullRequests: [IssueLinkedPullRequest]
    /// PRs that mention the issue (GitHub's cross-reference) without formally
    /// closing it, such as a PR in another repo with no closing keyword.
    /// Optional so records from before it was fetched still load; they gain
    /// it when next fetched.
    let mentionedInPullRequests: [IssueLinkedPullRequest]?
    /// The issue's field values on each project board it's on. A var so edits
    /// from the issue window show before the next fetch.
    var projectFields: [IssueProjectFields]

    func fields(onProject number: Int) -> IssueProjectFields? {
        projectFields.first { $0.projectNumber == number }
    }

    var isOpen: Bool { closedAt == nil }
    var isCompleted: Bool { closedAt != nil && stateReason == "COMPLETED" }
    var isNotPlanned: Bool { closedAt != nil && (stateReason == "NOT_PLANNED" || stateReason == "DUPLICATE") }
}

struct IssueStatusChange: Codable, Hashable {
    let at: Date
    let status: String
    let projectNumber: Int?
    let projectTitle: String?
}

/// An issue's values on one project board, by field name.
struct IssueProjectFields: Codable, Hashable {
    let projectNumber: Int
    let projectTitle: String
    var values: [String: IssueFieldValue]
}

enum IssueFieldValue: Codable, Hashable {
    case text(String)
    case number(Double)
    case date(Date)
    /// A single-select option, with its position on the board for ordering.
    case option(name: String, position: Int)
    case iteration(title: String, start: Date)
    /// A multi-select field's options, in board order.
    case options([String])

    var display: String {
        switch self {
        case .text(let text): text
        case .number(let number): number == number.rounded() && abs(number) < 1e15 ? String(Int(number)) : String(number)
        case .date(let date): date.formatted(date: .abbreviated, time: .omitted)
        case .option(let name, _): name
        case .iteration(let title, _): title
        case .options(let names): names.joined(separator: ", ")
        }
    }

    /// Orders values of the same field: board order for options, start date
    /// for iterations.
    static func ascending(_ a: IssueFieldValue, _ b: IssueFieldValue) -> Bool {
        switch (a, b) {
        case (.number(let x), .number(let y)): x < y
        case (.date(let x), .date(let y)): x < y
        case (.option(_, let x), .option(_, let y)): x < y
        case (.iteration(_, let x), .iteration(_, let y)): x < y
        default: a.display.localizedStandardCompare(b.display) == .orderedAscending
        }
    }
}

struct IssueLinkedPullRequest: Codable, Hashable {
    let number: Int
    let url: URL
    let createdAt: Date
    let mergedAt: Date?
    let state: String
    /// `owner/name`, when it's known to differ from the issue's own repo
    /// (a cross-repo mention). Optional so older cached records still load.
    let repo: String?
    /// Days with commits or reviews, for flow efficiency.
    let activityAt: [Date]
}

/// Issues per org: those closed since `coveredFrom`, and every open one.
struct IssueHistory: Codable {
    let orgLogin: String
    var coveredFrom: Date
    /// When closed and changed issues were last fetched.
    var syncedAt: Date
    /// When every open issue was last fetched in full. Project status
    /// changes don't touch an issue's `updatedAt`, so a changes search misses
    /// them; open issues are refetched in full now and then instead.
    var openFetchedAt: Date
    var issues: [String: IssueRecord]
}

/// How an org's issues move through its board, for cycle time.
struct IssueWorkflow: Codable, Hashable {
    /// Only this project's statuses count; nil means any project.
    var projectNumber: Int?
    /// Statuses that count as work in progress. Compared case-insensitively.
    var inProgressStatuses: Set<String> = ["In Progress"]
    /// For issues that never reach an in-progress status: treat the first
    /// linked PR being opened as the start, and the close as the end.
    var fallBackToPullRequests = true

    func isInProgress(_ status: String) -> Bool {
        inProgressStatuses.contains { $0.caseInsensitiveCompare(status) == .orderedSame }
    }

    func counts(_ change: IssueStatusChange) -> Bool {
        projectNumber == nil || change.projectNumber == projectNumber
    }
}
