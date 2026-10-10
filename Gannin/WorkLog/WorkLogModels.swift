import Foundation

/// A PR with the dated activity the work log draws: its commits, reviews,
/// opening and merge.
struct WorkLogPullRequest: Codable, Hashable, Identifiable {
    let id: String
    let number: Int
    let title: String
    let url: URL
    let repo: String
    let author: String?
    let createdAt: Date
    let mergedAt: Date?
    /// When it was closed, merged or not; nil while open.
    let closedAt: Date?
    let mergedBy: String?
    let commits: [WorkLogCommit]
    let reviews: [WorkLogReview]
    var isDraft: Bool? = nil
    /// Issues the PR closes when merged, for the standup's context.
    var closingIssues: [LinkedItem] = []
}

struct WorkLogCommit: Codable, Hashable {
    let authoredAt: Date
    /// The GitHub user behind the commit, when its email is linked to one.
    let author: String?
    let additions: Int
    let deletions: Int
    /// The author's UTC offset in seconds, from the commit's own timestamp
    /// (the clock of the machine it was made on).
    let utcOffset: Int?
    /// The first line of the message, for the standup.
    var message: String? = nil
    var url: URL? = nil
}

struct WorkLogReview: Codable, Hashable {
    let submittedAt: Date
    let author: String
    let state: String
}

/// An issue with the dated activity the work log draws: its opening and the
/// comments left on it.
struct WorkLogIssue: Codable, Hashable, Identifiable {
    let id: String
    let number: Int
    let title: String
    let url: URL
    let repo: String
    let author: String?
    let createdAt: Date
    /// The last comments on it (up to 30), oldest first.
    let comments: [WorkLogIssueComment]
}

struct WorkLogIssueComment: Codable, Hashable {
    let createdAt: Date
    let author: String
    let url: URL?
}

/// Recent PR activity per org, kept on disk and topped up with what changed.
struct WorkLogHistory: Codable {
    /// Bumped when the stored shape gains fields old caches can't fill in,
    /// so they're fetched again.
    static let currentVersion = 4

    var version: Int? = Self.currentVersion
    let orgLogin: String
    /// PRs updated since this date are all here.
    var coveredFrom: Date
    var fetchedAt: Date
    var pullRequests: [String: WorkLogPullRequest]
    /// Issues updated in the same range, for issues opened and comments.
    var issues: [String: WorkLogIssue] = [:]
}

/// One dot in the log.
struct WorkLogEvent: Identifiable, Hashable {
    enum Kind: String, CaseIterable {
        case commit = "Commit"
        case review = "Review"
        case opened = "PR opened"
        case merged = "PR merged"
        case issueOpened = "Issue opened"
        case comment = "Issue comment"

        /// Categorical palette slots 1-6, in order.
        var slot: Int {
            switch self {
            case .commit: 0
            case .review: 1
            case .opened: 2
            case .merged: 3
            case .issueOpened: 4
            case .comment: 5
            }
        }
    }

    /// What the event happened on.
    enum Subject: Hashable {
        case pullRequest(WorkLogPullRequest)
        case issue(WorkLogIssue)

        var repo: String {
            switch self {
            case .pullRequest(let pr): pr.repo
            case .issue(let issue): issue.repo
            }
        }

        var number: Int {
            switch self {
            case .pullRequest(let pr): pr.number
            case .issue(let issue): issue.number
            }
        }

        var title: String {
            switch self {
            case .pullRequest(let pr): pr.title
            case .issue(let issue): issue.title
            }
        }
    }

    let id: String
    let kind: Kind
    let at: Date
    let login: String
    let subject: Subject
    /// Lines changed, for commits.
    let lines: Int
    /// The author's UTC offset at the time, for commits.
    var utcOffset: Int? = nil

    /// Radius in points before a cell scales its cluster to fit.
    var radius: Double {
        switch kind {
        case .commit: min(9, 3 + 1.6 * log10(1 + Double(lines)))
        case .review: 5
        case .opened, .merged, .issueOpened: 6.5
        case .comment: 4
        }
    }

    var summary: String {
        var text = "\(kind.rawValue) · \(subject.repo)#\(subject.number) \(subject.title)"
        if kind == .commit { text += " · \(lines) lines" }
        text += " · \(at.formatted(date: .omitted, time: .shortened))"
        return text
    }
}

extension WorkLogPullRequest {
    /// Every dated event on the PR, each credited to whoever did it.
    var events: [WorkLogEvent] {
        var events: [WorkLogEvent] = []
        for (index, commit) in commits.enumerated() {
            guard let login = commit.author ?? author else { continue }
            events.append(WorkLogEvent(id: "\(id)-c\(index)", kind: .commit, at: commit.authoredAt, login: login, subject: .pullRequest(self), lines: commit.additions + commit.deletions, utcOffset: commit.utcOffset))
        }
        for (index, review) in reviews.enumerated() where review.author != author {
            events.append(WorkLogEvent(id: "\(id)-r\(index)", kind: .review, at: review.submittedAt, login: review.author, subject: .pullRequest(self), lines: 0))
        }
        if let author {
            events.append(WorkLogEvent(id: "\(id)-o", kind: .opened, at: createdAt, login: author, subject: .pullRequest(self), lines: 0))
        }
        if let mergedAt, let merger = mergedBy ?? author {
            events.append(WorkLogEvent(id: "\(id)-m", kind: .merged, at: mergedAt, login: merger, subject: .pullRequest(self), lines: 0))
        }
        return events
    }
}

extension WorkLogIssue {
    /// Its opening, credited to its author, and each comment, credited to
    /// whoever left it.
    var events: [WorkLogEvent] {
        var events: [WorkLogEvent] = []
        if let author {
            events.append(WorkLogEvent(id: "\(id)-o", kind: .issueOpened, at: createdAt, login: author, subject: .issue(self), lines: 0))
        }
        for (index, comment) in comments.enumerated() {
            events.append(WorkLogEvent(id: "\(id)-n\(index)", kind: .comment, at: comment.createdAt, login: comment.author, subject: .issue(self), lines: 0))
        }
        return events
    }
}
