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
}
