import Foundation
import Testing
@testable import Gannin

/// The project's goals in a Work on This brief: those a change moves, as
/// guidance.
struct SessionBriefGoalsTests {
    private func session() -> CodeSession {
        let issue = IssueReference(
            org: "acme", id: "I_1", number: 70, title: "Goals in the brief", repo: "acme/app",
            url: URL(string: "https://github.com/acme/app/issues/70")!
        )
        return CodeSession(
            id: UUID(), issue: issue, repo: "acme/harness", branch: "70-goals", createdAt: .now,
            harnessRepo: "acme/harness", harnessPath: "~/Code/acme/harness"
        )
    }

    private func goal(_ metric: ScorecardMetric?, target: Double?, team: String? = nil) -> Measurable {
        Measurable(name: metric?.title ?? "Hosting costs", cadence: .weekly, metric: metric, team: team, comparison: .atMost, target: target)
    }

    @Test func noGoalsLeavesTheBriefAsItWas() {
        let brief = SessionBrief.make(session: session(), record: nil, detail: nil, parent: nil, harness: nil)
        #expect(!brief.contains("## Goals"))
        #expect(SessionBrief.goalsSection([]).isEmpty)
    }

    @Test func sizeGoalsAreListedWithTheCaveat() {
        let brief = SessionBrief.make(
            session: session(), record: nil, detail: nil, parent: nil, harness: nil,
            goals: [goal(.prSize, target: 400), goal(.prFiles, target: 10)]
        )
        #expect(brief.contains("## Goals"))
        #expect(brief.contains("- **PR size**: ≤ 400 lines."))
        #expect(brief.contains("- **Files changed**: ≤ 10 files."))
        #expect(brief.contains("guidance, not rules"))
        #expect(brief.contains("under Why"))
        // Before the working notes.
        #expect(brief.range(of: "## Goals")!.lowerBound < brief.range(of: "## Working here")!.lowerBound)
    }

    @Test func leavesOutWhatAChangeDoesNotMove() {
        let lines = SessionBrief.goalsSection([
            goal(.firstReview, target: 4),
            goal(.answered, target: 90),
            goal(nil, target: 1000),
            goal(.prSize, target: nil),
            goal(.prSize, target: 200, team: "web"),
        ])
        #expect(lines.isEmpty)
    }
}
