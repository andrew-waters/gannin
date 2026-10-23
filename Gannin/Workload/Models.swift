import Foundation

nonisolated struct Person: Codable, Hashable, Identifiable {
    let login: String
    let name: String?
    let avatarUrl: URL?

    var id: String { login }

    var displayName: String {
        if let name, !name.isEmpty { return name }
        return login
    }
}

struct Viewer: Codable, Hashable {
    let login: String
    let name: String?
    let avatarUrl: URL?
}

struct Organisation: Codable, Hashable, Identifiable {
    let id: String
    let login: String
    let name: String?
    let avatarUrl: URL?
    let description: String?
    /// The signed-in user's own account rather than an org; nil for an org
    /// (and for orgs saved before).
    var isUser: Bool? = nil

    var isPersonal: Bool { isUser == true }

    var displayName: String {
        if let name, !name.isEmpty { return name }
        return login
    }
}

struct Team: Codable, Hashable, Identifiable {
    let id: String
    let slug: String
    let name: String
    let members: [String]
}

nonisolated struct IssueLabel: Codable, Hashable {
    let name: String
    let color: String
}

/// Lightweight pointer from a PR to an issue it closes, or the reverse.
struct LinkedItem: Codable, Hashable, Identifiable {
    let id: String
    let number: Int
    let title: String
    let url: URL
    let repo: String
    let state: String
}

/// One reviewer on a PR and where their review stands.
struct ReviewerEntry: Hashable, Identifiable {
    enum Standing: Hashable {
        /// Asked, and hasn't reviewed since.
        case waiting
        case approved
        case changesRequested
        case commented
        /// A review in any other state (dismissed and the like).
        case reviewed

        init(reviewState: String?) {
            switch reviewState {
            case "APPROVED": self = .approved
            case "CHANGES_REQUESTED": self = .changesRequested
            case "COMMENTED": self = .commented
            default: self = .reviewed
            }
        }

        var words: String {
            switch self {
            case .waiting: "review requested"
            case .approved: "approved"
            case .changesRequested: "changes requested"
            case .commented: "commented"
            case .reviewed: "reviewed"
            }
        }
    }

    let person: Person
    let standing: Standing

    var id: String { person.login }
}

struct PullRequest: Codable, Hashable, Identifiable {
    enum ReviewState: String, Codable {
        case approved = "APPROVED"
        case changesRequested = "CHANGES_REQUESTED"
        case reviewRequired = "REVIEW_REQUIRED"
    }

    let id: String
    let number: Int
    let title: String
    let url: URL
    let repo: String
    let author: Person?
    let isDraft: Bool
    let state: String
    let createdAt: Date
    let updatedAt: Date
    let mergedAt: Date?
    let reviewDecision: ReviewState?
    let additions: Int
    let deletions: Int
    /// Files the PR changes; nil in snapshots cached before it was fetched.
    var changedFiles: Int? = nil
    let assignees: [Person]
    var requestedReviewers: [Person]
    /// When each requested reviewer was (most recently) asked.
    var reviewRequestedAt: [String: Date]
    let reviewers: [Person]
    let linkedIssues: [LinkedItem]
    /// The latest commit's checks, as of the fetch (checks finishing don't
    /// touch `updatedAt`, so the detail store has fresher ones for pending).
    var checks: ItemDetail.CheckState? = nil
    /// Each reviewer's latest review state (`APPROVED`, `CHANGES_REQUESTED`,
    /// `COMMENTED`), for repos whose rules leave `reviewDecision` empty.
    var reviewStates: [String: String]? = nil
    /// When each reviewer's latest review was submitted.
    var reviewedAt: [String: Date]? = nil
    /// The latest commit's `committedDate`.
    var lastCommitAt: Date? = nil
    /// The latest of the author's own reviews (thread replies arrive as
    /// `COMMENTED` reviews) and conversation comments.
    var authorRepliedAt: Date? = nil
    /// Teams asked to review, as `org/slug`; nil in snapshots cached before
    /// team requests were fetched.
    var requestedTeams: [String]? = nil

    var isMerged: Bool { mergedAt != nil }

    /// Everyone asked to review it or who has, once each: those asked (again)
    /// and still waiting first, then each reviewer's latest review.
    var reviewerEntries: [ReviewerEntry] {
        let requested = Set(requestedReviewers.map(\.login))
        var seen: Set<String> = []
        let waiting = requestedReviewers.filter { seen.insert($0.login).inserted }
            .map { ReviewerEntry(person: $0, standing: .waiting) }
        let reviewed = reviewers.filter { !requested.contains($0.login) && seen.insert($0.login).inserted }
            .map { ReviewerEntry(person: $0, standing: ReviewerEntry.Standing(reviewState: reviewStates?[$0.login])) }
        return waiting + reviewed
    }

    /// `reviewStates` with automation accounts (coderabbitai and the like)
    /// left out, so their reviews don't read as a teammate's.
    var humanReviewStates: [String: String] {
        (reviewStates ?? [:]).filter { !OrgConfig.looksLikeBot($0.key) }
    }

    /// GitHub's review decision, else what the latest reviews say: a repo
    /// that doesn't require reviews gets no decision however it's reviewed.
    var review: ReviewState? {
        if let reviewDecision { return reviewDecision }
        let states = humanReviewStates.values
        if states.contains(ReviewState.changesRequested.rawValue) { return .changesRequested }
        if states.contains(ReviewState.approved.rawValue) { return .approved }
        return nil
    }

    /// Everyone doing work on this PR: author and assignees.
    var workers: Set<String> {
        var logins = Set(assignees.map(\.login))
        if let author { logins.insert(author.login) }
        return logins
    }
}

struct Issue: Codable, Hashable, Identifiable {
    let id: String
    let number: Int
    let title: String
    let url: URL
    let repo: String
    let author: Person?
    let state: String
    let createdAt: Date
    let updatedAt: Date
    let closedAt: Date?
    /// A var so assignees written from the app show before the next fetch.
    var assignees: [Person]
    let labels: [IssueLabel]
    let linkedPullRequests: [LinkedItem]
}

/// Everything fetched for one org. Persisted to disk so the last view is
/// available instantly on launch, and so refreshes only fetch what changed.
struct OrgSnapshot: Codable {
    let orgLogin: String
    /// When the latest refresh started; the next one fetches changes since.
    let fetchedAt: Date
    /// When members and teams were last fetched.
    var peopleFetchedAt: Date?
    /// When PRs and issues were last searched in full rather than for changes.
    var fullFetchedAt: Date?
    let lookbackDays: Int
    let members: [Person]
    let teams: [Team]
    /// Kept in `PullRequestStore`, not in the snapshot's own file, which lists
    /// their IDs (`storedOpenIDs`, `storedMergedIDs`) in order instead.
    var openPullRequests: [PullRequest] = []
    var mergedPullRequests: [PullRequest] = []
    /// Kept in `SharedIssueStore`, not in the snapshot's own file, which lists
    /// their IDs (`storedIssueIDs`) in order instead.
    var issues: [Issue] = []
    /// Outside repos (`OrgConfig.outsideRepos`) that have stopped being
    /// readable, by `owner/name`: GitHub's reason, or that it's been
    /// renamed and where to. Left out of searches; their last items stay,
    /// marked stale. Nil for a snapshot from before outside repos, or an
    /// account with none.
    var unreadableRepos: [String: String]?
    /// Outside repos that have had at least one full search (open PRs,
    /// merged PRs and open issues), so a later changes-only refresh can
    /// trust its "updated since" search rather than needing everything
    /// again: one just added to a project hasn't, so it still gets a full
    /// search even when the rest of the snapshot only needs its changes.
    /// Nil for a snapshot from before outside repos, or an account with none.
    var outsideReposFetched: Set<String>?
    /// Non-fatal problems (e.g. teams hidden from this token).
    let warnings: [String]
    /// The PRs' IDs as saved, set only on the copy that's written to disk.
    var storedOpenIDs: [String]?
    var storedMergedIDs: [String]?
    var storedIssueIDs: [String]?

    enum CodingKeys: String, CodingKey {
        case orgLogin, fetchedAt, peopleFetchedAt, fullFetchedAt, lookbackDays, members, teams
        case unreadableRepos, outsideReposFetched, warnings, storedOpenIDs, storedMergedIDs, storedIssueIDs
    }

    /// The snapshot before open issues moved to `SharedIssueStore`, whose
    /// file still holds them; a file without them isn't one.
    struct LegacyIssues: Decodable {
        var issues: [Issue]
    }

    /// The snapshot before PRs moved to `PullRequestStore`, whose file still
    /// holds them; a file without them isn't one.
    struct Legacy: Decodable {
        var openPullRequests: [PullRequest]
        var mergedPullRequests: [PullRequest]
    }

    /// Cached before PRs' files changed were fetched: a changes search
    /// would leave the PRs it doesn't touch without them, so the next
    /// refresh searches everything.
    var lacksFileCounts: Bool {
        (openPullRequests + mergedPullRequests).contains { $0.changedFiles == nil }
    }
}

struct Comment: Codable, Hashable, Identifiable {
    let url: URL
    let author: Person?
    let body: String
    let createdAt: Date

    var id: URL { url }
}

/// The heavier fields of an issue or PR, fetched when it is opened rather
/// than for every item in a snapshot.
struct ItemDetail: Codable, Hashable {
    enum CheckState: String, Codable {
        case success = "SUCCESS"
        case failure = "FAILURE"
        case error = "ERROR"
        case pending = "PENDING"
        case expected = "EXPECTED"
    }

    let body: String
    let commentCount: Int
    let recentComments: [Comment]
    let headRef: String?
    let baseRef: String?
    let checks: CheckState?
    /// The item's `updatedAt` when this was fetched.
    let updatedAt: Date?
}
