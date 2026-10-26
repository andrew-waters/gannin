import Foundation
import Testing
@testable import Gannin

/// Where an org files its issues: the team file, and the repos planning's
/// Agree offers and picks under each strategy.
struct IssueStrategyTests {
    private let central = IssueStrategy(kind: .central, repo: "acme/product")

    @Test func decodesLeniently() {
        #expect(TeamCoding.decode(IssueStrategy.self, "{}") == IssueStrategy())
        #expect(TeamCoding.decode(IssueStrategy.self, #"{"kind": "somethingNewer", "repo": "acme/product"}"#) == IssueStrategy(repo: "acme/product"))
        #expect(TeamCoding.decode(IssueStrategy.self, #"{"kind": "central", "repo": "acme/product"}"#) == central)
        #expect(TeamCoding.decode(IssueStrategy.self, #"{"kind": "perRepo", "projectNumber": 4}"#) == IssueStrategy(projectNumber: 4))
    }

    @Test func roundTripsThroughTheTeamFile() throws {
        let text = try #require(TeamCoding.encode(central))
        #expect(TeamCoding.decode(IssueStrategy.self, text) == central)
    }

    @Test func isOrgWide() {
        #expect(TeamFile.isOrgWide(TeamFile.issueStrategy))
        var after = OrgConfig()
        after.issueStrategy = central
        #expect(HarnessTeamData.changedFiles(from: OrgConfig(), to: after).keys.contains(TeamFile.issueStrategy))
        #expect(HarnessTeamData(files: [TeamFile.issueStrategy: TeamCoding.encode(central)!]).appliedOrgWide(to: OrgConfig()).filing == central)
    }

    @Test func centralRepoNeedsOneNamed() {
        #expect(central.centralRepo == "acme/product")
        #expect(IssueStrategy(kind: .central).centralRepo == nil)
        #expect(IssueStrategy(kind: .central, repo: " ").centralRepo == nil)
        #expect(IssueStrategy(repo: "acme/product").centralRepo == nil)
    }

    @Test func perRepoLeavesOutReposWithIssuesOff() {
        let repos = IssueStrategy().filingRepos(["acme/api", "acme/Docs", "acme/web"], issuesOff: ["acme/docs"])
        #expect(repos == ["acme/api", "acme/web"])
    }

    @Test func centralRepoComesFirstEvenWithIssuesOff() {
        #expect(central.filingRepos(["acme/api", "acme/Product"], issuesOff: []) == ["acme/product", "acme/api"])
        #expect(central.filingRepos(["acme/api"], issuesOff: ["acme/product"]) == ["acme/product", "acme/api"])
    }

    @Test func picksWhereATaskIsFiled() {
        let choices = ["acme/api", "acme/web"]
        #expect(IssueStrategy().filingRepo(for: "acme/web", in: choices) == "acme/web")
        #expect(IssueStrategy().filingRepo(for: "acme/docs", in: choices) == "acme/api")
        #expect(IssueStrategy().filingRepo(for: nil, in: []) == "")
        #expect(central.filingRepo(for: "acme/web", in: choices) == "acme/product")
    }

    @Test func boardFollowsTheStrategy() {
        let workflow = IssueWorkflow(projectNumber: 3)
        #expect(IssueStrategy().board(workflow: workflow) == 3)
        #expect(IssueStrategy(projectNumber: 9).board(workflow: workflow) == 9)
        #expect(IssueStrategy(kind: .central, repo: "acme/product", projectNumber: 9).board(workflow: workflow) == 3)
    }

    @Test func agreeSaysWhyARepoChanged() {
        #expect(PlanningAgreeSheet.repoNote(task: "acme/docs", filed: "acme/api", central: nil, issuesOff: ["acme/docs"]) == "acme/docs can't take issues (turned off, or archived), so this goes in acme/api.")
        #expect(PlanningAgreeSheet.repoNote(task: "acme/api", filed: "acme/product", central: "acme/product", issuesOff: []) == "The work is in acme/api; issues go in acme/product.")
        #expect(PlanningAgreeSheet.repoNote(task: "acme/api", filed: "acme/api", central: nil, issuesOff: []) == nil)
        #expect(PlanningAgreeSheet.repoNote(task: nil, filed: "acme/api", central: nil, issuesOff: []) == nil)
    }

    @Test func onlyEpicsAndInitiativesStayContainers() {
        #expect(PlanningAgreeSheet.isContainerType("Epic"))
        #expect(PlanningAgreeSheet.isContainerType("initiative"))
        #expect(!PlanningAgreeSheet.isContainerType("Feature"))
        #expect(!PlanningAgreeSheet.isContainerType(nil))
    }

    @Test func aPlansDetailsAreAppendedOnce() throws {
        let path = "plans/2026-10-26-one.md"
        let first = try #require(PlanningAgreeSheet.appending("- [ ] step", planPath: path, to: "Original.\n"))
        #expect(first.hasPrefix("Original.\n\n<!-- gannin-plan: \(path) -->\n## Details\n\n- [ ] step"))
        #expect(PlanningAgreeSheet.appending("- [ ] step", planPath: path, to: first) == nil)
        #expect(PlanningAgreeSheet.appending("x", planPath: path, to: "")?.hasPrefix("<!-- gannin-plan:") == true)
    }

    @Test func planningInstructionsFollowTheStrategy() {
        #expect(PlanningState.instructions(path: "p.json", filing: central).contains("files every issue in `acme/product`"))
        #expect(PlanningState.instructions(path: "p.json").contains("hasIssuesEnabled,isArchived"))
    }

    /// GitHub answers `rateLimit` beside the aliased repos, and it must
    /// decode too, or the whole lookup fails and nothing is filtered.
    @Test func readsReposThatWontTakeIssues() throws {
        let json = #"{"rateLimit": {"cost": 1, "remaining": 4999, "limit": 5000, "resetAt": "2026-10-23T20:00:00Z"}, "r0": {"nameWithOwner": "acme/Docs", "hasIssuesEnabled": false, "isArchived": false}, "r1": {"nameWithOwner": "acme/api", "hasIssuesEnabled": true, "isArchived": false}, "r2": {"nameWithOwner": "acme/old", "hasIssuesEnabled": true, "isArchived": true}, "r3": null}"#
        let response = try JSONDecoder().decode([String: IssuesEnabledNode?].self, from: Data(json.utf8))
        #expect(IssuesEnabledNode.closed(response) == ["acme/docs", "acme/old"])
    }
}
