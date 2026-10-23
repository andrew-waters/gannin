import Foundation
import Testing
@testable import Gannin

/// CI time per PR: matching runs to PRs, what a PR's time is made of, the
/// rank correlation behind CI against size, and runs a newer push overtook.
@MainActor
struct PullRequestCITests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }

    private func run(
        _ id: Int, sha: String, branch: String = "feature", event: String = "pull_request", workflow: String = "CI",
        at minute: Double, minutes: Double = 10, conclusion: String = "success", attempt: Int = 1, prs: [Int]? = nil, actor: String = "alex"
    ) -> WorkflowRun {
        WorkflowRun(
            id: id, repo: "acme/api", workflowID: workflow.hashValue, name: workflow, path: ".github/workflows/ci.yml",
            event: event, branch: branch, headSha: sha, runNumber: id, attempt: attempt, status: "completed",
            conclusion: conclusion, createdAt: at(minute), startedAt: at(minute), updatedAt: at(minute + minutes),
            actor: actor, url: URL(string: "https://github.com/acme/api/actions/runs/\(id)")!, pullRequests: prs
        )
    }

    private func merged(_ number: Int, branch: String, at minute: Double, lines: Int = 10) -> MetricPullRequest {
        MetricPullRequest(
            id: "PR_\(number)", number: number, title: "PR \(number)", url: URL(string: "https://github.com/acme/api/pull/\(number)")!,
            repo: "acme/api", author: Person(login: "alex", name: nil, avatarUrl: nil), authorIsBot: false,
            createdAt: at(minute - 600), mergedAt: at(minute), firstCommitAt: at(minute - 700), readyAt: nil,
            reviews: [], reviewRequests: [], additions: lines, deletions: 0, headRef: branch
        )
    }

    @Test func runsGoToTheListedPRThenTheBranchesMergedPR() {
        let runs = [
            run(1, sha: "a", at: 0, prs: [7]),
            run(2, sha: "b", at: 20),
            // The branch used again after #5 merged, for an open PR.
            run(3, sha: "c", at: 200, prs: [9]),
            run(4, sha: "d", at: 210),
            run(5, sha: "e", branch: "main", event: "push", at: 30),
            run(6, sha: "f", event: "schedule", at: 40),
            // GitHub lists an upstream PR from this repo's main: not this repo's.
            run(7, sha: "g", branch: "main", event: "push", at: 50, prs: [11]),
        ]
        let matched = PullRequestCI.match(runs, merged: [merged(5, branch: "feature", at: 100)], defaultBranches: ["acme/api": "main"])
        #expect(matched["acme/api#7"]?.map(\.id) == [1])
        #expect(matched["acme/api#5"]?.map(\.id) == [2])
        #expect(Set(matched["acme/api#9"]?.map(\.id) ?? []) == [3, 4])
        #expect(matched.values.flatMap { $0 }.allSatisfy { ![5, 6, 7].contains($0.id) })
        #expect(matched["acme/api#11"] == nil)
        // A branch's open PR keeps its number when its newest run isn't listed.
        let all = PullRequestCI.all(runs: runs, merged: [merged(5, branch: "feature", at: 100)], open: [], defaultBranches: ["acme/api": "main"], config: OrgConfig())
        #expect(Set(all.map(\.id)) == ["acme/api#7", "acme/api#5", "acme/api#9"])
    }

    @Test func aPRsTimeSplitsIntoReplacedFailedAndFinal() {
        let pr = merged(5, branch: "feature", at: 60)
        let runs = [
            run(1, sha: "a", at: 0, minutes: 10),
            run(2, sha: "a", workflow: "Lint", at: 0, minutes: 2),
            run(3, sha: "b", at: 20, minutes: 10, conclusion: "failure"),
            run(4, sha: "b", workflow: "Lint", at: 20, minutes: 2, attempt: 2),
        ]
        let ci = PullRequestCI.build(number: 5, runs: runs, merged: pr, open: nil)
        #expect(ci.runTime == 24 * 60)
        #expect(ci.commits == 2)
        #expect(ci.supersededTime == 12 * 60)
        #expect(ci.failedTime == 10 * 60)
        #expect(ci.failed == 1)
        #expect(ci.reruns == 1)
        #expect(ci.workflows.map(\.name) == ["CI", "Lint"])
        // Pushed at 20, CI done at 30, merged at 60.
        #expect(ci.finalWait == TimeInterval(10 * 60))
        #expect(ci.mergeAfterCI == TimeInterval(30 * 60))
        #expect(!ci.mergedOnCI)
    }

    @Test func botsAreKnownByTheirRuns() {
        let ci = PullRequestCI.build(number: 3, runs: [run(1, sha: "a", at: 0, prs: [3], actor: "dependabot[bot]")], merged: nil, open: nil)
        #expect(ci.isBot)
        // A person's PR that automation pushed to is still theirs.
        let pushed = PullRequestCI.build(number: 5, runs: [run(2, sha: "b", at: 0, actor: "renovate[bot]")], merged: merged(5, branch: "x", at: 30), open: nil)
        #expect(!pushed.isBot)
    }

    @Test func spearmanRanksWithTies() {
        #expect(abs((CIScaling.spearman([(1, 10), (2, 20), (3, 30), (4, 40)]) ?? 0) - 1) < 0.0001)
        #expect(abs((CIScaling.spearman([(1, 40), (2, 30), (3, 20), (4, 10)]) ?? 0) + 1) < 0.0001)
        let tied = CIScaling.spearman([(1, 5), (1, 5), (2, 6), (3, 7)]) ?? 0
        #expect(abs(tied - 1) < 0.0001)
        #expect(CIScaling.spearman([(1, 5), (2, 5), (3, 5)]) == nil)
    }

    @Test func bandsTakeTheMedianPerHundredLines() {
        let small = PullRequestCI.build(number: 5, runs: [run(1, sha: "a", at: 0, minutes: 10)], merged: merged(1, branch: "x", at: 30, lines: 10), open: nil)
        let large = PullRequestCI.build(number: 5, runs: [run(2, sha: "b", at: 0, minutes: 20)], merged: merged(2, branch: "y", at: 30, lines: 800), open: nil)
        let bands = CIScaling.bands([small, large])
        #expect(bands.map(\.label) == ["0-10", "401-1,000"])
        #expect(bands[0].perHundredLines == TimeInterval(100 * 60))
        #expect(bands[1].perHundredLines == TimeInterval(150))
    }

    @Test func overtakenRunsThatRanOnAreCounted() {
        let runs = [
            run(1, sha: "a", at: 0, minutes: 10),
            // Pushed while 1 ran; 1 ran on for 5 more minutes.
            run(2, sha: "b", at: 5, minutes: 10, conclusion: "cancelled"),
            // Pushed while 2 ran; 2 was cancelled.
            run(3, sha: "c", at: 8, minutes: 10),
            run(4, sha: "d", branch: "main", event: "push", at: 0, minutes: 10),
            run(5, sha: "e", branch: "main", event: "push", at: 2, minutes: 10),
        ]
        // An old commit's run re-run after newer pushes wasn't left running.
        var rerun = run(8, sha: "z", at: -100, minutes: 10, attempt: 2)
        rerun = WorkflowRun(
            id: rerun.id, repo: rerun.repo, workflowID: rerun.workflowID, name: rerun.name, path: rerun.path, event: rerun.event,
            branch: rerun.branch, headSha: rerun.headSha, runNumber: rerun.runNumber, attempt: 2, status: "completed",
            conclusion: "success", createdAt: at(-100), startedAt: at(100), updatedAt: at(110), actor: nil, url: rerun.url
        )
        let overtaken = ActionsMetrics.overtaken(runs + [rerun], defaultBranch: "main")
        #expect(overtaken.keptGoing == 1)
        #expect(overtaken.time == 5 * 60)
        #expect(overtaken.cancelled == 1)
    }
}
