import Foundation
import Testing
@testable import Gannin

/// How a view's filters combine: all of them, or any one.
struct FieldViewFiltersTests {
    private let context = FieldContext(board: nil, workflow: IssueWorkflow())

    private func issue(assignees: [String] = [], labels: [String] = []) -> IssueRecord {
        IssueRecord(
            id: "I_1", number: 1, title: "An issue", url: URL(string: "https://github.com/acme/api/issues/1")!, repo: "acme/api",
            author: "alex", assignees: assignees, labels: labels, issueType: nil, milestone: nil, parentID: nil,
            createdAt: .now, closedAt: nil, stateReason: nil, statusChanges: [], assignedAt: [], reopenedAt: [],
            subIssuesAddedAt: [], linkedPullRequests: [], mentionedInPullRequests: nil, projectFields: []
        )
    }

    private func view(any: Bool, _ filters: [FieldFilter]) -> FieldView {
        var view = FieldView(name: "V", projectNumber: nil, dimensions: [.repository])
        view.filters = filters
        view.matchesAnyFilter = any
        return view
    }

    private let mine = FieldFilter(key: .assignee, values: ["sam"])
    private let urgent = FieldFilter(key: .label, values: ["urgent"])

    @Test func allRequiresEveryFilter() {
        let all = view(any: false, [mine, urgent])
        #expect(all.passesFilters(issue(assignees: ["sam"], labels: ["urgent"]), context: context))
        #expect(!all.passesFilters(issue(assignees: ["sam"]), context: context))
        #expect(!all.passesFilters(issue(labels: ["urgent"]), context: context))
    }

    @Test func anyRequiresOneFilter() {
        let any = view(any: true, [mine, urgent])
        #expect(any.passesFilters(issue(assignees: ["sam"]), context: context))
        #expect(any.passesFilters(issue(labels: ["urgent"]), context: context))
        #expect(!any.passesFilters(issue(assignees: ["lee"], labels: ["bug"]), context: context))
    }

    @Test func emptyFiltersAllowEverything() {
        let empty = FieldFilter(key: .label, values: [])
        #expect(view(any: true, [empty]).passesFilters(issue(), context: context))
        #expect(view(any: false, [empty]).passesFilters(issue(), context: context))
        // An empty filter doesn't make an Any view match everything.
        #expect(!view(any: true, [empty, mine]).passesFilters(issue(assignees: ["lee"]), context: context))
    }

    @Test func anySettingResetsBelowTwoFilters() {
        var one = view(any: true, [mine, FieldFilter(key: .label, values: [])])
        one.resetMatchIfSingleFilter()
        #expect(!one.matchesAnyFilter)
        var two = view(any: true, [mine, urgent])
        two.resetMatchIfSingleFilter()
        #expect(two.matchesAnyFilter)
    }

    @Test func viewsSavedWithoutTheSettingMatchAll() throws {
        let old = Data(#"{"name":"Old","dimensions":[]}"#.utf8)
        #expect(try JSONDecoder().decode(FieldView.self, from: old).matchesAnyFilter == false)
        let round = try JSONDecoder().decode(FieldView.self, from: JSONEncoder().encode(view(any: true, [mine, urgent])))
        #expect(round.matchesAnyFilter)
    }
}
