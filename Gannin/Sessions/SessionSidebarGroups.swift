import Foundation

/// How an org's sessions split into the sidebar's groups, apart from Ask and
/// Design and Refine, which `SessionStore` orders by activity.
struct SessionSidebarGroups: Equatable {
    /// An issue's own sessions, not helpers, reviews, planning, Ask or Refine.
    var issues: [CodeSession]
    /// Active reviews that still need posting, then finished ones, most recently archived first.
    var reviews: [CodeSession]
    /// Active reviews whose latest result is posted: they wait on the author.
    var awaitingAuthor: [CodeSession]
    /// Planning sessions not yet archived.
    var planning: [CodeSession]

    /// - Parameters:
    ///   - sessions: The org's sessions, in the order the groups keep.
    ///   - awaitsAuthor: Whether a review's latest result is already posted.
    init(_ sessions: [CodeSession], awaitsAuthor: (CodeSession) -> Bool) {
        issues = sessions.filter {
            !$0.isPullRequestReview && !$0.isHelper && $0.reviewStep == nil && !$0.isPlanning && !$0.isAsk && !$0.isRefine
        }
        let all = sessions.filter { $0.isPullRequestReview && !$0.isHelper }
        let active = all.filter { $0.archivedAt == nil }
        let finished = all.filter { $0.archivedAt != nil }
            .sorted { ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast) }
        reviews = active.filter { !awaitsAuthor($0) } + finished
        awaitingAuthor = active.filter(awaitsAuthor)
        planning = sessions.filter { $0.isPlanning && $0.archivedAt == nil }
    }
}
