import Foundation
import Testing
@testable import Gannin

/// Ending a plan keeps it, finished, and Rituals › Planning ranks it last.
@MainActor
struct EndPlanTests {
    private let folder = FileManager.default.temporaryDirectory.appending(path: "EndPlanTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    private let suite = "EndPlanTests-\(UUID().uuidString)"
    private var defaults: UserDefaults { UserDefaults(suiteName: suite)! }

    private func store() -> SessionStore {
        SessionStore(harness: HarnessStore(auth: AuthStore()), directory: folder, saveDelay: .seconds(60), defaults: defaults)
    }

    private func clean() {
        try? FileManager.default.removeItem(at: folder)
        defaults.removePersistentDomain(forName: suite)
    }

    private func session(planning: PlanningInfo? = nil) -> CodeSession {
        let issue = IssueReference(org: "acme", id: "I_1", number: 1, title: "Issue", repo: "acme/harness",
                                   url: URL(string: "https://github.com/acme/harness/issues/1")!)
        return CodeSession(id: UUID(), issue: issue, repo: "acme/harness", branch: "plan-x", createdAt: .now,
                           harnessRepo: "acme/harness", harnessPath: "~/Code/acme/harness", planning: planning)
    }

    private var info: PlanningInfo { PlanningInfo(topic: "Topic", documentPath: nil, slug: "topic") }

    @Test func endingAPlanArchivesItAndClosesItsTab() {
        defer { clean() }
        let sessions = store()
        let plan = session(planning: info)
        sessions.add(plan)
        sessions.reveal(plan.id)
        #expect(sessions.tabs.contains(plan.id))

        sessions.endPlan(plan.id)

        #expect(sessions.sessions[plan.id]?.archivedAt != nil)
        #expect(!sessions.tabs.contains(plan.id))
    }

    @Test func endingASessionThatIsNotAPlanDoesNothing() {
        defer { clean() }
        let sessions = store()
        let work = session()
        sessions.add(work)

        sessions.endPlan(work.id)

        #expect(sessions.sessions[work.id]?.archivedAt == nil)
    }

    @Test func planningPageRanksUnderWayThenAgreedThenFinished() {
        var underWay = session(planning: info)
        var agreed = session(planning: info)
        agreed.planning?.agreed = PlanningAgreement(at: .now, by: [], planPath: nil, requirementPath: nil, parent: nil, parentURL: nil, issues: [])
        var finished = agreed
        finished.archivedAt = .now
        underWay.archivedAt = nil

        #expect(PlanningPage.rank(underWay) == 0)
        #expect(PlanningPage.rank(agreed) == 1)
        #expect(PlanningPage.rank(finished) == 2)
    }
}
