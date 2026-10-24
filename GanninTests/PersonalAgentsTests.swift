import Foundation
import Testing
@testable import Gannin

/// Your own specialists, workflows, rules and defaults beside the team's:
/// how a run is routed, what's kept out of the team file, and how a
/// personal specialist is named on GitHub.
@MainActor
struct PersonalAgentsTests {
    private let pr = WorkflowSubject(repo: "acme/api", author: "alex")

    @Test func yourRulesComeFirstThenTheTeamsThenYourDefault() throws {
        var team = AgentWorkflows()
        let security = AgentWorkflow.new(.review, name: "Security")
        team.save(security, for: .review)
        team[.review].rules = [RoutingRule(workflow: security.id, repos: ["api"])]
        var personal = AgentWorkflows()
        let coaching = AgentWorkflow.new(.review, name: "Coaching")
        personal.save(coaching, for: .review)

        // Only the team's rule matches.
        var library = WorkflowLibrary(team: team, personal: personal)
        #expect(library.resolve(.review, for: pr).id == security.id)

        // Yours wins where both match, and can send to your own workflow.
        personal[.review].rules = [RoutingRule(workflow: coaching.id, authors: ["alex"])]
        library = WorkflowLibrary(team: team, personal: personal)
        #expect(library.resolve(.review, for: pr).id == coaching.id)
        #expect(library.rules(for: .review).map(\.workflow) == [coaching.id, security.id])

        // With nothing matching, your default runs.
        personal.setDefault(security.id, for: .review)
        library = WorkflowLibrary(team: team, personal: personal)
        #expect(library.resolve(.review, for: WorkflowSubject(repo: "acme/web")).id == security.id)
        #expect(library.isPersonal(coaching.id, for: .review))
        #expect(!library.isPersonal(security.id, for: .review))
    }

    @Test func theTeamsDefaultIsIgnoredAndItsRulesReachOnlyTeamWorkflows() {
        var team = AgentWorkflows()
        let security = AgentWorkflow.new(.review, name: "Security")
        team.save(security, for: .review)
        team.setDefault(security.id, for: .review)
        var personal = AgentWorkflows()
        let mine = AgentWorkflow.new(.review, name: "Mine")
        personal.save(mine, for: .review)
        // A hand-edited team rule naming someone's own workflow.
        team[.review].rules = [RoutingRule(workflow: mine.id)]
        let library = WorkflowLibrary(team: team, personal: personal)
        // Someone new gets Gannin's.
        #expect(library.defaultWorkflow(for: .review).isBuiltIn)
        #expect(library.resolve(.review, for: pr).isBuiltIn)
    }

    @Test func aWorkflowWithYourSpecialistIsYoursAlone() {
        var workflow = AgentWorkflow.new(.review, name: "Coaching")
        #expect(!workflow.usesPersonalSpecialist)
        let id = workflow.steps[0].id
        workflow.update(id) { $0.specialist = "personal/alex-coach" }
        #expect(workflow.usesPersonalSpecialist)
        var team = AgentWorkflows()
        team.save(workflow, for: .review)
        #expect(team.usesPersonalSpecialist)

        let mine = PersonalSpecialist(name: "alex-coach", title: "Alex's coach", summary: nil, provider: nil, model: "claude-opus-5-5", focus: nil, soul: "Kind.")
        #expect(mine.specialist.name == "personal/alex-coach")
        #expect(mine.specialist.isPersonal)
        #expect(PersonalSpecialist(mine.specialist) == mine)
    }

    @Test func aPersonalStepIsNamedNeutrallyWhenPosted() {
        var team = ReviewStepRun(id: "a", stage: 0, title: "Security", provider: "claude-code", rounds: 1)
        team.results = [SessionTranscript.ReviewResult(summary: "Fine.", verdict: "approve", findings: [])]
        var mine = ReviewStepRun(id: "b", stage: 0, title: "Alex's coach", provider: "claude-code", rounds: 1)
        mine.personal = true
        mine.results = [SessionTranscript.ReviewResult(summary: "Kind.", verdict: "comment", findings: [])]
        var skipped = ReviewStepRun(id: "c", stage: 1, title: "Alex's other coach", provider: "claude-code", rounds: 1)
        skipped.personal = true
        skipped.state = .skipped
        let run = ReviewRun(workflowID: "w", workflowName: "W", steps: [team, mine, skipped])
        #expect(run.postedTitle(team) == "Security")
        #expect(run.postedTitle(mine) == "Reviewer 1")
        #expect(run.postedTitle(skipped) == "Reviewer 2")
        let summary = ReviewRunMerge.combined(run, lead: UUID()).summary
        #expect(!summary.contains("Alex"))
        #expect(summary.contains("**Reviewer 1**"))
    }

    @Test func personalAgentsRoundTrip() throws {
        var agents = PersonalAgents()
        agents.save(PersonalSpecialist(name: "coach", title: "Coach", summary: nil, provider: nil, model: nil, focus: nil, soul: "Kind."))
        var workflows = AgentWorkflows()
        workflows.save(.new(.review, name: "Mine"), for: .review)
        agents.projects["acme/harness"] = workflows
        let decoded = try JSONDecoder().decode(PersonalAgents.self, from: JSONEncoder().encode(agents))
        #expect(decoded == agents)
        #expect(!decoded.isEmpty)
    }
}
