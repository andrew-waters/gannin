import Foundation
import Testing
@testable import Gannin

/// The work log keeps its issues in `SharedIssueStore`: only coverage and the
/// issue count stay in its own file.
struct WorkLogIssueStoreTests {
    private func at(_ seconds: Double) -> Date { Date(timeIntervalSince1970: 1_791_000_000 + seconds) }

    private func uniqueFolder() -> String { "WorkLogIssueStoreTests-\(UUID().uuidString)" }

    private func directory() -> URL {
        URL.applicationSupportDirectory.appending(path: uniqueFolder(), directoryHint: .isDirectory)
    }

    private func logged(
        _ id: String = "I_1", repo: String = "acme/api", updated: Double? = 10,
        comments: [(String, Double)] = [("sam", 60)]
    ) -> WorkLogIssue {
        WorkLogIssue(
            id: id, number: 7, title: "Flaky login", url: URL(string: "https://github.com/\(repo)/issues/7")!, repo: repo,
            author: "alex", createdAt: at(0),
            comments: comments.map { WorkLogIssueComment(createdAt: at($0.1), author: $0.0, url: nil) },
            closedAt: nil, updatedAt: updated.map(at), assignees: ["sam"], labels: ["bug"]
        )
    }

    private func store(_ directory: URL, issues: SharedIssueStore) -> WorkLogStore {
        WorkLogStore(
            auth: AuthStore(), activity: SyncActivity(), pullRequestStore: PullRequestStore(folder: uniqueFolder()),
            issueStore: issues, directory: directory
        )
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func json(at url: URL) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]) ?? [:]
    }

    private struct Version5File: Encodable {
        var version = 5
        var orgLogin = "acme"
        var coveredFrom: Date
        var fetchedAt: Date
        var storedCount = 0
        var issues: [String: WorkLogIssue]
    }

    // MARK: Storage

    @Test func aVersion5LogMovesItsIssuesIntoTheStoreAndRewritesItsFile() throws {
        let directory = directory()
        let issues = SharedIssueStore(folder: uniqueFolder())
        defer { try? FileManager.default.removeItem(at: directory); issues.clear() }
        let issue = logged(updated: nil)
        let data = try encoder().encode(Version5File(coveredFrom: at(-100), fetchedAt: at(100), issues: ["I_1": issue]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appending(path: "acme.json"))

        let log = store(directory, issues: issues)
        log.loadCached("acme")

        let held = log.history(for: "acme")?.issues["I_1"]
        #expect(held?.title == issue.title && held?.author == issue.author && held?.createdAt == issue.createdAt)
        #expect(held?.comments == issue.comments)
        #expect(issues.issues(org: "acme")["I_1"]?.workLog?.comments == issue.comments)
        let file = json(at: directory.appending(path: "acme.json"))
        #expect(file["version"] as? Int == WorkLogHistory.currentVersion)
        #expect(file["issues"] == nil)
        #expect(file["storedIssueCount"] as? Int == 1)

        // The rewritten file isn't imported again, and reads back from the store.
        let again = store(directory, issues: issues)
        again.loadCached("acme")
        #expect(again.history(for: "acme")?.issues["I_1"]?.comments == issue.comments)
    }

    @Test func aCarriedOverIssueLeavesAHeldCoresListsAlone() {
        let issues = SharedIssueStore(folder: uniqueFolder())
        defer { issues.clear() }
        let person = Person(login: "sam", name: "Sam", avatarUrl: nil)
        // A held core with no `updatedAt`, as an old workload cache has.
        var held = StoredIssue(workLog: logged(updated: nil))
        held.core.assignees = [person]
        held.core.labels = [StoredLabel(name: "bug", color: "d73a4a")]
        held.workLog = nil
        issues.merge([held], org: "acme")

        var carried = logged(updated: nil)
        carried.assignees = nil
        carried.labels = nil
        issues.mergeCarriedOver([StoredIssue(workLog: carried)], org: "acme")

        let after = issues.issues(org: "acme")["I_1"]
        #expect(after?.core.assignees == [person])
        #expect(after?.core.labels == [StoredLabel(name: "bug", color: "d73a4a")])
        #expect(after?.workLog?.comments == carried.comments)
    }

    @Test func theLogsFileKeepsNoIssueFieldsOnceSaved() throws {
        let directory = directory()
        let issues = SharedIssueStore(folder: uniqueFolder())
        defer { try? FileManager.default.removeItem(at: directory); issues.clear() }
        let data = try encoder().encode(Version5File(coveredFrom: at(-100), fetchedAt: at(100), issues: ["I_1": logged()]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appending(path: "acme.json"))
        store(directory, issues: issues).loadCached("acme")

        let text = try String(contentsOf: directory.appending(path: "acme.json"), encoding: .utf8)
        for field in ["Flaky login", "github.com", "acme/api", "alex", "sam"] {
            #expect(!text.contains(field))
        }
    }

    @Test func aLogWhoseIssuesWereClearedFromTheStoreIsDropped() throws {
        let directory = directory()
        let folder = uniqueFolder()
        let issues = SharedIssueStore(folder: folder)
        defer { try? FileManager.default.removeItem(at: directory); issues.clear() }
        let data = try encoder().encode(Version5File(coveredFrom: at(-100), fetchedAt: at(100), issues: ["I_1": logged()]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appending(path: "acme.json"))
        store(directory, issues: issues).loadCached("acme")

        issues.clear()
        issues.flush()
        let log = store(directory, issues: SharedIssueStore(folder: folder))
        log.loadCached("acme")
        #expect(log.history(for: "acme") == nil)
    }

    @Test func clearingTheWorkLogLeavesTheOtherStoresPartsOfAnIssue() {
        let issues = SharedIssueStore(folder: uniqueFolder())
        defer { issues.clear() }
        var stored = StoredIssue(workLog: logged())
        stored.history = HistoryIssueExtras(
            updatedAt: at(10), issueType: nil, milestone: nil, parentID: nil, stateReason: nil, statusChanges: [],
            assignedAt: [], reopenedAt: [], subIssuesAddedAt: [], linkedPullRequests: [], mentionedInPullRequests: nil, projectFields: []
        )
        issues.merge([stored, StoredIssue(workLog: logged("I_2"))], org: "acme")

        issues.clear(.workLog)

        let held = issues.issues(org: "acme")
        #expect(held["I_1"]?.workLog == nil)
        #expect(held["I_1"]?.history != nil)
        #expect(held["I_2"] == nil)
    }

    @Test func aWorkLogFetchKeepsTheAvatarsAndColoursAnotherStoreSaved() {
        let issues = SharedIssueStore(folder: uniqueFolder())
        defer { issues.clear() }
        let person = Person(login: "sam", name: "Sam", avatarUrl: URL(string: "https://github.com/sam.png"))
        let workload = Gannin.Issue(
            id: "I_1", number: 7, title: "Flaky login", url: URL(string: "https://github.com/acme/api/issues/7")!, repo: "acme/api",
            author: nil, state: "OPEN", createdAt: at(0), updatedAt: at(10), closedAt: nil, assignees: [person],
            labels: [IssueLabel(name: "bug", color: "d73a4a")], linkedPullRequests: []
        )
        issues.merge([StoredIssue(workload: workload)], org: "acme")

        issues.merge([StoredIssue(workLog: logged(updated: 10))], org: "acme")

        let held = issues.issues(org: "acme")["I_1"]
        #expect(held?.core.assignees == [person])
        #expect(held?.core.labels == [StoredLabel(name: "bug", color: "d73a4a")])
        #expect(held?.workload != nil)
        #expect(held?.workLog?.comments.count == 1)
    }

    @Test func anOlderWorkLogFetchDoesNotOverwriteANewerCore() {
        let issues = SharedIssueStore(folder: uniqueFolder())
        defer { issues.clear() }
        var renamed = StoredIssue(workLog: logged(updated: 50))
        renamed.core = IssueCore(
            id: "I_1", number: 7, title: "Renamed", url: renamed.core.url, repo: "acme/api", author: nil, createdAt: at(0),
            closedAt: nil, updatedAt: at(50), assignees: [], labels: []
        )
        issues.merge([renamed], org: "acme")

        issues.merge([StoredIssue(workLog: logged(updated: 10))], org: "acme")

        #expect(issues.issues(org: "acme")["I_1"]?.core.title == "Renamed")
    }

    @Test func standupAndActivityReadTheSameEventsFromTheStoreAsFromTheFetch() {
        let fetched = logged(comments: [("sam", 60), ("alex", 120)])
        let held = StoredIssue(workLog: fetched).workLogIssue
        #expect(held?.events.map(\.kind) == fetched.events.map(\.kind))
        #expect(held?.events.map(\.login) == fetched.events.map(\.login))
        #expect(held?.events.map(\.at) == fetched.events.map(\.at))
        #expect(held?.events.map(\.id) == fetched.events.map(\.id))
        #expect(held?.comments == fetched.comments)
    }

    // MARK: Change feed

    private func entry(_ id: String, _ updated: Double, kind: ChangeEntry.Kind = .issue, outside: Bool = false) -> ChangeEntry {
        ChangeEntry(id: id, kind: kind, state: "OPEN", repo: outside ? "client/app" : "acme/api", updatedAt: at(updated), isOutside: outside)
    }

    @Test func theWorkLogTakesTheAccountsOwnIssuesFromTheFeed() {
        let history = WorkLogHistory(orgLogin: "acme", coveredFrom: at(0), fetchedAt: at(30), pullRequests: [:], issues: [
            "held": logged("held", updated: 20), "unknown": logged("unknown", updated: nil),
        ])
        let feed = ChangeFeed(
            entries: Dictionary(uniqueKeysWithValues: [
                entry("held", 20), entry("unknown", 21), entry("fresh", 22), entry("pr", 23, kind: .pullRequest),
                entry("elsewhere", 24, outside: true),
            ].map { ($0.id, $0) }),
            coveredFrom: at(0), lastRunAt: at(30), outsideRepos: ["client/app"]
        )
        guard case .fetch(let entries) = WorkLogStore.issueFeedPlan(feed, cursor: at(10), history: history) else {
            Testing.Issue.record("expected a plan")
            return
        }
        #expect(Set(entries.map(\.id)) == ["unknown", "fresh"])
    }

    @Test func theWorkLogSearchesForIssuesItselfWhenTheFeedCantSay() {
        let history = WorkLogHistory(orgLogin: "acme", coveredFrom: at(0), fetchedAt: at(30), pullRequests: [:])
        let late = ChangeFeed(entries: [:], coveredFrom: at(20), lastRunAt: at(30), outsideRepos: [])
        #expect(WorkLogStore.issueFeedPlan(nil, cursor: at(10), history: history) == .fallback)
        #expect(WorkLogStore.issueFeedPlan(late, cursor: at(10), history: history) == .fallback)
    }

    // MARK: Capped searches

    @Test func aCappedWeekIsSearchedADayAtATime() {
        let week = (from: at(0), to: Optional(at(0).addingTimeInterval(7 * 86_400)))
        let quiet = (from: at(7 * 86_400), to: Optional(at(14 * 86_400)))
        let split = WorkLogStore.splittingCapped([week, quiet], at: [0], now: at(20 * 86_400))
        #expect(split.count == 8)
        #expect(split.last?.from == quiet.from && split.last?.to == quiet.to)
        #expect(split.first?.from == week.from)
        #expect(split.dropLast().allSatisfy { $0.to != nil })
        // Together the days cover the week with no gap or overlap.
        for (a, b) in zip(split.prefix(6), split.dropFirst().prefix(6)) { #expect(a.to == b.from) }
        #expect(split[6].to == week.to)
    }

    @Test func aCappedOpenEndedSearchRunsToNow() {
        let open = (from: at(0), to: Date?.none)
        let split = WorkLogStore.splittingCapped([open], at: [0], now: at(0).addingTimeInterval(3 * 86_400))
        #expect(split.count == 3)
        #expect(split.last?.to == at(0).addingTimeInterval(3 * 86_400))
    }

    @Test func aRangeOfADayOrLessIsLeftAsItIs() {
        let day = (from: at(0), to: Optional(at(0).addingTimeInterval(86_400)))
        let split = WorkLogStore.splittingCapped([day], at: [0], now: at(86_400))
        #expect(split.count == 1 && split[0].from == day.from && split[0].to == day.to)
    }
}
