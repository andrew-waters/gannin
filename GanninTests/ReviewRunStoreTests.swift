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

    @Test func aReviewRunLeavesCommandStepsOutAndAddsGanninsOwnWhenTheFirstStageHasNoAgent() throws {
        defer { clean() }
        let workflow = AgentWorkflow(id: "w", name: "W", stages: [
            AgentStage(steps: [AgentStep(id: "t", command: "npm test")]),
            AgentStage(steps: [AgentStep(id: "r", specialist: "sec")]),
        ])
        let run = try #require(store().reviewRun(for: workflow, org: "acme", setup: HarnessConfig(repo: "acme/harness")))
        #expect(run.steps.map(\.id) == [AgentWorkflow.builtInID, "r"])
        #expect(run.steps.map(\.stage) == [0, 1])
        // The run makes the passes the editor counts.
        #expect(run.steps.reduce(0) { $0 + $1.rounds } == PassCount.of(workflow, specialists: [:], defaultModel: nil, activity: .review).reduce(0) { $0 + $1.passes })
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

    @Test func anAutomaticRunIsAutomaticAgainAfterAQuit() throws {
        defer { clean() }
        let sessions = store()
        var made = lead { [step("lead", session: $0, state: .done), step("next")] }
        made.reviewRun?.automatic = true
        sessions.add(made)
        // Two other automatic reviews just started fill the cap.
        for _ in 0..<AutoReview.maxRunning {
            let other = UUID()
            sessions.automaticRuns.insert(other)
            sessions.automaticStartedAt[other] = .now
        }
        sessions.resumeReviewRuns()
        #expect(sessions.automaticRuns.contains(made.id))
        // Capped, so its next step waits for a slot.
        #expect(sessions.sessions[made.id]?.reviewRun?.steps[1].state == .waiting)
    }

    private func result(_ summary: String, verdict: String = "comment", finding: String? = nil, line: Int = 3) -> SessionTranscript.ReviewResult {
        SessionTranscript.ReviewResult(
            summary: summary, verdict: verdict,
            findings: finding.map { [SessionTranscript.Finding(path: "a.swift", line: line, comment: $0)] } ?? []
        )
    }

    @Test func theLeadsOwnRoundReadAgainDoesNotReplaceAFinishedRunsResult() throws {
        defer { clean() }
        let sessions = store()
        let round = result("Lead.", finding: "From the lead.")
        let made = lead { id in
            var first = step("lead", session: id, state: .done)
            first.results = [round]
            var second = step("other", session: UUID(), state: .done)
            second.results = [result("Other.", finding: "From the other.", line: 9)]
            return [first, second]
        }
        sessions.add(made)
        sessions.advanceRun(made.id)
        let merged = try #require(sessions.sessions[made.id]?.reviewResult)
        #expect(merged.findings.count == 2)

        // The lead's transcript is read again: its own round isn't the review.
        sessions.keepReview(round, for: made.id)
        #expect(sessions.sessions[made.id]?.reviewResult == merged)

        // Look Again gives a different review, which does replace the run's.
        let again = result("Again.", verdict: "approve")
        sessions.keepReview(again, for: made.id)
        #expect(sessions.sessions[made.id]?.reviewResult == again)
    }

    @Test func theReviewShownForAFinishedRunIsTheMergedOneUntilLookAgain() throws {
        defer { clean() }
        let sessions = store()
        let round = result("Lead.", finding: "From the lead.")
        let made = lead { id in
            var first = step("lead", session: id, state: .done)
            first.results = [round]
            var second = step("other", session: UUID(), state: .done)
            second.results = [result("Other.", finding: "From the other.", line: 9)]
            return [first, second]
        }
        sessions.add(made)
        sessions.advanceRun(made.id)
        let merged = try #require(sessions.sessions[made.id]?.reviewResult)

        func transcript(replying review: SessionTranscript.ReviewResult) throws -> SessionTranscript {
            var transcript = SessionTranscript()
            transcript.lastReply = "```json\n" + String(decoding: try JSONEncoder().encode(review), as: UTF8.self) + "\n```"
            return transcript
        }

        // The lead's transcript still ends with its own round.
        sessions.transcripts[made.id] = try transcript(replying: round)
        #expect(sessions.transcripts[made.id]?.review == round)
        #expect(sessions.currentReview(of: made.id) == merged)
        #expect(sessions.currentReview(of: made.id)?.findings.count == 2)

        // A review from Look Again isn't a round of the run.
        let again = result("Again.", verdict: "approve")
        sessions.transcripts[made.id] = try transcript(replying: again)
        #expect(sessions.currentReview(of: made.id) == again)
    }

    @Test func aLeadsSecondRoundAddsToTheFirstAndNeitherReplacesTheMergedResult() throws {
        defer { clean() }
        let sessions = store()
        let first = result("Round 1.", finding: "First round.", line: 3)
        let second = result("Round 2.", finding: "Second round.", line: 5)
        let made = lead { id in
            var lead = step("lead", session: id, state: .done)
            lead.rounds = 2
            lead.results = [first, second]
            return [lead]
        }
        sessions.add(made)
        sessions.advanceRun(made.id)
        let merged = try #require(sessions.sessions[made.id]?.reviewResult)
        #expect(Set(merged.findings.map(\.comment)) == ["First round.", "Second round."])

        // The transcript reports the latest round when it's read again.
        sessions.keepReview(second, for: made.id)
        #expect(sessions.sessions[made.id]?.reviewResult == merged)
    }

    @Test func aLaterStageStartsOnceTheEarlierOneFinishesAndSeesItsFindings() throws {
        defer { clean() }
        let sessions = store()
        let made = lead { [step("lead", session: $0, state: .running), step("next", stage: 1, provider: "junie")] }
        sessions.add(made)
        sessions.advanceRun(made.id)
        // Stage 1 waits while stage 0 runs.
        #expect(sessions.sessions[made.id]?.reviewRun?.steps[1].state == .waiting)

        sessions.stepResult(result("Lead.", finding: "Missing nil check."), from: made.id)
        let run = try #require(sessions.sessions[made.id]?.reviewRun)
        #expect(run.steps[0].state == .done)
        #expect(run.stage == 1)
        #expect(run.steps[1].state == .running)

        let prompt = SessionStore.stepInstructions(run.steps[1], of: run, specialist: nil)
        #expect(prompt.contains("Missing nil check."))
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
