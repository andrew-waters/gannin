import Foundation

/// A merged PR with the timestamps cycle-time metrics are built from.
struct MetricPullRequest: Codable, Hashable, Identifiable {
    let id: String
    let number: Int
    let title: String
    let url: URL
    let repo: String
    let author: Person?
    let authorIsBot: Bool
    let createdAt: Date
    let mergedAt: Date
    /// Author date of the earliest commit on the PR.
    let firstCommitAt: Date?
    /// When a draft was marked ready; nil if it was never a draft.
    let readyAt: Date?
    /// Submitted reviews by humans other than the author, oldest first.
    /// A var so excluded reviewers can be filtered out before deriving metrics.
    var reviews: [MetricReview]
    /// Review requests to individual users, in the order they were made.
    var reviewRequests: [MetricReviewRequest]
    let additions: Int
    let deletions: Int

    /// When the PR started waiting for review.
    var reviewableAt: Date { readyAt ?? createdAt }

    /// Reviews submitted up to the merge; later ones don't affect timing.
    var reviewsBeforeMerge: [MetricReview] { reviews.filter { $0.submittedAt <= mergedAt } }

    var firstReviewAt: Date? { reviewsBeforeMerge.first?.submittedAt }
    var firstReviewer: String? { reviewsBeforeMerge.first?.login }
    /// The last approval before merge, so a PR approved, changed and
    /// re-approved counts the changes as rework rather than merge time.
    var approvedAt: Date? { reviewsBeforeMerge.last { $0.state == "APPROVED" }?.submittedAt }

    /// Distinct reviewers, in the order they first reviewed.
    var reviewers: [String] {
        var logins: [String] = []
        for review in reviews where !logins.contains(review.login) { logins.append(review.login) }
        return logins
    }
}

struct MetricReviewRequest: Codable, Hashable {
    let login: String
    let requestedAt: Date
    /// Set when the request was withdrawn before they reviewed.
    var removedAt: Date?
}

struct MetricReview: Codable, Hashable {
    let login: String
    let state: String
    let submittedAt: Date
}

/// Per-org metrics history kept on disk. Merged PRs are fetched once and
/// topped up on each sync; opened counts are cheap and refetched.
struct MetricsHistory: Codable {
    let orgLogin: String
    /// Merged PRs are complete from this date to `syncedAt`.
    var coveredFrom: Date
    var syncedAt: Date
    var pullRequests: [String: MetricPullRequest]
    /// PRs opened per week, keyed by the week's start.
    var openedPerWeek: [Date: Int]
}
