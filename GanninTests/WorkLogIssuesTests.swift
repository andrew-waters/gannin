import Foundation
import Testing
@testable import Gannin

/// The work log's issue activity (issues opened and comments) and its filter.
struct WorkLogIssuesTests {
    private let day = Date(timeIntervalSince1970: 1_791_000_000)

    private func issue(author: String? = "alex", repo: String = "acme/api", comments: [(String, TimeInterval)] = []) -> WorkLogIssue {
        WorkLogIssue(
            id: "I_1", number: 7, title: "Flaky login", url: URL(string: "https://github.com/\(repo)/issues/7")!, repo: repo,
            author: author, createdAt: day,
            comments: comments.map { WorkLogIssueComment(createdAt: day.addingTimeInterval($0.1), author: $0.0, url: nil) }
        )
    }

    @Test func creditsOpeningToAuthorAndCommentsToCommenters() {
        let events = issue(comments: [("sam", 60), ("alex", 120)]).events
        #expect(events.map(\.kind) == [.issueOpened, .comment, .comment])
        #expect(events.map(\.login) == ["alex", "sam", "alex"])
        #expect(Set(events.map(\.id)).count == events.count)
        #expect(events.allSatisfy { $0.subject.repo == "acme/api" && $0.subject.number == 7 })
    }

    @Test func skipsOpeningWithNoAuthor() {
        let events = issue(author: nil, comments: [("sam", 60)]).events
        #expect(events.map(\.kind) == [.comment])
    }

    @Test func filterHidesKindsAndOtherRepos() {
        let events = issue(comments: [("sam", 60)]).events + issue(repo: "acme/web").events
        let everything = WorkLogFilter()
        #expect(!everything.isActive)
        #expect(events.filter(everything.includes).count == 3)

        let noComments = WorkLogFilter(hiddenKinds: [.comment])
        #expect(events.filter(noComments.includes).map(\.kind) == [.issueOpened, .issueOpened])

        let web = WorkLogFilter(repo: "acme/web")
        #expect(web.isActive)
        #expect(events.filter(web.includes).map(\.subject.repo) == ["acme/web"])
    }

    @Test func hiddenKindsRoundTripThroughStorage() {
        let kinds: Set<WorkLogEvent.Kind> = [.comment, .commit]
        let value = WorkLogFilter.value(of: kinds)
        #expect(value == "Commit,Issue comment")
        #expect(WorkLogFilter.kinds(from: value) == kinds)
        #expect(WorkLogFilter.kinds(from: "Commit,Something else,") == [.commit])
        #expect(WorkLogFilter.kinds(from: "").isEmpty)
    }

    @Test func gridPutsIssueActivityInPeoplesCells() {
        let history = WorkLogHistory(
            orgLogin: "acme", coveredFrom: day.addingTimeInterval(-86_400), fetchedAt: day,
            pullRequests: [:], issues: ["I_1": issue(comments: [("sam", 60)])]
        )
        let start = Calendar.current.startOfDay(for: day)
        let column = WorkLogGrid.Column(start: start, end: start.addingTimeInterval(86_400))
        let people = [Person(login: "alex", name: nil, avatarUrl: nil), Person(login: "sam", name: nil, avatarUrl: nil)]
        let grid = WorkLogGrid(history: history, columns: [column], scale: .days, people: people, config: OrgConfig(), hidden: [])
        #expect(grid.rows.map { $0.cells[start]?.count ?? 0 } == [1, 1])

        let filtered = WorkLogGrid(history: history, columns: [column], scale: .days, people: people, config: OrgConfig(), hidden: [], filter: WorkLogFilter(hiddenKinds: [.issueOpened]))
        #expect(filtered.rows.map { $0.cells[start]?.count ?? 0 } == [0, 1])
    }
}
