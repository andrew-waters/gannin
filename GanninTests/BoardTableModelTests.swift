import Foundation
import Testing
@testable import Gannin

struct BoardTableModelTests {
    private func item(_ id: String, _ title: String) -> BoardItem {
        BoardItem(id: id, kind: .issue, contentID: nil, title: title, number: nil, url: nil, repo: nil, state: nil,
                  assignees: [], labels: [], milestone: nil, parent: nil, subIssuesProgress: nil,
                  linkedPullRequests: 0, updatedAt: nil, values: [:])
    }

    private func group(_ name: String, _ items: [BoardItem]) -> BoardLayout.Group {
        BoardLayout.Group(name: name, value: nil, items: items)
    }

    private let byTitle: (BoardItem) -> StatsSortKey = { .text($0.title) }

    private func rows(_ entries: [BoardTableEntry]) -> [String] {
        entries.map {
            switch $0 {
            case .header(let group): "# \(group.name)"
            case .row(let item, _, _, _): item.id
            }
        }
    }

    @Test func ungroupedTableHasNoHeaders() {
        let entries = BoardTableModel.entries(
            groups: [group("", [item("a", "A"), item("b", "B")])],
            showsHeaders: false, collapsed: [], sortKey: nil, ascending: true
        )
        #expect(rows(entries) == ["a", "b"])
    }

    @Test func groupsKeepTheirHeadersAndOrder() {
        let entries = BoardTableModel.entries(
            groups: [group("Todo", [item("a", "A")]), group("Done", [item("b", "B")])],
            showsHeaders: true, collapsed: [], sortKey: nil, ascending: true
        )
        #expect(rows(entries) == ["# Todo", "a", "# Done", "b"])
    }

    @Test func collapsedGroupKeepsItsHeaderAndDropsItsRows() {
        let entries = BoardTableModel.entries(
            groups: [group("Todo", [item("a", "A")]), group("Done", [item("b", "B")])],
            showsHeaders: true, collapsed: ["Todo"], sortKey: nil, ascending: true
        )
        #expect(rows(entries) == ["# Todo", "# Done", "b"])
    }

    @Test func eachGroupIsSortedOnItsOwn() {
        let groups = [group("X", [item("x2", "b"), item("x1", "a")]), group("Y", [item("y2", "d"), item("y1", "c")])]
        let ascending = BoardTableModel.entries(groups: groups, showsHeaders: true, collapsed: [], sortKey: byTitle, ascending: true)
        #expect(rows(ascending) == ["# X", "x1", "x2", "# Y", "y1", "y2"])
        let descending = BoardTableModel.entries(groups: groups, showsHeaders: true, collapsed: [], sortKey: byTitle, ascending: false)
        #expect(rows(descending) == ["# X", "x2", "x1", "# Y", "y2", "y1"])
    }

    @Test func tiesKeepTheOrderGivenInBothDirections() {
        let groups = [group("", [item("1", "same"), item("2", "same"), item("3", "same")])]
        for ascending in [true, false] {
            let entries = BoardTableModel.entries(groups: groups, showsHeaders: false, collapsed: [], sortKey: byTitle, ascending: ascending)
            #expect(rows(entries) == ["1", "2", "3"])
        }
    }

    @Test func emptyValuesSortLastAscending() {
        let empty: (BoardItem) -> StatsSortKey = { $0.title.isEmpty ? .text("\u{10FFFF}") : .text($0.title) }
        let groups = [group("", [item("none", ""), item("a", "a")])]
        let entries = BoardTableModel.entries(groups: groups, showsHeaders: false, collapsed: [], sortKey: empty, ascending: true)
        #expect(rows(entries) == ["a", "none"])
    }

    @Test func stripingRestartsAtEachGroup() {
        let entries = BoardTableModel.entries(
            groups: [group("X", [item("a", "A"), item("b", "B")]), group("Y", [item("c", "C")])],
            showsHeaders: true, collapsed: [], sortKey: nil, ascending: true
        )
        let striped = entries.compactMap { entry -> Bool? in
            if case .row(_, _, let striped, _) = entry { striped } else { nil }
        }
        #expect(striped == [false, true, false])
    }

    private func issue(_ id: String, _ title: String, parent: String? = nil) -> BoardItem {
        BoardItem(id: id, kind: .issue, contentID: "node-\(id)", title: title, number: nil, url: nil, repo: nil, state: nil,
                         assignees: [], labels: [], milestone: nil, parent: nil, subIssuesProgress: nil,
                         linkedPullRequests: 0, updatedAt: nil, values: [:], parentID: parent.map { "node-\($0)" })
    }

    private func depths(_ entries: [BoardTableEntry]) -> [String] {
        entries.compactMap {
            if case .row(let item, _, _, let depth) = $0 { "\(item.id):\(depth)" } else { nil }
        }
    }

    @Test func subIssuesSitUnderTheirParentInTheSameGroup() {
        let groups = [group("", [issue("c", "C", parent: "p"), issue("x", "X"), issue("p", "P")])]
        let entries = BoardTableModel.entries(groups: groups, showsHeaders: false, collapsed: [], sortKey: nil, ascending: true)
        #expect(depths(entries) == ["x:0", "p:0", "c:1"])
    }

    @Test func eachLevelIsSortedOnItsOwn() {
        let groups = [group("", [issue("b", "b", parent: "p"), issue("p", "p"), issue("a", "a", parent: "p"), issue("z", "z")])]
        let entries = BoardTableModel.entries(groups: groups, showsHeaders: false, collapsed: [], sortKey: byTitle, ascending: false)
        #expect(depths(entries) == ["z:0", "p:0", "b:1", "a:1"])
    }

    @Test func aParentInAnotherGroupLeavesTheChildTopLevel() {
        let groups = [group("Todo", [issue("p", "P")]), group("Done", [issue("c", "C", parent: "p")])]
        let entries = BoardTableModel.entries(groups: groups, showsHeaders: true, collapsed: [], sortKey: nil, ascending: true)
        #expect(depths(entries) == ["p:0", "c:0"])
    }

    @Test func headerIDsNeverCollideWithRowIDs() {
        let entries = BoardTableModel.entries(
            groups: [group("a", [item("a", "A")])],
            showsHeaders: true, collapsed: [], sortKey: nil, ascending: true
        )
        #expect(Set(entries.map(\.id)).count == entries.count)
    }
}
