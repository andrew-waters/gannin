import Foundation
import Testing
@testable import Gannin

struct SharedIssueStoreTests {
    private func at(_ seconds: Double) -> Date { Date(timeIntervalSince1970: 1_760_000_000 + seconds) }

    private let folder = "SharedIssueStoreTests-\(UUID().uuidString)"

    private func record(
        _ id: String = "a", updated: Double? = 10, labels: [String] = ["bug"], assignees: [String] = ["kim"],
        statusChanges: [IssueStatusChange] = [], closedAt: Date? = nil
    ) -> IssueRecord {
        IssueRecord(
            id: id, number: 3, title: "Issue \(id)", url: URL(string: "https://github.com/acme/api/issues/3")!, repo: "acme/api",
            author: "sam", assignees: assignees, labels: labels, issueType: "Bug", milestone: "v1", parentID: "p",
            createdAt: at(0), closedAt: closedAt, stateReason: closedAt.map { _ in "COMPLETED" }, statusChanges: statusChanges,
            assignedAt: [at(1)], reopenedAt: [at(2)], subIssuesAddedAt: [at(3)],
            linkedPullRequests: [IssueLinkedPullRequest(number: 7, url: URL(string: "https://github.com/acme/api/pull/7")!, createdAt: at(4), mergedAt: nil, state: "OPEN", repo: nil, activityAt: [at(5)])],
            mentionedInPullRequests: nil,
            projectFields: [IssueProjectFields(projectNumber: 1, projectTitle: "Board", values: ["Status": .option(name: "Todo", position: 0)])],
            updatedAt: updated.map(at)
        )
    }

    private func workload(_ id: String = "a", updated: Double = 10, labels: [IssueLabel] = [IssueLabel(name: "bug", color: "d73a4a")]) -> Gannin.Issue {
        Gannin.Issue(
            id: id, number: 3, title: "Issue \(id)", url: URL(string: "https://github.com/acme/api/issues/3")!, repo: "acme/api",
            author: Person(login: "sam", name: "Sam Jones", avatarUrl: URL(string: "https://example.com/sam.png")),
            state: "OPEN", createdAt: at(0), updatedAt: at(updated), closedAt: nil,
            assignees: [Person(login: "kim", name: "Kim", avatarUrl: URL(string: "https://example.com/kim.png"))],
            labels: labels, linkedPullRequests: []
        )
    }

    @Test func everyFieldOfAnIssueRecordRoundTripsThroughTheStore() {
        let original = record(statusChanges: [IssueStatusChange(at: at(6), status: "Done", projectNumber: 1, projectTitle: "Board")])
        #expect(StoredIssue(history: original).issueRecord == original)
        let closed = record(closedAt: at(9))
        #expect(StoredIssue(history: closed).issueRecord == closed)
    }

    @Test func aWorkloadAndAHistoryFetchOfTheSameIssueShareOneCopy() {
        let store = SharedIssueStore(folder: folder)
        defer { store.clear() }
        store.merge([StoredIssue(workload: workload())], org: "acme")
        store.merge([StoredIssue(history: record())], org: "acme")

        #expect(store.issues(org: "acme").count == 1)
        let held = store.issues(org: "acme")["a"]!
        #expect(held.workload != nil)
        #expect(held.history != nil)
    }

    @Test func aHistoryFetchKeepsTheAvatarsAndLabelColoursOnlyTheWorkloadFetchReads() {
        let store = SharedIssueStore(folder: folder)
        defer { store.clear() }
        let original = workload()
        store.merge([StoredIssue(workload: original)], org: "acme")
        store.merge([StoredIssue(history: record(updated: 20))], org: "acme")

        let held = store.issues(org: "acme")["a"]!
        #expect(held.core.author == original.author)
        #expect(held.core.assignees == original.assignees)
        #expect(held.core.labels == [StoredLabel(name: "bug", color: "d73a4a")])
        // The workload's own part is as it was fetched.
        #expect(held.workloadIssue?.assignees == original.assignees)
    }

    @Test func aLabelOnlyTheHistoryHasSeenGetsTheDefaultColourInTheWorkload() {
        let store = SharedIssueStore(folder: folder)
        defer { store.clear() }
        store.merge([StoredIssue(workload: workload())], org: "acme")
        store.merge([StoredIssue(history: record(updated: 20, labels: ["bug", "new"]))], org: "acme")
        // The workload part stays at its fetch; an edit that reaches the core shows on the next load.
        store.merge([StoredIssue(workload: workload(updated: 20, labels: [IssueLabel(name: "bug", color: "d73a4a")]))], org: "acme")

        let labels = store.issues(org: "acme")["a"]!.workloadIssue?.labels
        #expect(labels?.map(\.name) == ["bug"])
    }

    @Test func aFetchOlderThanTheHeldCoreDoesNotOverwriteIt() {
        let store = SharedIssueStore(folder: folder)
        defer { store.clear() }
        store.merge([StoredIssue(history: record(updated: 30, labels: ["new"]))], org: "acme")
        store.merge([StoredIssue(workload: workload(updated: 10))], org: "acme")

        let held = store.issues(org: "acme")["a"]!
        #expect(held.core.labels.map(\.name) == ["new"])
        #expect(held.core.updatedAt == at(30))
        #expect(held.workload?.updatedAt == at(10))
    }

    @Test func aStoreSkipsOnItsOwnPartsUpdatedAtNotTheCores() {
        let store = SharedIssueStore(folder: folder)
        defer { store.clear() }
        store.merge([StoredIssue(history: record(updated: 10))], org: "acme")
        store.merge([StoredIssue(workload: workload(updated: 30))], org: "acme")

        let held = store.issues(org: "acme")["a"]!
        #expect(held.core.updatedAt == at(30))
        #expect(held.history?.updatedAt == at(10))
    }

    @Test func anEditAtTheSameUpdatedAtReplacesTheHistoryPart() {
        let store = SharedIssueStore(folder: folder)
        defer { store.clear() }
        store.merge([StoredIssue(history: record())], org: "acme")
        store.merge([StoredIssue(history: record(labels: ["bug", "edited"]))], org: "acme")
        #expect(store.issues(org: "acme")["a"]?.issueRecord?.labels == ["bug", "edited"])
    }

    @Test func pruningAPartKeepsTheOtherAndDropsAnIssueLeftWithNone() {
        let store = SharedIssueStore(folder: folder)
        defer { store.clear() }
        store.merge([StoredIssue(workload: workload("a")), StoredIssue(workload: workload("b"))], org: "acme")
        store.merge([StoredIssue(history: record("a"))], org: "acme")

        store.prune(.workload, org: "acme", keeping: [])
        let held = store.issues(org: "acme")
        #expect(held["a"]?.workload == nil)
        #expect(held["a"]?.history != nil)
        #expect(held["b"] == nil)
    }

    @Test func clearingOnePartLeavesTheOtherInEveryOrg() {
        let store = SharedIssueStore(folder: folder)
        defer { store.clear() }
        store.merge([StoredIssue(workload: workload())], org: "acme")
        store.merge([StoredIssue(history: record())], org: "acme")
        store.clear(.history)
        #expect(store.issues(org: "acme")["a"]?.history == nil)
        #expect(store.issues(org: "acme")["a"]?.workload != nil)
    }

    @Test func issuesSurviveBeingReadBackFromDisk() {
        let store = SharedIssueStore(folder: folder)
        defer { store.clear() }
        store.merge([StoredIssue(workload: workload()), StoredIssue(history: record("b"))], org: "acme")
        let reread = SharedIssueStore(folder: folder)
        #expect(reread.issues(org: "acme") == store.issues(org: "acme"))
    }

    @Test func aHistoryFileHoldsNoIssuesAndAnOldOneStillDecodes() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var history = IssueHistory(orgLogin: "acme", coveredFrom: at(0), syncedAt: at(1), openFetchedAt: at(1), issues: ["a": record()])
        history.storedIDs = ["a"]
        let data = try encoder.encode(history)
        #expect((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["issues"] == nil)
        #expect((try? decoder.decode(IssueHistory.Legacy.self, from: data)) == nil)

        struct OldFile: Encodable {
            var version = 1
            var orgLogin = "acme"
            var coveredFrom: Date
            var syncedAt: Date
            var openFetchedAt: Date
            var issues: [String: IssueRecord]
        }
        let old = try encoder.encode(OldFile(coveredFrom: at(0), syncedAt: at(1), openFetchedAt: at(1), issues: ["a": record()]))
        #expect(try decoder.decode(IssueHistory.Legacy.self, from: old).issues["a"] == record())
        #expect(try decoder.decode(IssueHistory.self, from: old).storedIDs == nil)
    }

    // MARK: IssueStore.loadCached

    private func issueStore(_ shared: SharedIssueStore, _ directory: URL) -> IssueStore {
        IssueStore(auth: AuthStore(), activity: SyncActivity(), issueStore: shared, directory: directory)
    }

    private func writeOldHistory(_ records: [IssueRecord], to directory: URL) throws {
        struct OldFile: Encodable {
            var version = 1
            var orgLogin = "acme"
            var coveredFrom: Date
            var syncedAt: Date
            var openFetchedAt: Date
            var issues: [String: IssueRecord]
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = OldFile(coveredFrom: at(0), syncedAt: at(1), openFetchedAt: at(1), issues: Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) }))
        try encoder.encode(file).write(to: directory.appending(path: "acme.json"))
    }

    @Test func aHistoryFromBeforeTheStoreMovesItsIssuesIntoItAndIsRewrittenWithoutThem() throws {
        let directory = URL.applicationSupportDirectory.appending(path: "SharedIssueStoreTests-dir-\(UUID().uuidString)", directoryHint: .isDirectory)
        let shared = SharedIssueStore(folder: folder)
        defer { try? FileManager.default.removeItem(at: directory); shared.clear() }
        let records = [record("a"), record("b", closedAt: at(9))]
        try writeOldHistory(records, to: directory)

        let store = issueStore(shared, directory)
        store.loadCached("acme")
        #expect(store.history(for: "acme")?.issues == Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) }))
        #expect(shared.issues(org: "acme")["a"]?.history != nil)
        let rewritten = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appending(path: "acme.json"))) as? [String: Any]
        #expect(rewritten?["issues"] == nil)

        // A fresh launch reads the rewritten file and the store.
        let again = issueStore(SharedIssueStore(folder: folder), directory)
        again.loadCached("acme")
        #expect(again.history(for: "acme")?.issues.count == 2)
        #expect(again.history(for: "acme")?.issues["a"] == records[0])
    }

    @Test func aHistoryWhoseIssueStoreWasClearedIsDroppedSoItFetchesAgain() throws {
        let directory = URL.applicationSupportDirectory.appending(path: "SharedIssueStoreTests-dir-\(UUID().uuidString)", directoryHint: .isDirectory)
        let shared = SharedIssueStore(folder: folder)
        defer { try? FileManager.default.removeItem(at: directory); shared.clear() }
        try writeOldHistory([record("a")], to: directory)
        issueStore(shared, directory).loadCached("acme")
        shared.clear()

        let store = issueStore(SharedIssueStore(folder: folder), directory)
        store.loadCached("acme")
        #expect(store.history(for: "acme") == nil)
    }

    @Test func anEditIsKeptInTheStoreAndShownByTheNextLoad() throws {
        let directory = URL.applicationSupportDirectory.appending(path: "SharedIssueStoreTests-dir-\(UUID().uuidString)", directoryHint: .isDirectory)
        let shared = SharedIssueStore(folder: folder)
        defer { try? FileManager.default.removeItem(at: directory); shared.clear() }
        try writeOldHistory([record("a")], to: directory)
        let store = issueStore(shared, directory)
        store.loadCached("acme")
        store.recordLabels(org: "acme", issueID: "a", labels: ["bug", "edited"])
        store.recordFieldValue(org: "acme", issueID: "a", projectNumber: 1, projectTitle: "Board", field: "Status", value: .option(name: "Done", position: 2))

        let again = issueStore(SharedIssueStore(folder: folder), directory)
        again.loadCached("acme")
        let reloaded = again.history(for: "acme")?.issues["a"]
        #expect(reloaded?.labels == ["bug", "edited"])
        #expect(reloaded?.fields(onProject: 1)?.values["Status"] == .option(name: "Done", position: 2))
    }
}
