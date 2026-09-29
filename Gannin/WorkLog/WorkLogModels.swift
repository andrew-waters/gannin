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

/// Recent PR activity per org, kept on disk and topped up with what changed.
struct WorkLogHistory: Codable {
    /// Bumped when the stored shape gains fields old caches can't fill in,
    /// so they're fetched again.
    static let currentVersion = 3

    var version: Int? = Self.currentVersion
    let orgLogin: String
    /// PRs updated since this date are all here.
    var coveredFrom: Date
    var fetchedAt: Date
    var pullRequests: [String: WorkLogPullRequest]
}

/// One dot in the log.
struct WorkLogEvent: Identifiable, Hashable {
    enum Kind: String, CaseIterable {
        case commit = "Commit"
        case review = "Review"
        case opened = "PR opened"
        case merged = "PR merged"

        /// Categorical palette slots 1-4, in order.
        var slot: Int {
            switch self {
            case .commit: 0
            case .review: 1
            case .opened: 2
            case .merged: 3
            }
        }
    }

    let id: String
    let kind: Kind
    let at: Date
    let login: String
    let pullRequest: WorkLogPullRequest
    /// Lines changed, for commits.
    let lines: Int
    /// The author's UTC offset at the time, for commits.
    var utcOffset: Int? = nil

    /// Radius in points before a cell scales its cluster to fit.
    var radius: Double {
        switch kind {
        case .commit: min(9, 3 + 1.6 * log10(1 + Double(lines)))
        case .review: 5
        case .opened, .merged: 6.5
        }
    }

    var summary: String {
        var text = "\(kind.rawValue) · \(pullRequest.repo)#\(pullRequest.number) \(pullRequest.title)"
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
            events.append(WorkLogEvent(id: "\(id)-c\(index)", kind: .commit, at: commit.authoredAt, login: login, pullRequest: self, lines: commit.additions + commit.deletions, utcOffset: commit.utcOffset))
        }
        for (index, review) in reviews.enumerated() where review.author != author {
            events.append(WorkLogEvent(id: "\(id)-r\(index)", kind: .review, at: review.submittedAt, login: review.author, pullRequest: self, lines: 0))
        }
        if let author {
            events.append(WorkLogEvent(id: "\(id)-o", kind: .opened, at: createdAt, login: author, pullRequest: self, lines: 0))
        }
        if let mergedAt, let merger = mergedBy ?? author {
            events.append(WorkLogEvent(id: "\(id)-m", kind: .merged, at: mergedAt, login: merger, pullRequest: self, lines: 0))
        }
        return events
    }
}
