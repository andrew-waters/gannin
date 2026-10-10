import Foundation
import Testing
@testable import Gannin

/// Triage's priority scheme: the team file, and reading an issue's bucket by
/// label or board field.
struct PrioritySchemeTests {
    private let now = PriorityBucket(name: "Now", slot: 0, githubValue: "priority: now")
    private let next = PriorityBucket(name: "Next", slot: 1, githubValue: "priority: next")
    private let later = PriorityBucket(name: "Later", slot: 2, githubValue: "priority: later")

    private func issue(labels: [String] = [], fields: [IssueProjectFields] = []) -> IssueRecord {
        IssueRecord(
            id: "I_1", number: 1, title: "An issue", url: URL(string: "https://github.com/acme/api/issues/1")!, repo: "acme/api",
            author: "alex", assignees: [], labels: labels, issueType: nil, milestone: nil, parentID: nil,
            createdAt: .now, closedAt: nil, stateReason: nil, statusChanges: [], assignedAt: [], reopenedAt: [],
            subIssuesAddedAt: [], linkedPullRequests: [], mentionedInPullRequests: nil, projectFields: fields
        )
    }

    private func onBoard(_ option: String, field: String = "Priority", project: Int = 7) -> IssueProjectFields {
        IssueProjectFields(projectNumber: project, projectTitle: "Roadmap", values: [field: .option(name: option, position: 0)])
    }

    @Test func readsBucketsByLabel() {
        let scheme = PriorityScheme(buckets: [now, next, later])
        #expect(scheme.reading(issue(labels: ["bug", "Priority: Next"])) == .bucket(next))
        #expect(scheme.reading(issue(labels: ["bug"])) == .untriaged)
        #expect(scheme.reading(issue()).isUntriaged)
    }

    @Test func labelsOfTwoBucketsConflict() {
        let scheme = PriorityScheme(buckets: [now, next, later])
        let reading = scheme.reading(issue(labels: ["priority: later", "priority: now"]))
        #expect(reading == .conflicting([now, later]))
        #expect(reading.isConflicting)
        #expect(reading.needsTriage)
        #expect(reading.assigned == nil)
    }

    @Test func readsBucketsByBoardField() {
        let buckets = [
            PriorityBucket(name: "Now", slot: 0, githubValue: "Now"),
            PriorityBucket(name: "Next", slot: 1, githubValue: "Next"),
        ]
        let scheme = PriorityScheme(buckets: buckets, tracking: .projectField(projectNumber: 7, projectTitle: "Roadmap", field: "Priority"))
        #expect(scheme.reading(issue(fields: [onBoard("next", field: "priority")])) == .bucket(buckets[1]))
        // Another board, another field, or an option no bucket has: untriaged.
        #expect(scheme.reading(issue(fields: [onBoard("Now", project: 8)])) == .untriaged)
        #expect(scheme.reading(issue(fields: [onBoard("Now", field: "Status")])) == .untriaged)
        #expect(scheme.reading(issue(fields: [onBoard("Someday")])) == .untriaged)
        // Labels don't count when the board field is what's tracked.
        #expect(scheme.reading(issue(labels: ["Now"])) == .untriaged)
    }

    @Test func anEmptyValueNeverMatches() {
        let scheme = PriorityScheme(buckets: [PriorityBucket(name: "Half made", slot: 3, githubValue: ""), now])
        #expect(scheme.reading(issue(labels: [""])) == .untriaged)
        #expect(scheme.githubValues == ["priority: now"])
    }

    @Test func travelsInTheTeamFileWithKeysSorted() throws {
        var before = OrgConfig()
        before.committedDateField = "Committed"
        var after = before
        after.priorityScheme = PriorityScheme(
            buckets: [now, next], tracking: .labels,
            lastPass: Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 10))
        )
        let files = HarnessTeamData.changedFiles(from: before, to: after)
        #expect(files.keys.sorted() == [TeamFile.triage])
        let text = try #require(files[TeamFile.triage] ?? nil)
        #expect(text.contains(#""lastPass" : "2026-10-10""#))
        let keys = ["buckets", "lastPass", "tracking"].map { text.range(of: "\"\($0)\"")?.lowerBound }
        #expect(keys.allSatisfy { $0 != nil })
        #expect(keys.compactMap { $0 } == keys.compactMap { $0 }.sorted())

        let read = HarnessTeamData(files: [TeamFile.triage: text]).appliedProject(to: OrgConfig())
        #expect(read.priorityScheme == after.priorityScheme)

        // Taking it away removes the file.
        let removed = HarnessTeamData.changedFiles(from: after, to: before)
        #expect(removed[TeamFile.triage] == .some(nil))
        #expect(TeamFile.name(TeamFile.triage) == "the priority scheme")
        #expect(!TeamFile.isOrgWide(TeamFile.triage))
    }

    @Test func readsAFileWrittenByHand() throws {
        let text = """
        {
          "buckets": [{ "name": "Now" }, { "name": "Later", "githubValue": "later", "slot": 2 }],
          "tracking": { "somethingNew": {} }
        }
        """
        let scheme = try #require(TeamCoding.decode(PriorityScheme.self, text))
        #expect(scheme.tracking == .labels)
        #expect(scheme.lastPass == nil)
        #expect(scheme.buckets.map(\.name) == ["Now", "Later"])
        #expect(scheme.buckets.map(\.githubValue) == ["Now", "later"])
        #expect(scheme.buckets.map(\.slot) == [0, 2])

        let board = try #require(TeamCoding.decode(PriorityScheme.self, #"{"tracking":{"projectField":{"projectNumber":3,"projectTitle":"Roadmap","field":"Horizon"}}}"#))
        #expect(board.tracking == .projectField(projectNumber: 3, projectTitle: "Roadmap", field: "Horizon"))
        #expect(board.buckets.isEmpty)
    }

    @Test func olderSettingsStillLoad() throws {
        let config = try JSONDecoder().decode(OrgConfig.self, from: Data(#"{"excludedRepos":[]}"#.utf8))
        #expect(config.priorityScheme == nil)
        #expect(config.isEmpty)
    }
}
