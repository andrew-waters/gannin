import Foundation
import Testing
@testable import Gannin

struct BoardTableColumnTests {
    private func item(_ title: String, values: [String: IssueFieldValue] = [:]) -> BoardItem {
        BoardItem(id: title, kind: .issue, contentID: nil, title: title, number: nil, url: nil, repo: nil, state: nil,
                  assignees: [], labels: [], milestone: nil, parent: nil, subIssuesProgress: nil,
                  linkedPullRequests: 0, updatedAt: nil, values: values)
    }

    @Test func titleColumnComesFirstAndIsNotRepeated() {
        let columns = BoardTableColumn.columns(visibleFields: ["Status", "title", "Assignees"])
        #expect(columns.map(\.id) == ["title", "Status", "Assignees"])
        #expect(columns[0].width == nil)
    }

    @Test func fieldColumnsAreSizedByField() {
        #expect(BoardTableColumn(field: "Assignees").width == 90)
        #expect(BoardTableColumn(field: "Labels").width == 220)
        #expect(BoardTableColumn(field: "Parent issue").width == 200)
        #expect(BoardTableColumn(field: "Status").width == 140)
    }

    @Test func titleSortsCaseInsensitively() {
        #expect(BoardTableColumn.title.sortKey(item("Banana")) == .text("banana"))
    }

    @Test func fieldSortKeyReadsTheItemsValue() {
        let column = BoardTableColumn(field: "Size")
        #expect(column.sortKey(item("a", values: ["Size": .number(3)])) == .number(3))
        #expect(column.sortKey(item("a", values: ["Size": .text("Big")])) == .text("big"))
    }

    @Test func emptyValuesSortLast() {
        let column = BoardTableColumn(field: "Size")
        #expect(column.sortKey(item("a", values: ["Size": .text("zzz")])) < column.sortKey(item("b")))
    }
}
