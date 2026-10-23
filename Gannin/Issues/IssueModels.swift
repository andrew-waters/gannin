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
    /// A var so assignees written from the app show before the next fetch.
    var assignees: [String]
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
    /// When GitHub last updated it, so the change feed can skip an issue
    /// already held at that time. Optional so records from before it was
    /// fetched still load; they're fetched once when next seen changed.
    var updatedAt: Date? = nil

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

nonisolated enum IssueFieldValue: Codable, Hashable {
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
    /// Bumped when the stored shape gains fields old caches can't fill in,
    /// so they're fetched again.
    static let currentVersion = 1

    var version: Int? = Self.currentVersion
    let orgLogin: String
    var coveredFrom: Date
    /// When closed and changed issues were last fetched.
    var syncedAt: Date
    /// When every open issue was last fetched in full. Project status
    /// changes don't touch an issue's `updatedAt`, so a changes search misses
    /// them; open issues are refetched in full now and then instead.
    var openFetchedAt: Date
    /// Kept in `SharedIssueStore`, not in the history's own file, which lists
    /// their IDs (`storedIDs`) instead.
    var issues: [String: IssueRecord] = [:]
    /// Outside repos (`OrgConfig.outsideRepos`) with a full backfill to
    /// build a changes search on; nil for none, or for a cache from before
    /// outside repos were covered (andrew-waters/gannin#205).
    var outsideReposFetched: Set<String>?
    /// The issues' IDs as saved, set only on the copy that's written to disk.
    var storedIDs: [String]?

    enum CodingKeys: String, CodingKey {
        case version, orgLogin, coveredFrom, syncedAt, openFetchedAt, outsideReposFetched, storedIDs
    }

    /// The history before issues moved to `SharedIssueStore`, whose file
    /// still holds them; a file without them isn't one.
    struct Legacy: Decodable {
        var issues: [String: IssueRecord]
    }
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

/// Where an org files its issues (Org settings › Issues › Where issues go).
/// A missing field or a kind this Gannin doesn't know reads as per repo, so
/// the file still decodes.
struct IssueStrategy: Codable, Hashable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        /// Each issue in the repo it touches, collected on a board.
        case perRepo
        /// Every issue in one named repo, whichever repo the work is in.
        case central

        var id: Self { self }

        var name: String {
            switch self {
            case .perRepo: "Per repo, collected on a project"
            case .central: "Central repo"
            }
        }
    }

    var kind: Kind = .perRepo
    /// `owner/name` every issue goes in, under `central`.
    var repo: String?
    /// The board each issue is added to under `perRepo`; nil means the
    /// project's Issue workflow board.
    var projectNumber: Int?

    init(kind: Kind = .perRepo, repo: String? = nil, projectNumber: Int? = nil) {
        self.kind = kind
        self.repo = repo
        self.projectNumber = projectNumber
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? container.decodeIfPresent(Kind.self, forKey: .kind)) ?? .perRepo
        repo = try? container.decodeIfPresent(String.self, forKey: .repo)
        projectNumber = try? container.decodeIfPresent(Int.self, forKey: .projectNumber)
    }

    /// The repo every issue goes in, when that's the strategy and one is named.
    var centralRepo: String? {
        guard kind == .central, let repo = repo?.trimmingCharacters(in: .whitespaces), repo.contains("/") else { return nil }
        return repo
    }

    /// The board a new issue is added to: under per repo the strategy's
    /// own, else the Issue workflow board.
    func board(workflow: IssueWorkflow) -> Int? {
        kind == .perRepo ? projectNumber ?? workflow.projectNumber : workflow.projectNumber
    }

    /// The repos an issue can be filed in, in order: the central repo
    /// first, then `repos` without those with issues turned off (`issuesOff`,
    /// lowercased). The central repo stays even with issues off, so the
    /// choice is visible and its warning explains it.
    func filingRepos(_ repos: [String], issuesOff: Set<String>) -> [String] {
        let open = repos.filter { !issuesOff.contains($0.lowercased()) }
        guard let central = centralRepo else { return open }
        return [central] + open.filter { $0.caseInsensitiveCompare(central) != .orderedSame }
    }

    /// Where a task's issue is filed: the central repo, else the task's own
    /// repo when it's one of `choices`, else the first choice.
    func filingRepo(for task: String?, in choices: [String]) -> String {
        if let central = centralRepo { return central }
        return task.flatMap { repo in choices.first { $0.caseInsensitiveCompare(repo) == .orderedSame } } ?? choices.first ?? ""
    }
}
