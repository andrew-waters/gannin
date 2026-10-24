import Foundation
import Testing
@testable import Gannin

/// Standup's board: which stage a status falls in, what each column holds,
/// triage matching Prioritisation's, and the team file.
struct StandupStagesTests {
    private let board = 7
    private let since = Date(timeIntervalSince1970: 1_000_000)

    private func issue(
        _ number: Int, status: String? = nil, onBoard: Bool = true, assignees: [String] = [], labels: [String] = [],
        created: Date? = nil, closed: Date? = nil, completed: Bool = true, moves: [(String, Date)] = [], position: Int = 0
    ) -> IssueRecord {
        var values: [String: IssueFieldValue] = [:]
        if let status { values["Status"] = .option(name: status, position: position) }
        return IssueRecord(
            id: "I_\(number)", number: number, title: "Issue \(number)", url: URL(string: "https://github.com/acme/api/issues/\(number)")!, repo: "acme/api",
            author: "alex", assignees: assignees, labels: labels, issueType: nil, milestone: nil, parentID: nil,
            createdAt: created ?? since.addingTimeInterval(-86_400 * 10), closedAt: closed, stateReason: closed == nil ? nil : completed ? "COMPLETED" : "NOT_PLANNED",
            statusChanges: moves.map { IssueStatusChange(at: $0.1, status: $0.0, projectNumber: board, projectTitle: "Work") },
            assignedAt: [], reopenedAt: [], subIssuesAddedAt: [], linkedPullRequests: [], mentionedInPullRequests: nil,
            projectFields: onBoard ? [IssueProjectFields(projectNumber: board, projectTitle: "Work", values: values)] : []
        )
    }

    private func config(_ standup: StandupConfig? = nil) -> OrgConfig {
        var config = OrgConfig()
        config.issueWorkflow = IssueWorkflow(projectNumber: board, inProgressStatuses: ["Doing it"])
        config.standup = standup
        return config
    }

    @Test func guessesStagesFromNames() {
        let workflow = IssueWorkflow(inProgressStatuses: ["Building", "In Review"])
        #expect(StandupConfig.guess("Done", workflow: workflow) == .done)
        #expect(StandupConfig.guess("Shipped 🚀", workflow: workflow) == .done)
        // Review before in progress, though it counts for cycle time.
        #expect(StandupConfig.guess("In Review", workflow: workflow) == .review)
        #expect(StandupConfig.guess("Building", workflow: workflow) == .progress)
        #expect(StandupConfig.guess("In progress", workflow: workflow) == .progress)
        #expect(StandupConfig.guess("Backlog", workflow: workflow) == .hidden)
    }

    @Test func theTeamsChoiceWins() {
        let standup = StandupConfig(stages: ["QA": .review, "Done": .hidden])
        let workflow = IssueWorkflow()
        #expect(standup.stage(for: "qa", workflow: workflow) == .review)
        #expect(standup.stage(for: "Done", workflow: workflow) == .hidden)
        #expect(standup.stage(for: "In progress", workflow: workflow) == .progress)
    }

    @Test func columnsFollowTheBoard() {
        let issues = [
            issue(1, status: "In Review", moves: [("In Review", since.addingTimeInterval(-3600))], position: 2),
            issue(2, status: "In Review", moves: [("In Review", since.addingTimeInterval(-7200))], position: 2),
            issue(3, status: "Doing it", position: 1),
            issue(4, status: "Backlog"),
            issue(5),
            issue(6, onBoard: false),
        ]
        let standup = StandupBoard(issues: issues, board: board, config: config(), since: since)
        // The longest in review first.
        #expect(standup.items(.review).map(\.record.number) == [2, 1])
        #expect(standup.items(.progress).map(\.record.number) == [3])
        #expect(standup.items(.triage).map(\.record.number).sorted() == [5, 6])
        #expect(standup.items(.triage).first { $0.record.number == 6 }?.isOnBoard == false)
        #expect(standup.items(.done).isEmpty)
    }

    @Test func doneIsWhatChangedSince() {
        let issues = [
            issue(1, closed: since.addingTimeInterval(3600)),
            issue(2, closed: since.addingTimeInterval(-3600)),
            issue(3, closed: since.addingTimeInterval(3600), completed: false),
            issue(4, status: "Done", moves: [("Done", since.addingTimeInterval(7200))]),
            issue(5, status: "Done", moves: [("Done", since.addingTimeInterval(-86_400))]),
        ]
        let standup = StandupBoard(issues: issues, board: board, config: config(), since: since)
        // Newest first; closed before, not planned and old Done left out.
        #expect(standup.items(.done).map(\.record.number) == [4, 1])
    }

    @Test func discussionComesFirstAndStaysInItsColumn() {
        let issues = [
            issue(1, status: "In progress", labels: ["Needs Discussion"]),
            issue(2, labels: ["needs discussion"]),
            issue(3, status: "In progress", labels: ["talk"]),
            issue(4, labels: ["needs discussion"], closed: since.addingTimeInterval(60)),
        ]
        let standup = StandupBoard(issues: issues, board: board, config: config(), since: since)
        #expect(standup.discussion.map(\.record.number).sorted() == [1, 2])
        #expect(standup.items(.progress).map(\.record.number).sorted() == [1, 3])
        #expect(standup.items(.progress).first { $0.record.number == 1 }?.needsDiscussion == true)
        #expect(standup.items(.triage).map(\.record.number) == [2])
        #expect(standup.count(.done) == 3)

        let own = StandupBoard(issues: issues, board: board, config: config(StandupConfig(discussionLabel: "talk")), since: since)
        #expect(own.discussion.map(\.record.number) == [3])
    }

    @Test func triageIsPrioritisations() {
        let issues = [
            issue(1, created: since.addingTimeInterval(-60)),
            issue(2, onBoard: false, created: since),
            issue(3, status: "Backlog"),
            issue(4, closed: since),
            issue(5, assignees: ["sam"], created: since.addingTimeInterval(-120)),
        ]
        let config = config()
        let counted = TriageQueue.counted(issues, config: config, hidden: ["I_1"], team: Team(id: "T", slug: "app", name: "App", members: ["kim"]))
        // Hidden and the other team's left out; newest first.
        #expect(TriageQueue.untriaged(counted, board: board).map(\.number) == [2])
        let standup = StandupBoard(issues: counted, board: board, config: config, since: since)
        #expect(standup.items(.triage).map(\.record.number) == TriageQueue.untriaged(counted, board: board).map(\.number))
        #expect(TriageQueue.untriaged(issues, board: board).map(\.number) == [2, 1, 5])
    }

    @Test func narrowsToOnePerson() {
        let issues = [
            issue(1, status: "In progress", assignees: ["kim"]),
            issue(2, status: "In progress", assignees: ["sam"]),
            issue(3, assignees: ["kim", "sam"]),
        ]
        let kim = StandupBoard(issues: issues, board: board, config: config(), since: since).assigned(to: "kim")
        #expect(kim.items(.progress).map(\.record.number) == [1])
        #expect(kim.items(.triage).map(\.record.number) == [3])
        #expect(!kim.isEmpty)
    }

    @Test func travelsInTheTeamFile() throws {
        let before = OrgConfig()
        var after = before
        after.standup = StandupConfig(style: .people, stages: ["QA": .review], discussionLabel: "discuss")
        let files = HarnessTeamData.changedFiles(from: before, to: after)
        #expect(files.keys.sorted() == [TeamFile.standup])
        let text = try #require(files[TeamFile.standup] ?? nil)
        let read = HarnessTeamData(files: [TeamFile.standup: text]).appliedProject(to: OrgConfig())
        #expect(read.standup == after.standup)
        #expect(!TeamFile.isOrgWide(TeamFile.standup))
        #expect(HarnessTeamData.changedFiles(from: after, to: before)[TeamFile.standup] == .some(nil))
    }

    @Test func readsLeniently() throws {
        let standup = try #require(TeamCoding.decode(StandupConfig.self, #"{"style":"huddle","stages":{"QA":"review","Odd":"sideways"},"discussionLabel":"  "}"#))
        #expect(standup.style == nil)
        #expect(standup.openingStyle == .board)
        #expect(standup.stages == ["QA": .review])
        #expect(standup.discussion == StandupConfig.defaultDiscussionLabel)
        let config = try JSONDecoder().decode(OrgConfig.self, from: Data(#"{"excludedRepos":[]}"#.utf8))
        #expect(config.standup == nil)
        #expect(config.isEmpty)
    }
}
