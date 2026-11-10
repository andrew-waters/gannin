import Foundation
import Testing
@testable import Gannin

/// The sidebar splits an org's sessions into issue work, reviews, reviews
/// awaiting the author and planning.
@MainActor
struct SessionSidebarGroupsTests {
    private func session(_ number: Int, _ change: (inout CodeSession) -> Void = { _ in }) -> CodeSession {
        let issue = IssueReference(org: "acme", id: "I_\(number)", number: number, title: "Issue \(number)", repo: "acme/app",
                                   url: URL(string: "https://github.com/acme/app/issues/\(number)")!)
        var session = CodeSession(id: UUID(), issue: issue, repo: "acme/harness", branch: "b\(number)", createdAt: .now,
                                  harnessRepo: "acme/harness", harnessPath: "~/Code/acme/harness")
        change(&session)
        return session
    }

    private func review(_ number: Int, archivedAt: Date? = nil) -> CodeSession {
        session(number) {
            $0.reviewOf = PullRequestReference(org: "acme", id: "PR_\(number)", number: number, title: "PR \(number)", repo: "acme/app",
                                               url: URL(string: "https://github.com/acme/app/pull/\(number)")!)
            $0.archivedAt = archivedAt
        }
    }

    @Test func helpersAndReviewsStayOutOfIssueWork() {
        let work = session(1)
        let helper = session(2) { $0.parentID = work.id }
        let groups = SessionSidebarGroups([work, helper, review(3)], awaitsAuthor: { _ in false })
        #expect(groups.issues.map(\.id) == [work.id])
    }

    @Test func postedActiveReviewsWaitOnTheAuthor() {
        let waiting = review(1)
        let open = review(2)
        let groups = SessionSidebarGroups([waiting, open], awaitsAuthor: { $0.id == waiting.id })
        #expect(groups.awaitingAuthor.map(\.id) == [waiting.id])
        #expect(groups.reviews.map(\.id) == [open.id])
    }

    @Test func finishedReviewsFollowActiveOnesNewestArchivedFirst() {
        let active = review(1)
        let older = review(2, archivedAt: Date(timeIntervalSince1970: 100))
        let newer = review(3, archivedAt: Date(timeIntervalSince1970: 200))
        let groups = SessionSidebarGroups([older, active, newer], awaitsAuthor: { _ in false })
        #expect(groups.reviews.map(\.id) == [active.id, newer.id, older.id])
    }

    @Test func archivedPlanningIsLeftOut() {
        let info = PlanningInfo(topic: "Topic", documentPath: nil, slug: "topic")
        let live = session(1) { $0.planning = info }
        let done = session(2) { $0.planning = info; $0.archivedAt = .now }
        let groups = SessionSidebarGroups([live, done], awaitsAuthor: { _ in false })
        #expect(groups.planning.map(\.id) == [live.id])
    }
}
