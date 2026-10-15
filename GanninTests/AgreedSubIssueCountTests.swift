import Foundation
import Testing
@testable import Gannin

struct AgreedSubIssueCountTests {
    private func issue(id: String, number: Int, parentID: String? = nil) -> IssueRecord {
        IssueRecord(
            id: id, number: number, title: "Issue \(number)", url: URL(string: "https://github.com/acme/app/issues/\(number)")!, repo: "acme/app",
            author: "alex", assignees: [], labels: [], issueType: nil, milestone: nil, parentID: parentID,
            createdAt: .now, closedAt: nil, stateReason: nil, statusChanges: [], assignedAt: [], reopenedAt: [],
            subIssuesAddedAt: [], linkedPullRequests: [], mentionedInPullRequests: nil, projectFields: []
        )
    }

    private func history(_ issues: [IssueRecord]) -> IssueHistory {
        IssueHistory(orgLogin: "acme", coveredFrom: .now, syncedAt: .now, openFetchedAt: .now, issues: Dictionary(uniqueKeysWithValues: issues.map { ($0.id, $0) }))
    }

    private func agreement(issues: Int) -> PlanningAgreement {
        PlanningAgreement(
            at: .now, by: [], parent: "acme/app#1", parentURL: nil,
            issues: (0..<issues).map { URL(string: "https://github.com/acme/app/issues/\($0 + 2)")! }
        )
    }

    @Test func countsSubIssuesAddedAfterAgreeing() {
        let live = history([issue(id: "p", number: 1), issue(id: "a", number: 2, parentID: "p"), issue(id: "b", number: 3, parentID: "p"), issue(id: "c", number: 4, parentID: "p")])
        #expect(agreement(issues: 2).subIssueCount(in: live) == 3)
    }

    @Test func neverCountsFewerThanAgreeRecorded() {
        let live = history([issue(id: "p", number: 1), issue(id: "a", number: 2, parentID: "p")])
        #expect(agreement(issues: 3).subIssueCount(in: live) == 3)
    }

    @Test func fallsBackToTheRecordedIssuesWithoutHistory() {
        #expect(agreement(issues: 2).subIssueCount(in: nil) == 2)
    }

    @Test func fallsBackWhenTheHistoryLacksTheParent() {
        let live = history([issue(id: "a", number: 2, parentID: "p")])
        #expect(agreement(issues: 2).subIssueCount(in: live) == 2)
    }
}
