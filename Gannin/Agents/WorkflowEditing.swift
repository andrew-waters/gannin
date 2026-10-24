import Foundation

/// What the workflow editor does to a workflow: add, remove and move stages
/// and steps, and keep an interactive activity's one session step. Each
/// leaves a workflow every run can read: no empty stage, and for an
/// interactive activity exactly one interactive step, alone in its stage.
extension AgentWorkflow {
    /// A new workflow for the activity: one step, the session's for an
    /// interactive one.
    static func new(_ activity: WorkflowActivity, name: String) -> AgentWorkflow {
        AgentWorkflow(name: name, stages: [AgentStage(steps: [AgentStep(interactive: activity.isInteractive ? true : nil)])])
    }

    /// A copy with new ids, so the merge never takes it for the original.
    func duplicated(name: String) -> AgentWorkflow {
        AgentWorkflow(name: name, stages: stages.map { stage in
            AgentStage(steps: stage.steps.map { step in
                var copy = step
                copy.id = UUID().uuidString.lowercased()
                return copy
            })
        })
    }

    func location(of stepID: String) -> (stage: Int, step: Int)? {
        for (stageIndex, stage) in stages.enumerated() {
            if let stepIndex = stage.steps.firstIndex(where: { $0.id == stepID }) { return (stageIndex, stepIndex) }
        }
        return nil
    }

    func step(_ id: String) -> AgentStep? {
        location(of: id).map { stages[$0.stage].steps[$0.step] }
    }

    /// A stage of one new step at `index` (the end when it's past it);
    /// returns the step's id.
    @discardableResult
    mutating func addStage(at index: Int) -> String {
        let step = AgentStep()
        stages.insert(AgentStage(steps: [step]), at: min(max(index, 0), stages.count))
        return step.id
    }

    /// A new step beside the others in a stage, to run at the same time.
    /// The session's stage takes none: they go in a stage after it.
    @discardableResult
    mutating func addStep(toStage index: Int, activity: WorkflowActivity) -> String? {
        guard stages.indices.contains(index) else { return nil }
        if activity.isInteractive, stages[index].steps.contains(where: \.isInteractive) {
            return addStage(at: index + 1)
        }
        let step = AgentStep()
        stages[index].steps.append(step)
        return step.id
    }

    /// Takes a step out, and its stage with it when it was the last. The
    /// session step of an interactive activity can't be removed.
    mutating func removeStep(_ id: String, activity: WorkflowActivity) {
        guard let at = location(of: id), !(activity.isInteractive && stages[at.stage].steps[at.step].isInteractive) else { return }
        stages[at.stage].steps.remove(at: at.step)
        if stages[at.stage].steps.isEmpty { stages.remove(at: at.stage) }
    }

    /// Moves a stage earlier (-1) or later (+1).
    mutating func moveStage(_ index: Int, by offset: Int) {
        let target = index + offset
        guard stages.indices.contains(index), stages.indices.contains(target) else { return }
        stages.swapAt(index, target)
    }

    /// Moves a step into the stage before (-1) or after (+1), beside what's
    /// there; one that was alone in its stage takes the stage with it.
    mutating func moveStep(_ id: String, by offset: Int, activity: WorkflowActivity) {
        guard let at = location(of: id) else { return }
        let step = stages[at.stage].steps[at.step]
        if stages[at.stage].steps.count == 1 {
            moveStage(at.stage, by: offset)
            return
        }
        stages[at.stage].steps.remove(at: at.step)
        let target = at.stage + offset
        if stages.indices.contains(target), !(activity.isInteractive && (step.isInteractive || stages[target].steps.contains(where: \.isInteractive))) {
            stages[target].steps.append(step)
        } else {
            stages.insert(AgentStage(steps: [step]), at: offset < 0 ? at.stage : at.stage + 1)
        }
        normalise(for: activity)
    }

    /// Makes a step the session the user types in: the others stop being
    /// it, and any beside it move to a stage of their own after it.
    mutating func makeInteractive(_ id: String) {
        for stage in stages.indices {
            for step in stages[stage].steps.indices {
                stages[stage].steps[step].interactive = stages[stage].steps[step].id == id ? true : nil
            }
        }
        normalise(for: .work)
    }

    /// No empty stages; for an interactive activity, exactly one session
    /// step (the first step when none is), alone in its stage.
    mutating func normalise(for activity: WorkflowActivity) {
        stages.removeAll { $0.steps.isEmpty }
        guard activity.isInteractive else {
            for stage in stages.indices {
                for step in stages[stage].steps.indices { stages[stage].steps[step].interactive = nil }
            }
            return
        }
        if stages.isEmpty { stages = [AgentStage(steps: [AgentStep(interactive: true)])] }
        let keep = interactiveStep?.id ?? stages[0].steps[0].id
        for stage in stages.indices {
            for step in stages[stage].steps.indices {
                stages[stage].steps[step].interactive = stages[stage].steps[step].id == keep ? true : nil
            }
        }
        guard let at = location(of: keep), stages[at.stage].steps.count > 1 else { return }
        let others = stages[at.stage].steps.enumerated().filter { $0.offset != at.step }.map(\.element)
        stages[at.stage].steps = [stages[at.stage].steps[at.step]]
        stages.insert(AgentStage(steps: others), at: at.stage + 1)
    }

    /// Changes one step in place.
    mutating func update(_ id: String, _ change: (inout AgentStep) -> Void) {
        guard let at = location(of: id) else { return }
        change(&stages[at.stage].steps[at.step])
    }
}

extension AgentWorkflows {
    /// Saves a workflow for the activity, adding it if it's new. The
    /// built-in one is never written.
    mutating func save(_ workflow: AgentWorkflow, for activity: WorkflowActivity) {
        guard !workflow.isBuiltIn else { return }
        var entry = self[activity]
        if let index = entry.workflows.firstIndex(where: { $0.id == workflow.id }) {
            entry.workflows[index] = workflow
        } else {
            entry.workflows.append(workflow)
        }
        self[activity] = entry
    }

    /// Removes a workflow, with the rules that send work to it; the default
    /// goes back to built in if it was.
    mutating func remove(_ id: String, for activity: WorkflowActivity) {
        var entry = self[activity]
        entry.workflows.removeAll { $0.id == id }
        entry.rules = entry.rules?.filter { $0.workflow != id }
        if entry.defaultWorkflow == id { entry.defaultWorkflow = nil }
        self[activity] = entry
    }

    mutating func setDefault(_ id: String, for activity: WorkflowActivity) {
        self[activity].defaultWorkflow = id == AgentWorkflow.builtInID ? nil : id
    }

    /// The file's text, nil when there's nothing in it (no file).
    var fileText: String? {
        activities.values.allSatisfy({ $0.workflows.isEmpty && $0.defaultWorkflow == nil && ($0.rules ?? []).isEmpty }) ? nil : TeamCoding.encode(self)
    }
}
