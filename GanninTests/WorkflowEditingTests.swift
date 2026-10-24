import Foundation
import Testing
@testable import Gannin

/// The workflow editor's operations (andrew-waters/gannin#494): stages and
/// steps added, moved and removed, and an interactive activity's one
/// session step kept.
struct WorkflowEditingTests {
    private func ids(_ workflow: AgentWorkflow) -> [[String]] {
        workflow.stages.map { $0.steps.map(\.id) }
    }

    @Test func stagesAndParallelStepsAreAddedMovedAndRemoved() throws {
        var workflow = AgentWorkflow.new(.review, name: "Review")
        let first = try #require(workflow.steps.first?.id)
        let second = workflow.addStage(at: 1)
        let added = workflow.addStep(toStage: 1, activity: .review)
        let beside = try #require(added)
        #expect(ids(workflow) == [[first], [second, beside]])
        #expect(workflow.interactiveStep == nil)

        workflow.moveStage(1, by: -1)
        #expect(ids(workflow) == [[second, beside], [first]])
        // One of two moves into the next stage, beside what's there.
        workflow.moveStep(beside, by: 1, activity: .review)
        #expect(ids(workflow) == [[second], [first, beside]])
        // Alone in its stage, a step takes the stage with it.
        workflow.moveStep(second, by: 1, activity: .review)
        #expect(ids(workflow) == [[first, beside], [second]])

        workflow.removeStep(second, activity: .review)
        #expect(ids(workflow) == [[first, beside]])
        workflow.removeStep(beside, activity: .review)
        workflow.removeStep(first, activity: .review)
        #expect(workflow.stages.isEmpty)
    }

    @Test func anInteractiveWorkflowKeepsOneSessionAloneInItsStage() throws {
        var workflow = AgentWorkflow.new(.work, name: "Work")
        let session = try #require(workflow.interactiveStep?.id)
        // Nothing goes beside the session: a step "beside" it gets a stage after.
        let added = workflow.addStep(toStage: 0, activity: .work)
        let after = try #require(added)
        #expect(ids(workflow) == [[session], [after]])
        let before = workflow.addStage(at: 0)
        #expect(workflow.stepsBefore.map(\.id) == [before])
        #expect(workflow.stepsAfter.map(\.id) == [after])

        // The session can't be removed; another step can be made it.
        workflow.removeStep(session, activity: .work)
        #expect(workflow.interactiveStep?.id == session)
        workflow.makeInteractive(after)
        #expect(workflow.steps.filter(\.isInteractive).map(\.id) == [after])

        // A step moved into the session's stage gets one of its own.
        workflow.moveStep(before, by: 1, activity: .work)
        #expect(workflow.stages.allSatisfy { stage in !stage.steps.contains(where: \.isInteractive) || stage.steps.count == 1 })
        #expect(workflow.steps.filter(\.isInteractive).count == 1)
    }

    @Test func normalisingMendsAHandWrittenWorkflow() {
        var workflow = AgentWorkflow(name: "Hand made", stages: [
            AgentStage(steps: []),
            AgentStage(steps: [AgentStep(id: "a", interactive: true), AgentStep(id: "b", interactive: true)]),
        ])
        workflow.normalise(for: .ask)
        #expect(ids(workflow) == [["a"], ["b"]])
        #expect(workflow.interactiveStep?.id == "a")
        #expect(workflow.steps.filter(\.isInteractive).count == 1)
        workflow.normalise(for: .review)
        #expect(workflow.interactiveStep == nil)
    }

    @Test func savingRemovingAndDefaults() {
        var file = AgentWorkflows()
        #expect(file.fileText == nil)
        let made = AgentWorkflow.new(.review, name: "Security first")
        file.save(made, for: .review)
        file.setDefault(made.id, for: .review)
        file[.review].rules = [RoutingRule(workflow: made.id, paths: ["auth/"])]
        #expect(file.defaultWorkflow(for: .review).id == made.id)
        #expect(file.fileText != nil)
        // The built-in one is never written, and making it the default is no default.
        file.save(.builtIn(.review), for: .review)
        #expect(file[.review].workflows.map(\.id) == [made.id])
        file.setDefault(AgentWorkflow.builtInID, for: .review)
        #expect(file[.review].defaultWorkflow == nil)
        file.setDefault(made.id, for: .review)
        file.remove(made.id, for: .review)
        #expect(file[.review].workflows.isEmpty && file[.review].defaultWorkflow == nil && (file[.review].rules ?? []).isEmpty)
        #expect(file.fileText == nil)
    }

    @Test func aDuplicateHasItsOwnIDs() {
        let original = AgentWorkflow.new(.review, name: "A")
        let copy = original.duplicated(name: "B")
        #expect(copy.id != original.id)
        #expect(Set(copy.steps.map(\.id)).isDisjoint(with: original.steps.map(\.id)))
        #expect(copy.name == "B")
    }
}
