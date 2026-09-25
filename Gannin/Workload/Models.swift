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

struct IssueLabel: Codable, Hashable {
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
    let assignees: [Person]
    let requestedReviewers: [Person]
    /// When each requested reviewer was (most recently) asked.
    let reviewRequestedAt: [String: Date]
    let reviewers: [Person]
    let linkedIssues: [LinkedItem]

    var isMerged: Bool { mergedAt != nil }

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
    let assignees: [Person]
    let labels: [IssueLabel]
    let linkedPullRequests: [LinkedItem]
}

/// Everything fetched for one org in a single refresh. Persisted to disk so
/// the last view is available instantly on launch.
struct OrgSnapshot: Codable {
    let orgLogin: String
    let fetchedAt: Date
    let lookbackDays: Int
    let members: [Person]
    let teams: [Team]
    let openPullRequests: [PullRequest]
    let mergedPullRequests: [PullRequest]
    let issues: [Issue]
    /// Non-fatal problems (e.g. teams hidden from this token).
    let warnings: [String]
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
}
