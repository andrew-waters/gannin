import Foundation

/// The workflow an interactive session was started through, kept with it:
/// which one, the one-shot steps that prepare its brief before its agent
/// starts, and the review its PRs get from the steps after it.
struct SessionWorkflow: Codable, Hashable {
    var activity: String
    var id: String
    var name: String
    /// One-shot steps run before the agent first starts, each adding to
    /// the brief.
    var before: [PreparedStep]?
    /// The steps after the session, run as a review of each PR it opens.
    var after: AgentWorkflow?
    /// Steps that couldn't run as written, and why.
    var notes: [String]?
}

/// A one-shot step before a session: its prompt, written whole when the
/// session started, and the model it runs on.
struct PreparedStep: Codable, Hashable {
    var title: String
    var prompt: String
    var model: String?
}

extension SessionStore {
    /// The workflow an activity routes to for the subject (a PR or issue),
    /// from the project's harness.
    func routedWorkflow(org: String, setup: HarnessConfig, activity: WorkflowActivity, subject: WorkflowSubject?) -> AgentWorkflow {
        agentWorkflows(org, setup).resolve(activity, for: subject)
    }

    /// The project's specialists and the user's own, by lower-cased name
    /// (`personal/<name>` for the user's).
    func specialists(org: String, setup: HarnessConfig) -> [String: HarnessSpecialist] {
        (harnessStore.index(for: org, setup)?.specialists ?? [:]).merging(personalSpecialists(org)) { team, _ in team }
    }

    /// Starts the session as its activity's workflow says (`workflow`, else
    /// the one routed for `subject`): the interactive step's specialist soul
    /// and focus go before the team's prompts in its instructions, its
    /// provider and model are the session's, and the steps before and after
    /// it are kept for the start script and for the PRs it opens. A workflow
    /// of Gannin's one plain step, built in or not, changes nothing.
    func applyWorkflow(_ activity: WorkflowActivity, to session: inout CodeSession, org: String, setup: HarnessConfig, subject: WorkflowSubject?, workflow picked: AgentWorkflow? = nil) {
        let workflow = picked ?? routedWorkflow(org: org, setup: setup, activity: activity, subject: subject)
        guard !workflow.isPlain, let step = workflow.interactiveStep ?? workflow.steps.first else { return }
        let specialists = specialists(org: org, setup: setup)
        var notes: [String] = []
        let specialist = step.specialist.flatMap { name in
            let found = specialists[name.lowercased()]
            if found == nil { notes.append("The specialist \(name) isn't in \(setup.repo), so the session runs Gannin's own prompt.") }
            return found
        }
        let named = ProviderID(name: step.provider ?? specialist?.provider)
        if let named, !named.isInteractive {
            notes.append("\(named.title) only answers once, so the session runs on \(ProviderID.claudeCode.title).")
        }
        session.provider = named.flatMap { $0.isInteractive ? $0 : nil } ?? session.provider ?? Self.provider
        session.model = (step.model ?? specialist?.model).flatMap { $0.isEmpty ? nil : $0 } ?? session.model
        if let specialist {
            session.instructions = [specialist.instructions(focus: step.focus), session.instructions].compactMap { $0 }.joined(separator: "\n\n")
        } else if let focus = step.focus?.trimmingCharacters(in: .whitespacesAndNewlines), !focus.isEmpty {
            session.instructions = ["Your focus: \(focus)", session.instructions].compactMap { $0 }.joined(separator: "\n\n")
        }
        let before = workflow.stepsBefore.compactMap { step -> PreparedStep? in
            let specialist = step.specialist.flatMap { specialists[$0.lowercased()] }
            let provider = ProviderID(name: step.provider ?? specialist?.provider) ?? .claudeCode
            guard provider.isInteractive else {
                notes.append("\(specialist?.title ?? "A step") on \(provider.title) can't prepare a session, so it was left out.")
                return nil
            }
            return PreparedStep(
                title: specialist?.title ?? "Preparation",
                prompt: Self.preparePrompt(session, specialist: specialist, focus: step.focus),
                model: (step.model ?? specialist?.model).flatMap { $0.isEmpty ? nil : $0 }
            )
        }
        let after = workflow.stepsAfter.isEmpty ? nil : AgentWorkflow(
            id: workflow.id, name: workflow.name,
            stages: Array(workflow.stages.drop { !$0.steps.contains(where: \.isInteractive) }.dropFirst())
        )
        session.workflow = SessionWorkflow(
            activity: activity.rawValue, id: workflow.id, name: workflow.name,
            before: before.isEmpty ? nil : before, after: after, notes: notes.isEmpty ? nil : notes
        )
    }

    /// What a one-shot step before a session is asked: who it is, then to
    /// read the brief and write what the session should know first.
    static func preparePrompt(_ session: CodeSession, specialist: HarnessSpecialist?, focus: String?) -> String {
        let folder = ".worktrees/\(session.branch)"
        var parts: [String] = []
        if let specialist {
            parts.append(specialist.instructions(focus: focus))
        } else if let focus = HarnessSpecialist.focus(step: focus, specialist: nil) {
            parts.append("Your focus: \(focus)")
        }
        parts.append("""
            A Claude Code session is about to start on \(session.longReference), "\(session.issue.title)", in the team's harness. \
            Read its brief, \(folder)/.gannin/brief.md, and whatever in the harness and its projects helps, then write what the session \
            should know before it starts, as Markdown with no preamble. Don't change any files.
            """)
        return parts.joined(separator: "\n\n")
    }

    /// The subject a coding workflow is routed by: the issue's repo, labels
    /// and type, from the issue history.
    func codingSubject(_ reference: IssueReference, record: IssueRecord?) -> WorkflowSubject {
        WorkflowSubject(repo: reference.repo, labels: record?.labels ?? [], issueType: record?.issueType)
    }
}

extension SessionScript {
    /// The workflow's one-shot steps before the session, run once, before
    /// its agent first starts: each answer is added to the brief, in the
    /// session's folder (so it's kept for a resume) and the one the agent
    /// reads. A step that fails is warned about and the session starts
    /// anyway. Empty without any, else ends with a newline. Needs
    /// `$session`, `$folder` and the shared functions.
    static func prepareSteps(_ session: CodeSession) -> String {
        guard let steps = session.workflow?.before, !steps.isEmpty else { return "" }
        var lines = [#"if [ ! -e "$session/started" ] && [ ! -e "$session/prepared" ]; then"#]
        for (index, step) in steps.enumerated() {
            let file = #""$folder/.gannin/prepare-"# + "\(index + 1)" + #".md""#
            let heading = Data("\n## From \(step.title)\n\n".utf8).base64EncodedString()
            lines += [
                "  note \(quoted("Preparing the session: \(step.title)"))",
                "  printf %s \(Data(step.prompt.utf8).base64EncodedString()) | base64 -d > \(file)",
                "  if out=$(\(session.agent.oneShotCommand(promptFile: file, model: step.model))); then",
                #"    { printf %s "# + heading + #" | base64 -d; printf '%s\n' "$out"; } | tee -a "$session/brief.md" >> "$folder/.gannin/brief.md""#,
                "  else",
                "    warn \(quoted("\(step.title) couldn't prepare the session, so it starts without it."))",
                "  fi",
            ]
        }
        lines += [#"  touch "$session/prepared""#, "fi", ""]
        return lines.joined(separator: "\n")
    }
}
