import Foundation
import Testing
@testable import Gannin

/// A review workflow run moved on by the store (andrew-waters/gannin#493):
/// one-shot steps starting, the automatic cap, a step's session closed, and
/// a run picked up after a relaunch.
@MainActor
struct ReviewRunStoreTests {
    private let folder = FileManager.default.temporaryDirectory.appending(path: "ReviewRunStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)

    private func store() -> SessionStore {
        SessionStore(harness: HarnessStore(auth: AuthStore()), directory: folder, saveDelay: .milliseconds(500))
    }

    private func clean() { try? FileManager.default.removeItem(at: folder) }

    private let pr = PullRequestReference(org: "acme", id: "PR_1", number: 7, title: "Tidy", repo: "acme/api", url: URL(string: "https://github.com/acme/api/pull/7")!)

    private func lead(_ steps: (UUID) -> [ReviewStepRun]) -> CodeSession {
        let id = UUID()
        var session = CodeSession(
            id: id, issue: IssueReference(org: "acme", id: pr.id, number: pr.number, title: pr.title, repo: pr.repo, url: pr.url),
            repo: "acme/harness", branch: SessionStore.reviewBranch(pr), createdAt: .now, pullRequests: [pr.url],
            harnessRepo: "acme/harness", harnessPath: "~/Code/acme/does-not-exist", role: "Review", isReviewer: true, reviewOf: pr
        )
        session.reviewRun = ReviewRun(workflowID: "w", workflowName: "W", steps: steps(id))
        return session
    }

    private func step(_ id: String, stage: Int = 0, provider: String = "claude-code", session: UUID? = nil, state: ReviewStepRun.State = .waiting) -> ReviewStepRun {
        var step = ReviewStepRun(id: id, stage: stage, title: id, provider: provider, rounds: 1, session: session)
        step.state = state
        return step
    }

    @Test func aOneShotStepStartsRatherThanBeingSkipped() throws {
        defer { clean() }
        let sessions = store()
        let made = lead { [step("lead", session: $0, state: .running), step("junie", provider: "junie")] }
        sessions.add(made)
        sessions.advanceRun(made.id)
        let junie = try #require(sessions.sessions[made.id]?.reviewRun?.steps[1])
        #expect(junie.state == .running)
        #expect(junie.run != nil)
        #expect(junie.note == nil)
    }

    @Test func aLeadWhoseStepIsDoneHoldsNoSlot() {
        defer { clean() }
        let sessions = store()
        let helper = UUID()
        let made = lead { [step("lead", session: $0, state: .done), step("other", session: helper, state: .running)] }
        sessions.add(made)
        sessions.automaticRuns.insert(made.id)
        sessions.automaticStartedAt[made.id] = .now
        // The helper's step counts; the lead, done with its own, doesn't.
        #expect(sessions.automaticReviewsRunning == 1)
    }

    @Test func closingAStepsSessionMarksItNotRun() throws {
        defer { clean() }
        let sessions = store()
        let helperID = UUID()
        let made = lead { [step("lead", session: $0, state: .running), step("other", session: helperID, state: .running)] }
        sessions.add(made)
        var helper = CodeSession(id: helperID, issue: made.issue, repo: made.repo, branch: made.branch, createdAt: .now,
                                 harnessRepo: made.harnessRepo, harnessPath: made.harnessPath, parentID: made.id, role: "other", isReviewer: true)
        helper.reviewStep = ReviewStepReference(lead: made.id, step: "other")
        sessions.add(helper)
        sessions.remove(helperID)
        let other = try #require(sessions.sessions[made.id]?.reviewRun?.steps[1])
        #expect(other.state == .skipped)
        #expect(other.note == "its session was closed")
        #expect(sessions.sessions[made.id]?.reviewRun?.finishedAt == nil)
    }

    @Test func aRunLeftByAQuitIsPickedUp() throws {
        defer { clean() }
        let sessions = store()
        let made = lead { id in
            var first = step("lead", session: id, state: .done)
            first.results = [SessionTranscript.ReviewResult(summary: "Fine.", verdict: "approve", findings: [])]
            return [first, step("junie", provider: "junie", state: .running)]
        }
        sessions.add(made)
        sessions.resumeReviewRuns()
        let run = try #require(sessions.sessions[made.id]?.reviewRun)
        #expect(run.steps[1].state == .skipped)
        #expect(run.steps[1].note == "Gannin quit while it ran")
        #expect(run.finishedAt != nil)
        #expect(sessions.sessions[made.id]?.reviewResult?.summary.contains("Not run: junie (Gannin quit while it ran).") == true)
    }
}
