import Foundation
import Testing
@testable import Gannin

/// A second agent reviewing a session's change: the rounds, its findings
/// and the script the working agent runs.
struct PairReviewTests {
    private func session(inHarness: Bool = true) -> CodeSession {
        let issue = IssueReference(
            org: "acme", id: "I_1", number: 68, title: "Pair review", repo: "acme/app",
            url: URL(string: "https://github.com/acme/app/issues/68")!
        )
        return CodeSession(
            id: UUID(), issue: issue, repo: "acme/harness", branch: "68-pair-review", createdAt: .now,
            harnessRepo: inHarness ? "acme/harness" : nil, harnessPath: inHarness ? "~/Code/acme/harness" : nil
        )
    }

    private func transcript(_ reply: String) -> SessionTranscript {
        var transcript = SessionTranscript()
        transcript.lastReply = reply
        return transcript
    }

    @Test func roundWithFindingsGoesBackToBeFixed() {
        var pairing = PairReview()
        pairing.finishRound(findings: 2, reply: "a")
        #expect(pairing.phase == .fixing)
        #expect(pairing.round == 1)
        #expect(pairing.lastReply == "a")
        #expect(!pairing.isOver)
    }

    @Test func roundWithNothingSettles() {
        var pairing = PairReview(round: 1, phase: .reviewing)
        pairing.finishRound(findings: 0, reply: "b")
        #expect(pairing.phase == .settled)
        #expect(pairing.endedAt != nil)
        #expect(pairing.status == "Settled after 2 rounds: nothing more to fix")
    }

    @Test func lastRoundStopsAtTheLimit() {
        var pairing = PairReview(round: PairReview.maxRounds - 1, phase: .reviewing)
        pairing.finishRound(findings: 1, reply: "c")
        #expect(pairing.phase == .limit)
        #expect(pairing.isOver)
    }

    @Test func emptyListIsAnAnswer() {
        #expect(transcript("Nothing left.\n\n```json\n[]\n```").listedFindings == [])
        #expect(transcript("Still reading the diff.").listedFindings == nil)
        let found = transcript(#"Two things.\#n```json\#n[{"path": "app/a.swift", "line": 3, "comment": "Off by one"}]\#n```"#).listedFindings
        #expect(found?.count == 1)
        #expect(found?.first?.line == 3)
    }

    @Test func onlyAnIssuesOwnSessionPairs() {
        var helper = session()
        helper.parentID = UUID()
        #expect(session().canPairReview)
        #expect(!helper.canPairReview)
    }

    @Test func scriptPathFollowsWhereClaudeRuns() {
        #expect(session().readyForReviewScript == ".worktrees/68-pair-review/.gannin/ready-for-review")
        #expect(session(inHarness: false).readyForReviewScript == ".gannin/ready-for-review")
    }

    @Test func briefsPullRequestStepAsksForTheReviewFirst() {
        func brief(_ session: CodeSession) -> String {
            SessionBrief.make(session: session, record: nil, detail: nil, parent: nil, harness: nil)
        }
        func asks(_ script: String) -> String {
            "run `\(script) \"<what changed and where to look>\"` and wait for its outcome (opening it as a draft first is fine)."
        }

        let issue = brief(session())
        #expect(issue.contains("Before opening it as ready for review, " + asks(".worktrees/68-pair-review/.gannin/ready-for-review")))
        #expect(brief(session(inHarness: false)).contains(asks(".gannin/ready-for-review")))

        var noIssue = session()
        noIssue.quickChange = QuickChangeInfo(note: "Nudge it", attachments: [], hasIssue: false)
        #expect(brief(noIssue).contains(asks(".worktrees/68-pair-review/.gannin/ready-for-review")))

        var helper = session()
        helper.parentID = UUID()
        #expect(!brief(helper).contains("Before opening it as ready for review"))

        var local = session()
        var routine = Routine.new(org: "acme", harnessRepo: "acme/harness", kind: .code, name: "Tidy dependencies")
        routine.limit = .localOnly
        local.routineRun = RoutineRunInfo(routine: routine, run: UUID())
        #expect(!brief(local).contains("Before opening it as ready for review"))
    }

    @Test func scriptWritesTheRequestIntoTheSessionsFolder() {
        let script = SessionScript.readyForReview(session(), directory: #""$HOME"/.gannin/sessions/x"#)
        #expect(script.hasPrefix("#!/bin/bash\n"))
        #expect(script.contains(#"> "$HOME"/.gannin/sessions/x/review-request"#))
        #expect(script.contains(#"tr '\n' ' '"#))
    }

    @Test func settingsAllowTheScript() throws {
        let json = SessionScript.settings(directory: "/tmp/s", isRemote: true, allowing: [".gannin/ready-for-review"])
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let allow = (object["permissions"] as? [String: Any])?["allow"] as? [String]
        #expect(allow == ["Bash(.gannin/ready-for-review:*)"])
        let none = SessionScript.settings(directory: "/tmp/s", isRemote: true)
        #expect(!none.contains("permissions"))
    }

    @Test func findingsPromptSaysWhatsNext() {
        let findings = [SessionTranscript.Finding(path: "app/a.swift", line: 3, comment: "Off by one")]
        let again = SessionStore.findingsPrompt(findings, round: 1, script: ".gannin/ready-for-review", last: false)
        #expect(again.contains("1. `app/a.swift:3`: Off by one"))
        #expect(again.contains("run `.gannin/ready-for-review"))
        let last = SessionStore.findingsPrompt(findings, round: 3, script: ".gannin/ready-for-review", last: true)
        #expect(last.contains("last round"))
    }

    // MARK: A reviewer whose sandbox failed

    /// A store with a working session and its reviewer helper in a sandbox, the
    /// pairing saved as `phase`.
    private func paired(_ phase: PairReview.Phase, in folder: URL) -> (store: SessionStore, parent: UUID, reviewer: UUID) {
        let store = SessionStore(harness: HarnessStore(auth: AuthStore()), directory: folder, saveDelay: .seconds(60), defaults: UserDefaults(suiteName: "PairReviewTests-\(UUID().uuidString)")!)
        var parent = session()
        parent.sandbox = SandboxPlacement.containerName(for: parent.id)
        let reviewer = CodeSession(
            id: UUID(), issue: parent.issue, repo: parent.repo, branch: parent.branch, createdAt: .now,
            harnessRepo: parent.harnessRepo, harnessPath: parent.harnessPath,
            parentID: parent.id, role: "Review", prompt: "Review it", isReviewer: true, sandbox: parent.sandbox
        )
        parent.pairing = PairReview(reviewerID: reviewer.id, round: 1, phase: phase, lastReply: "reply")
        store.add(parent)
        store.add(reviewer)
        return (store, parent.id, reviewer.id)
    }

    @Test(arguments: [PairReview.Phase.reviewing, .fixing, .settled, .limit, .stopped])
    func aReviewerWhoseSandboxFailedIsReplaced(phase: PairReview.Phase) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "PairReviewTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (store, parent, reviewer) = paired(phase, in: folder)
        store.sandboxStatus[reviewer] = "failed: The sandbox didn't start."
        store.pendingPrompts[reviewer] = "Look again"
        var pairing = store.sessions[parent]!.pairing!

        #expect(store.replaceFailedReviewer(of: parent, in: &pairing))

        // Nothing is left for a new request to find and wait on, whichever
        // branch of reviewRequested it would have taken.
        #expect(pairing.reviewerID == nil)
        #expect(pairing.lastReply == nil)
        #expect(pairing.phase == phase)
        #expect(store.sessions[parent]?.pairing?.reviewerID == nil)
        #expect(store.sessions[reviewer] == nil)
        #expect(store.helpers(of: parent).isEmpty)
        #expect(store.pendingPrompts[reviewer] == nil)
        // The issue's own session, and so its sandbox, stays.
        #expect(store.sessions[parent] != nil)
    }

    @Test(arguments: [PairReview.Phase.settled, .limit, .stopped])
    func reviewNowSaysWhyWhenTheSessionIsntRunning(phase: PairReview.Phase) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "PairReviewTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (store, parent, _) = paired(phase, in: folder)
        let before = store.sessions[parent]?.pairing

        store.reviewRequested(parent, note: "", byYou: true)

        #expect(store.pairReviewProblems[parent] != nil)
        #expect(store.sessions[parent]?.pairing == before)
    }

    @Test func aReviewerWhoseSandboxStartedIsKept() {
        let folder = FileManager.default.temporaryDirectory.appending(path: "PairReviewTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (store, parent, reviewer) = paired(.reviewing, in: folder)
        var pairing = store.sessions[parent]!.pairing!
        for status in [nil, "starting", "running"] {
            store.sandboxStatus[reviewer] = status
            #expect(!store.replaceFailedReviewer(of: parent, in: &pairing))
        }
        #expect(pairing.reviewerID == reviewer)
        #expect(store.sessions[reviewer] != nil)
    }
}
