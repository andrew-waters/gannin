import Foundation
import Testing
@testable import Gannin

/// Specialists, workflows, routing and review runs (andrew-waters/gannin#493).
struct AgentWorkflowsTests {
    private func specialist(_ text: String, path: String = "specialists/security-reviewer.md") -> HarnessSpecialist? {
        HarnessSpecialist(document: HarnessDocument(path: path, sha: "abc", kind: .specialists, text: text))
    }

    @Test func specialistsReadTheirFrontMatterAndSoul() throws {
        let found = try #require(specialist("""
            ---
            type: specialist
            name: sec
            summary: >
              Looks for security problems.
            provider: junie
            model: fast
            focus: >
              Auth and secrets.
            owner: alex
            ---

            # Security reviewer

            You know our auth middleware.
            """))
        #expect(found.name == "sec")
        #expect(found.title == "Security reviewer")
        #expect(found.provider == "junie")
        #expect(found.model == "fast")
        #expect(found.focus == "Auth and secrets.")
        #expect(found.soul == "You know our auth middleware.")
        #expect(found.otherFields["owner"] == ["alex"])
        // Written back, it reads the same.
        let again = try #require(specialist(found.fileText))
        #expect(again.name == found.name && again.focus == found.focus && again.soul == found.soul && again.otherFields == found.otherFields)
    }

    @Test func aSpecialistWithProseOnlyStillLoads() throws {
        let found = try #require(specialist("# Docs reviewer\n\nYou read the docs.", path: "specialists/docs.md"))
        #expect(found.name == "docs")
        #expect(found.provider == nil && found.model == nil && found.focus == nil)
        #expect(found.instructions(focus: nil).contains("You read the docs."))
        #expect(found.instructions(focus: "Changelog only").contains("Your focus for this step: Changelog only"))
        #expect(HarnessKind(path: "specialists/docs.md") == .specialists)
        #expect(HarnessKind(path: "specialists/_template.md") == nil)
    }

    private let review = AgentWorkflow(id: "chain", name: "Chain", stages: [
        AgentStage(id: "s1", steps: [AgentStep(id: "a", specialist: "sec", rounds: 2)]),
        AgentStage(id: "s2", steps: [AgentStep(id: "b", specialist: "docs"), AgentStep(id: "c", provider: "junie")]),
    ])

    @Test func theFileRoundTripsAndKeepsWhatItDoesntKnow() throws {
        let text = """
            {
              "review": {
                "default": "chain",
                "rules": [{"id": "r1", "workflow": "chain", "paths": ["docs/"]}, {"id": "bad"}],
                "workflows": [{"id": "chain", "name": "Chain", "stages": [{"id": "s1", "steps": [{"id": "a", "specialist": "sec", "rounds": 2}]}]}, {"broken": true}]
              },
              "someday": {"workflows": []}
            }
            """
        let workflows = try #require(TeamCoding.decode(AgentWorkflows.self, text))
        #expect(workflows[.review].workflows.map(\.id) == ["chain"])
        #expect(workflows[.review].rules?.map(\.id) == ["r1"])
        #expect(workflows[.review].defaultWorkflow == "chain")
        #expect(workflows.activities["someday"] != nil)
        let written = try #require(TeamCoding.encode(workflows))
        #expect(written.contains("\"default\" : \"chain\""))
        #expect(TeamCoding.decode(AgentWorkflows.self, written) == workflows)
    }

    @Test func editsMergeByActivityAndID() throws {
        var base = AgentWorkflows()
        base[.review] = ActivityWorkflows(workflows: [review])
        var ours = base
        ours[.review].rules = [RoutingRule(id: "mine", workflow: "chain")]
        var theirs = base
        theirs[.work] = ActivityWorkflows(workflows: [AgentWorkflow(id: "w", name: "W", stages: [])])
        let merged = try #require(TeamCoding.merge(base: TeamCoding.encode(base), ours: TeamCoding.encode(ours), theirs: TeamCoding.encode(theirs)))
        let result = try #require(TeamCoding.decode(AgentWorkflows.self, merged))
        #expect(result[.review].rules?.map(\.id) == ["mine"])
        #expect(result[.work].workflows.map(\.id) == ["w"])
    }

    @Test func routingTakesTheFirstMatchingRuleElseTheDefault() {
        var workflows = AgentWorkflows()
        let docs = AgentWorkflow(id: "docs", name: "Docs", stages: [])
        let api = AgentWorkflow(id: "api", name: "API", stages: [])
        workflows[.review] = ActivityWorkflows(workflows: [review, docs, api], defaultWorkflow: "chain", rules: [
            RoutingRule(id: "1", workflow: "gone", repos: ["web"]),
            RoutingRule(id: "2", workflow: "docs", paths: ["docs/"]),
            RoutingRule(id: "3", workflow: "api", repos: ["acme/api"], authors: ["@Alex"]),
            RoutingRule(id: "4", workflow: "docs", labels: ["documentation"]),
        ])
        workflows[.work] = ActivityWorkflows(workflows: [api], rules: [RoutingRule(id: "5", workflow: "api", issueTypes: ["Bug"])])
        // A rule whose workflow is gone is passed over.
        #expect(workflows.resolve(.review, for: WorkflowSubject(repo: "acme/web")).id == "chain")
        #expect(workflows.resolve(.review, for: WorkflowSubject(repo: "acme/web", paths: ["src/a.swift", "docs/guide.md"])).id == "docs")
        #expect(workflows.resolve(.review, for: WorkflowSubject(repo: "acme/api", author: "alex")).id == "api")
        #expect(workflows.resolve(.review, for: WorkflowSubject(repo: "acme/api", author: "sam")).id == "chain")
        #expect(workflows.resolve(.review, for: WorkflowSubject(repo: "acme/api", labels: ["Documentation"])).id == "docs")
        #expect(workflows.resolve(.work, for: WorkflowSubject(repo: "acme/api", issueType: "bug")).id == "api")
        // No default named: built in. Ask isn't routed.
        #expect(workflows.resolve(.work, for: WorkflowSubject(repo: "acme/api")).isBuiltIn)
        #expect(workflows.resolve(.ask, for: nil).isBuiltIn)
        #expect(AgentWorkflows().resolve(.review, for: WorkflowSubject(repo: "x")).isPlain)
    }

    @Test func interactiveWorkflowsSplitAroundTheirSession() {
        let workflow = AgentWorkflow(id: "w", name: "W", stages: [
            AgentStage(steps: [AgentStep(id: "brief", specialist: "planner")]),
            AgentStage(steps: [AgentStep(id: "session", specialist: "coder", interactive: true)]),
            AgentStage(steps: [AgentStep(id: "after", specialist: "sec")]),
        ])
        #expect(workflow.interactiveStep?.id == "session")
        #expect(workflow.stepsBefore.map(\.id) == ["brief"])
        #expect(workflow.stepsAfter.map(\.id) == ["after"])
        #expect(!workflow.isPlain)
        #expect(AgentWorkflow.builtIn(.work).interactiveStep != nil)
        #expect(AgentWorkflow.builtIn(.review).interactiveStep == nil)
    }

    @Test func passesCountStepsTimesRoundsByProviderAndModel() {
        let specialists = ["sec": HarnessSpecialist(path: "specialists/sec.md", name: "sec", title: "Sec", summary: nil, provider: nil, model: "claude-opus-5-5", focus: nil, soul: "x")]
        let counts = PassCount.of(review, specialists: specialists, defaultModel: nil)
        #expect(counts == [
            PassCount(label: "Claude Code, claude-opus-5-5", passes: 2),
            PassCount(label: "Claude Code", passes: 1),
            PassCount(label: "Junie", passes: 1),
        ])
    }

    private func finding(_ path: String, _ line: Int?, _ comment: String) -> SessionTranscript.Finding {
        SessionTranscript.Finding(path: path, line: line, comment: comment)
    }

    private func result(_ findings: [SessionTranscript.Finding], verdict: String = "comment", summary: String = "S") -> SessionTranscript.ReviewResult {
        SessionTranscript.ReviewResult(summary: summary, verdict: verdict, findings: findings)
    }

    @Test func aStepStopsWhenARoundAddsNothingNew() {
        var step = ReviewStepRun(id: "a", stage: 0, title: "Sec", provider: "claude-code", rounds: 3)
        step.results = [result([finding("a.swift", 1, "x")])]
        #expect(ReviewRunMerge.wantsAnotherRound(step))
        step.results.append(result([finding("a.swift", 1, "x")]))
        #expect(!ReviewRunMerge.wantsAnotherRound(step))
        // Another point on a line already flagged is new.
        step.results = [result([finding("a.swift", 1, "x")]), result([finding("a.swift", 1, "Also leaks the token")])]
        #expect(ReviewRunMerge.wantsAnotherRound(step))
        #expect(step.findings.count == 2)
        step.results = [result([])]
        #expect(!ReviewRunMerge.wantsAnotherRound(step))
        step.rounds = 1
        step.results = [result([finding("a.swift", 1, "x")])]
        #expect(!ReviewRunMerge.wantsAnotherRound(step))
    }

    @Test func aRunMakesOneLabelledReviewWithTheStrictestVerdict() {
        let lead = UUID()
        var first = ReviewStepRun(id: "a", stage: 0, title: "Sec", provider: "claude-code", rounds: 2, session: lead)
        first.results = [
            { var r = result([finding("a.swift", 1, "Injection")], verdict: "approve", summary: "Safe enough."); r.headline = "Adds login"; return r }(),
            result([finding("b.swift", 4, "Leaked key")], verdict: "approve"),
        ]
        first.state = .done
        var second = ReviewStepRun(id: "b", stage: 1, title: "Docs", provider: "claude-code", rounds: 1)
        second.results = [result([finding("a.swift", 1, "Document it"), finding("README.md", nil, "Mention login")], verdict: "request_changes", summary: "Needs docs.")]
        second.state = .done
        var skipped = ReviewStepRun(id: "c", stage: 1, title: "Junie", provider: "junie", rounds: 1)
        skipped.state = .skipped
        skipped.note = "Junie isn't installed on this Mac."
        let run = ReviewRun(workflowID: "chain", workflowName: "Chain", steps: [first, second, skipped])
        let review = ReviewRunMerge.combined(run, lead: lead)
        #expect(review.verdict == "request_changes")
        #expect(review.headline == "Adds login")
        // a.swift:1 is one finding from both; the rest say whose they are.
        #expect(review.findings.count == 3)
        let shared = review.findings.first { $0.path == "a.swift" }
        #expect(shared?.reviewer == "Sec and Docs")
        #expect(shared?.comment == "Sec: Injection Docs: Document it")
        #expect(review.findings.contains { $0.comment == "Sec: Leaked key" })
        #expect(review.findings.contains { $0.comment == "Docs: Mention login" })
        #expect(review.summary.contains("**Sec**: Safe enough. S"))
        #expect(review.summary.contains("**Docs**: Needs docs."))
        #expect(review.summary.contains("Not run: Junie (Junie isn't installed on this Mac.)."))
        // Earlier stages' findings go to later ones, labelled.
        #expect(run.earlierFindings(before: 1).map(\.reviewer) == ["Sec", "Sec"])
        #expect(run.earlierFindings(before: 0).isEmpty)
    }

    @Test func theLeadsOwnPassIsCountedWhenTheFirstStageHasNoClaudeStep() {
        let junieFirst = AgentWorkflow(id: "j", name: "J", stages: [AgentStage(steps: [AgentStep(id: "a", provider: "junie")])])
        let counts = PassCount.of(junieFirst, specialists: [:], defaultModel: nil, activity: .review)
        #expect(counts == [PassCount(label: "Claude Code", passes: 1), PassCount(label: "Junie", passes: 1)])
        #expect(PassCount.of(junieFirst, specialists: [:], defaultModel: nil) == [PassCount(label: "Junie", passes: 1)])
        #expect(PassCount.of(review, specialists: [:], defaultModel: nil, activity: .review).reduce(0) { $0 + $1.passes } == 4)
    }

    @Test func pairReviewsMergeAsBefore() {
        let claude = [finding("a.swift", 1, "x")]
        #expect(PairReview.merge(claude: claude, extras: []) == claude)
        let merged = PairReview.merge(claude: claude, extras: [("Junie", [finding("a.swift", 1, "x")])])
        #expect(merged.first?.comment == "x")
        #expect(merged.first?.reviewer == "claude and Junie")
    }

    @Test func oneShotStepsCheckThePullRequestOutAndRemoveIt() {
        let pr = PullRequestReference(org: "acme", id: "PR_1", number: 7, title: "Tidy", repo: "acme/api", url: URL(string: "https://github.com/acme/api/pull/7")!)
        let tag = UUID(uuidString: "3F9A2C1D-0000-4000-8000-000000000012")!
        let checkout = SessionStore.oneShotCheckout(pr, harness: "~/Code/acme/harness", branch: "review-api-7", tag: tag)
        #expect(checkout.make.contains(#"cd "$HOME"/'Code/acme/harness'"#))
        #expect(checkout.make.contains("fetch --quiet origin 'pull/7/head'"))
        #expect(checkout.make.contains(#"worktree add --quiet --detach "$PWD"/'.worktrees/review-api-7/api-3f9a2c1d' FETCH_HEAD"#))
        #expect(checkout.remove.contains(#"worktree remove --force "$PWD"/'.worktrees/review-api-7/api-3f9a2c1d'"#))
        #expect(Shell.run("bash -n <<'X'\n\(checkout.make)\nX", .local).ok)
        #expect(Shell.run("bash -n <<'X'\n\(checkout.remove)\nX", .local).ok)
    }

    @Test func stepsBeforeASessionPrepareItsBriefOnce() {
        let issue = IssueReference(org: "acme", id: "I_1", number: 12, title: "Fix", repo: "acme/api", url: URL(string: "https://github.com/acme/api/issues/12")!)
        var session = CodeSession(id: UUID(), issue: issue, repo: "acme/harness", branch: "12-fix", createdAt: .now, harnessRepo: "acme/harness", harnessPath: "~/h")
        #expect(SessionScript.prepareSteps(session).isEmpty)
        session.workflow = SessionWorkflow(activity: "work", id: "w", name: "W", before: [PreparedStep(title: "Planner", prompt: "Plan it", model: "claude-opus-5-5")])
        let steps = SessionScript.prepareSteps(session)
        #expect(steps.hasPrefix(#"if [ ! -e "$session/started" ] && [ ! -e "$session/prepared" ]; then"#))
        #expect(steps.contains("claude -p --output-format text --allowedTools 'Read,Glob,Grep' --model 'claude-opus-5-5' < \"$folder/.gannin/prepare-1.md\""))
        #expect(steps.contains(#"tee -a "$session/brief.md" >> "$folder/.gannin/brief.md""#))
        let start = SessionScript.start(session, root: "\"$HOME\"/'h'", directory: "'/tmp/s'")
        #expect(Shell.run("bash -n <<'X'\n\(start)\nX", .local).ok)
        #expect(start.range(of: "prepare-1.md")!.lowerBound < start.range(of: "claude --session-id")!.lowerBound)
    }
}
