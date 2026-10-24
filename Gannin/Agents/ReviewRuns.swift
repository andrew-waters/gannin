import Foundation

/// A review of a PR run through a workflow of more than Gannin's one step
/// (andrew-waters/gannin#466), kept on its lead review session: the session
/// `review(of:)` finds, which runs the first stage's first Claude Code step
/// itself and holds the run's merged result. Every other step is a
/// read-only helper session under it (or a one-shot CLI run in a throwaway
/// copy), so Post Review, the approval queue, records and auto review all
/// act on one review per run, as they always have.
struct ReviewRun: Codable, Hashable {
    var workflowID: String
    var workflowName: String
    var steps: [ReviewStepRun]
    /// The stage running now.
    var stage: Int = 0
    var startedAt: Date = .now
    var finishedAt: Date?
    /// Started by auto review, so a relaunch puts it back among the
    /// automatic runs (capped, and posted as one).
    var automatic: Bool?

    var stageCount: Int { (steps.map(\.stage).max() ?? 0) + 1 }

    func steps(inStage stage: Int) -> [Int] { steps.indices.filter { steps[$0].stage == stage } }

    /// Findings from every step before `stage`, labelled, for the steps in
    /// it: a step sees earlier stages', never those beside it.
    func earlierFindings(before stage: Int) -> [SessionTranscript.Finding] {
        steps.filter { $0.stage < stage }.flatMap { step in step.findings.map { finding in
            var labelled = finding
            labelled.reviewer = step.title
            return labelled
        } }
    }
}

/// One step of a run: who runs it, how far it got, and what each of its
/// rounds found.
struct ReviewStepRun: Codable, Hashable, Identifiable {
    enum State: String, Codable {
        case waiting, running, done, skipped
    }

    var id: String
    var stage: Int
    /// The specialist's title, else "Gannin's review".
    var title: String
    var specialist: String?
    /// A `ProviderID`, as the step named it.
    var provider: String
    var model: String?
    var focus: String?
    var rounds: Int
    /// Its review session: the lead's for the lead step, a helper's for
    /// another Claude Code step; nil for a one-shot step.
    var session: UUID?
    /// Each round's result, in order.
    var results: [SessionTranscript.ReviewResult] = []
    var state: State = .waiting
    /// Why it was skipped, or what went wrong.
    var note: String?
    /// The one-shot run going now, for cancelling it.
    var run: UUID?

    /// Every round's findings, once each.
    var findings: [SessionTranscript.Finding] {
        var seen: Set<String> = []
        return results.flatMap(\.findings).filter { seen.insert(ReviewRunMerge.identity($0)).inserted }
    }

    var isFinished: Bool { state == .done || state == .skipped }
}

/// On a step's helper: whose run, which step.
struct ReviewStepReference: Codable, Hashable {
    var lead: UUID
    var step: String
}

/// Turning a run's steps into the one review it posts.
enum ReviewRunMerge {
    /// What makes two findings one across rounds of the same reviewer: the
    /// same line and the same start to what it says. Two different points
    /// on one line stay two.
    static func identity(_ finding: SessionTranscript.Finding) -> String {
        finding.key
    }

    /// The findings a round adds to those before it.
    static func added(_ result: SessionTranscript.ReviewResult, after earlier: [SessionTranscript.ReviewResult]) -> [SessionTranscript.Finding] {
        let seen = Set(earlier.flatMap(\.findings).map(identity))
        return result.findings.filter { !seen.contains(identity($0)) }
    }

    /// Whether a step goes on to another round: it has rounds left and its
    /// last round found something new (the first round counts its findings).
    static func wantsAnotherRound(_ step: ReviewStepRun) -> Bool {
        guard step.results.count < step.rounds, let last = step.results.last else { return false }
        return !added(last, after: Array(step.results.dropLast())).isEmpty
    }

    /// The strictest of the steps' verdicts.
    static func strictest(_ verdicts: [String?]) -> String? {
        let order = ["request_changes", "comment", "approve"]
        return order.first { verdicts.contains($0) } ?? verdicts.compactMap { $0 }.first
    }

    /// One review from the run: findings merged by file and line, each
    /// labelled with its step (Pair review's merge), the strictest verdict,
    /// one summary saying what each step found and which didn't run, and the
    /// rest (headline, walkthrough, threads to resolve) from the lead step.
    static func combined(_ run: ReviewRun, lead: UUID) -> SessionTranscript.ReviewResult {
        let answered = run.steps.filter { !$0.results.isEmpty }
        // The lead's rounds, latest first, then everyone else's: a later
        // round asks only for what's new, so its headline or walkthrough
        // may be missing.
        let leadRounds = (answered.first { $0.session == lead } ?? answered.first)?.results.reversed() ?? []
        func latest<T>(_ field: (SessionTranscript.ReviewResult) -> T?) -> T? {
            leadRounds.lazy.compactMap(field).first ?? answered.lazy.flatMap { $0.results.reversed() }.compactMap(field).first
        }
        let findings = PairReview.merge(labelled: answered.map { (reviewer: $0.title, findings: $0.findings) }, labelsEveryComment: answered.count > 1)
            .sorted { $0.severityRank < $1.severityRank }
        /// Every round's summary, in order.
        func said(_ step: ReviewStepRun) -> String { step.results.map(\.summary).filter { !$0.isEmpty }.joined(separator: " ") }
        var summary: [String] = []
        if answered.count == 1, let only = answered.first {
            summary.append(said(only))
        } else {
            summary += answered.map { "**\($0.title)**: \(said($0))" }
        }
        let skipped = run.steps.filter { $0.state == .skipped }
        if !skipped.isEmpty {
            summary.append("Not run: " + skipped.map { "\($0.title)\($0.note.map { " (\($0))" } ?? "")" }.joined(separator: "; ") + ".")
        }
        var result = SessionTranscript.ReviewResult(
            summary: summary.joined(separator: "\n\n"),
            verdict: strictest(answered.flatMap { $0.results.map(\.verdict) }),
            findings: findings
        )
        result.resolved = leadRounds.first?.resolved
        result.learnings = answered.flatMap { $0.results.flatMap { $0.learnings ?? [] } }.nilIfEmpty
        result.applied = latest(\.applied)
        result.headline = latest(\.headline)
        result.effort = answered.flatMap { $0.results.compactMap(\.effort) }.max()
        result.walkthrough = latest(\.walkthrough)
        result.flow = latest(\.flow)
        result.checks = latest(\.checks)
        return result
    }
}

private extension Array {
    var nilIfEmpty: Self? { isEmpty ? nil : self }
}

extension SessionStore {
    // MARK: Starting a run

    /// The run a review of `pr` makes for `workflow`, nil for a plain one
    /// (Gannin's one step, as reviews always ran). Every step gets its
    /// specialist's defaults where it sets none; the first stage's first
    /// Claude Code step is the lead's own, and with none there the lead runs
    /// Gannin's own step beside them.
    func reviewRun(for workflow: AgentWorkflow, org: String, setup: HarnessConfig) -> ReviewRun? {
        guard !workflow.isPlain else { return nil }
        let specialists = specialists(org: org, setup: setup)
        var steps: [ReviewStepRun] = []
        for (stage, workflowStage) in workflow.stages.enumerated() {
            for step in workflowStage.steps {
                let specialist = step.specialist.flatMap { specialists[$0.lowercased()] }
                var run = ReviewStepRun(
                    id: step.id, stage: stage, title: specialist?.title ?? step.specialist ?? "Gannin's review", specialist: step.specialist,
                    provider: (step.provider ?? specialist?.provider)?.lowercased() ?? ProviderID.claudeCode.rawValue,
                    model: (step.model ?? specialist?.model).flatMap { $0.isEmpty ? nil : $0 },
                    focus: HarnessSpecialist.focus(step: step.focus, specialist: specialist?.focus),
                    rounds: step.roundCount
                )
                if let name = step.specialist, specialist == nil {
                    run.note = "The specialist \(name) isn't in \(setup.repo), so Gannin's own prompt ran."
                }
                steps.append(run)
            }
        }
        if !steps.contains(where: { $0.stage == 0 && Self.isClaudeStep($0) }) {
            steps.insert(ReviewStepRun(id: AgentWorkflow.builtInID, stage: 0, title: "Gannin's review", provider: ProviderID.claudeCode.rawValue, rounds: 1), at: 0)
        }
        guard !steps.isEmpty else { return nil }
        return ReviewRun(workflowID: workflow.id, workflowName: workflow.name, steps: steps)
    }

    /// A step on Claude Code, or on a provider this build reads as it.
    static func isClaudeStep(_ step: ReviewStepRun) -> Bool {
        ProviderID(name: step.provider)?.isInteractive == true
    }

    /// The lead step: the first stage's first Claude Code step.
    static func leadStep(of run: ReviewRun) -> Int? {
        run.steps.firstIndex { $0.stage == 0 && isClaudeStep($0) }
    }

    /// What a step's session is told besides Gannin's review prompt: who it
    /// is and its focus, that it's one step of several, and what earlier
    /// stages found.
    static func stepInstructions(_ step: ReviewStepRun, of run: ReviewRun, specialist: HarnessSpecialist?) -> String {
        var parts: [String] = []
        if let specialist {
            parts.append(specialist.instructions(focus: step.focus))
        } else if let focus = step.focus {
            parts.append("Your focus: \(focus)")
        }
        if run.steps.count > 1 {
            parts.append("You're one step of the team's \(run.workflowName) review: other reviewers look at this PR too, each with their own focus, so keep to yours. Another step may already have checked the PR out at the path above; use that checkout if it's there.")
        }
        let earlier = run.earlierFindings(before: step.stage)
        if !earlier.isEmpty {
            parts.append("Earlier steps found these. Don't raise them again; say in your summary if you disagree with one.\n\n" + Self.findingList(earlier))
        }
        return parts.joined(separator: "\n\n")
    }

    static func findingList(_ findings: [SessionTranscript.Finding]) -> String {
        findings.map { "- `\($0.path)\($0.line.map { ":\($0)" } ?? "")`: \($0.comment)\($0.reviewer.map { " (\($0))" } ?? "")" }.joined(separator: "\n")
    }

    /// Asks a step's session to look again for what its rounds so far
    /// missed. Nothing is edited.
    static func roundPrompt(_ pr: PullRequestReference, round: Int, of rounds: Int, found: [SessionTranscript.Finding]) -> String {
        let list = found.isEmpty ? "Nothing yet." : findingList(found)
        return """
            Round \(round) of \(rounds): look at \(pr.repo)#\(pr.number) again for what you've missed so far, keeping to your focus. \
            This is still a review: don't edit any files. Your earlier rounds found:

            \(list)

            Don't repeat those. End the same way with the fenced JSON block, with only new findings in `findings` (an empty list \
            if there are none) and a summary of this round.
            """
    }

    // MARK: Moving a run on

    /// Starts what the run's current stage still waits for, moves to the
    /// next stage once every step in it has finished, and finishes the run
    /// after the last. An automatic run's steps start only while there's
    /// room under the automatic review cap; the rest wait for a free slot.
    func advanceRun(_ lead: UUID) {
        guard var run = sessions[lead]?.reviewRun, run.finishedAt == nil else { return }
        while true {
            let indices = run.steps(inStage: run.stage)
            if indices.allSatisfy({ run.steps[$0].isFinished }) {
                if run.stage + 1 >= run.stageCount {
                    update(lead) { $0.reviewRun = run }
                    finishRun(lead)
                    return
                }
                run.stage += 1
                continue
            }
            update(lead) { $0.reviewRun = run }
            // Read afresh each time: a step skipped as it starts moves the
            // run on itself, which may already have started the next.
            for index in indices where sessions[lead]?.reviewRun?.steps[safe: index]?.state == .waiting {
                guard hasRoomForStep(of: lead) else { break }
                startStep(index, of: lead)
            }
            return
        }
    }

    /// Whether another of the run's steps can start now: always for a run
    /// started by hand; for an automatic one, while the automatic reviews
    /// running (step sessions counted) are under the open window's limit,
    /// else the cap.
    private func hasRoomForStep(of lead: UUID) -> Bool {
        guard automaticRuns.contains(lead), let org = sessions[lead]?.org else { return true }
        var limit = AutoReview.maxRunning
        if case .start(let room) = reviewGate(org) { limit = room }
        return automaticReviewsRunning < limit
    }

    /// Steps of automatic runs waiting for a slot, tried again whenever a
    /// step or review finishes.
    func advanceWaitingRuns() {
        for lead in automaticRuns where sessions[lead]?.reviewRun?.finishedAt == nil && sessions[lead]?.reviewRun != nil {
            advanceRun(lead)
        }
    }

    private func startStep(_ index: Int, of leadID: UUID) {
        guard let lead = sessions[leadID], var run = lead.reviewRun, let pr = lead.reviewOf,
              run.steps.indices.contains(index), run.steps[index].state == .waiting else { return }
        var step = run.steps[index]
        if step.session == leadID {
            // The lead's own: its claude started with the review.
            step.state = .running
            run.steps[index] = step
            update(leadID) { $0.reviewRun = run }
            return
        }
        guard let provider = ProviderID(name: step.provider) else {
            skipStep(index, of: leadID, because: "\(step.provider) isn't a provider this Gannin knows")
            return
        }
        guard let setup = lead.harnessRepo.map({ HarnessConfig(repo: $0) }) else {
            skipStep(index, of: leadID, because: "the review has no harness")
            return
        }
        let specialist = step.specialist.flatMap { specialists(org: lead.org, setup: setup)[$0.lowercased()] }
        step.state = .running
        if let extra = provider.extraReviewer {
            let tag = UUID()
            step.run = tag
            run.steps[index] = step
            update(leadID) { $0.reviewRun = run }
            runOneShotStep(index, extra, tag: tag, lead: leadID, pr: pr, specialist: specialist)
            return
        }
        let id = UUID()
        step.session = id
        run.steps[index] = step
        update(leadID) { $0.reviewRun = run }
        Task {
            let learnings = await reviewLearnings(org: lead.org, harnessRepo: lead.harnessRepo, repo: pr.repo, number: pr.number)
            let base = Self.pullRequestReviewPrompt(pr, branch: lead.branch, learnings: learnings, config: lead.reviewConfig ?? ReviewConfig())
            guard let current = sessions[leadID]?.reviewRun, current.steps.indices.contains(index) else { return }
            var helper = CodeSession(
                id: id, issue: lead.issue, repo: lead.repo, branch: lead.branch, createdAt: .now,
                connect: lead.connect, remoteWorkspace: lead.remoteWorkspace,
                harnessRepo: lead.harnessRepo, harnessPath: lead.harnessPath, harnessFolder: lead.harnessFolder,
                parentID: leadID, role: step.title,
                prompt: base + "\n\n" + Self.stepInstructions(step, of: current, specialist: specialist),
                instructions: lead.instructions, isReviewer: true
            )
            helper.provider = provider
            helper.model = step.model
            helper.reviewConfig = lead.reviewConfig
            helper.reviewStep = ReviewStepReference(lead: leadID, step: step.id)
            Self.noteFolder(of: helper)
            let directory = Self.directory(for: id)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: Self.directory(for: leadID).appending(path: "brief.md"), to: directory.appending(path: "brief.md"))
            add(helper)
            addTab(id, after: leadID)
            _ = open(helper)
        }
    }

    private func skipStep(_ index: Int, of lead: UUID, because why: String) {
        guard var run = sessions[lead]?.reviewRun, run.steps.indices.contains(index) else { return }
        run.steps[index].state = .skipped
        run.steps[index].note = why
        run.steps[index].run = nil
        update(lead) { $0.reviewRun = run }
        advanceRun(lead)
        advanceWaitingRuns()
    }

    // MARK: Results

    /// A round's result from a step's session (the lead's or a helper's):
    /// kept, then another round asked for if the step has rounds left and
    /// this one found something new, else the step is done and the run
    /// moves on. A result read again (the same as the last) is ignored.
    func stepResult(_ result: SessionTranscript.ReviewResult, from sessionID: UUID) {
        let lead = sessions[sessionID]?.reviewStep?.lead ?? sessionID
        guard var run = sessions[lead]?.reviewRun, run.finishedAt == nil,
              let index = run.steps.firstIndex(where: { $0.session == sessionID && $0.state == .running }),
              run.steps[index].results.last != result else { return }
        run.steps[index].results.append(result)
        let step = run.steps[index]
        if ReviewRunMerge.wantsAnotherRound(step), let pr = sessions[lead]?.reviewOf {
            update(lead) { $0.reviewRun = run }
            let prompt = Self.roundPrompt(pr, round: step.results.count + 1, of: step.rounds, found: step.findings)
            if isRunning(sessionID), state(sessionID) == .idle, submit(prompt, to: sessionID) { return }
            pendingPrompts[sessionID] = prompt
            if !isRunning(sessionID), let session = sessions[sessionID] { _ = open(session) }
            return
        }
        run.steps[index].state = .done
        update(lead) { $0.reviewRun = run }
        advanceRun(lead)
        advanceWaitingRuns()
    }

    /// A step's session ended without its review: the step is marked as
    /// not run, so the rest of the run isn't held up.
    func stepEnded(_ sessionID: UUID) {
        let lead = sessions[sessionID]?.reviewStep?.lead ?? sessionID
        guard let run = sessions[lead]?.reviewRun, run.finishedAt == nil,
              let index = run.steps.firstIndex(where: { $0.session == sessionID && $0.state == .running }) else { return }
        if run.steps[index].results.isEmpty {
            skipStep(index, of: lead, because: "its session ended without a review")
        } else {
            var run = run
            run.steps[index].state = .done
            update(lead) { $0.reviewRun = run }
            advanceRun(lead)
            advanceWaitingRuns()
        }
    }

    /// A step's helper is being removed while its step runs: the step is
    /// marked as not run (or done, with the rounds it gave), so the run
    /// goes on. Called before the session goes, while it still says whose
    /// step it is.
    func stepClosed(_ sessionID: UUID) {
        guard let lead = sessions[sessionID]?.reviewStep?.lead, var run = sessions[lead]?.reviewRun, run.finishedAt == nil,
              let index = run.steps.firstIndex(where: { $0.session == sessionID && $0.state == .running }) else { return }
        if run.steps[index].results.isEmpty {
            skipStep(index, of: lead, because: "its session was closed")
        } else {
            run.steps[index].state = .done
            update(lead) { $0.reviewRun = run }
            advanceRun(lead)
            advanceWaitingRuns()
        }
    }

    /// After a relaunch: an automatic run is one again; one-shot steps that
    /// were running died with the app, so they're marked as not run; steps
    /// whose session is gone are too. A running step's session is opened
    /// again, so a review it had written is read, and each unfinished run
    /// moves on.
    func resumeReviewRuns() {
        for (lead, session) in sessions where session.reviewRun.map({ $0.finishedAt == nil }) ?? false {
            guard var run = session.reviewRun else { continue }
            // `automaticRuns` isn't saved: before anything starts, so its
            // steps are capped and its review is posted as an automatic one.
            if run.automatic == true { automaticRuns.insert(lead) }
            for index in run.steps.indices where run.steps[index].state == .running {
                if let id = run.steps[index].session, sessions[id] != nil { continue }
                run.steps[index].state = .skipped
                run.steps[index].note = run.steps[index].session == nil ? "Gannin quit while it ran" : "its session is gone"
                run.steps[index].run = nil
            }
            update(lead) { $0.reviewRun = run }
            for step in run.steps where step.state == .running {
                if let id = step.session, let running = sessions[id], !isRunning(id) { _ = open(running) }
            }
            advanceRun(lead)
        }
    }

    /// Every step has finished: the merged review becomes the lead's
    /// result, which Post Review, the approval queue, records and auto
    /// review take from there.
    private func finishRun(_ lead: UUID) {
        guard var run = sessions[lead]?.reviewRun, run.finishedAt == nil else { return }
        run.finishedAt = .now
        let result = ReviewRunMerge.combined(run, lead: lead)
        update(lead) {
            $0.reviewRun = run
            $0.reviewResult = result
        }
        reviewDrafts[lead, default: sessions[lead]?.reviewDraft ?? ReviewDraft()].resultAt = .now
        save()
        reviewFinished(lead)
        advanceWaitingRuns()
    }

    /// Stops the one-shot steps still going, when their run's review is
    /// removed.
    func cancelRunSteps(of session: CodeSession) {
        for step in session.reviewRun?.steps ?? [] where step.state == .running {
            guard let tag = step.run, let extra = ProviderID(name: step.provider)?.extraReviewer else { continue }
            let script = extra.cancelScript(tag: tag.uuidString)
            Task.detached { _ = ScriptRunner.run(script, place: .local) }
        }
    }

    // MARK: One-shot steps

    /// A step on a one-shot CLI (Junie): run on this Mac in a throwaway copy
    /// of the PR checked out in the harness, as Pair review's extras are.
    /// Skipped, and marked so, on a server or where the CLI can't run.
    private func runOneShotStep(_ index: Int, _ reviewer: ExtraReviewer, tag: UUID, lead leadID: UUID, pr: PullRequestReference, specialist: HarnessSpecialist?) {
        guard let lead = sessions[leadID], let run = lead.reviewRun, run.steps[safe: index]?.run == tag else { return }
        guard lead.connect == nil, !lead.isSandboxed, let harnessRepo = lead.harnessRepo else {
            skipStep(index, of: leadID, because: "\(reviewer.title) runs only on this Mac")
            return
        }
        let step = run.steps[index]
        let checkout = Self.oneShotCheckout(pr, harness: Self.localHarnessPath(org: lead.org, repo: harnessRepo), branch: lead.branch, tag: tag)
        let prompt = Self.oneShotPrompt(pr, step: step, run: run, specialist: specialist)
        Task {
            let made = await Task.detached { ScriptRunner.run(checkout.make, place: .local) }.value
            let folder = made.output.split(separator: "\n").last.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
            guard made.status == 0, !folder.isEmpty else {
                skipStep(index, of: leadID, because: "the PR couldn't be checked out for \(reviewer.title): \(made.error.isEmpty ? "exit \(made.status)" : made.error)")
                return
            }
            var results: [SessionTranscript.ReviewResult] = []
            var failure: String?
            for round in 1...step.rounds {
                let found = results.flatMap(\.findings)
                let ask = round == 1 ? prompt : prompt + "\n\n" + Self.roundPrompt(pr, round: round, of: step.rounds, found: found)
                let outcome = await reviewer.review(folder: URL(filePath: folder), prompt: ask, tag: tag.uuidString) { script in
                    await Task.detached { ScriptRunner.run(script, place: .local) }.value
                }
                // Stopped, or the review removed, meanwhile.
                guard sessions[leadID]?.reviewRun?.steps[safe: index]?.run == tag else { break }
                switch outcome {
                case .findings(let findings):
                    let result = SessionTranscript.ReviewResult(summary: "\(findings.count) finding\(findings.count == 1 ? "" : "s").", verdict: findings.isEmpty ? "approve" : "comment", findings: findings)
                    results.append(result)
                case .failed(let why, _):
                    failure = why
                }
                if failure != nil || ReviewRunMerge.added(results.last!, after: Array(results.dropLast())).isEmpty { break }
            }
            _ = await Task.detached { ScriptRunner.run(checkout.remove, place: .local) }.value
            guard var current = sessions[leadID]?.reviewRun, current.steps[safe: index]?.run == tag else { return }
            current.steps[index].run = nil
            if results.isEmpty {
                update(leadID) { $0.reviewRun = current }
                skipStep(index, of: leadID, because: failure ?? "\(reviewer.title) gave no review")
                return
            }
            current.steps[index].results = results
            current.steps[index].state = .done
            current.steps[index].note = failure
            update(leadID) { $0.reviewRun = current }
            advanceRun(leadID)
            advanceWaitingRuns()
        }
    }

    /// Bash that checks the PR out, detached, in the review's folder in the
    /// harness (from the repo's clone in `projects/`, or the harness itself
    /// when it's the code repo), printing its path; and bash that removes it.
    static func oneShotCheckout(_ pr: PullRequestReference, harness: String, branch: String, tag: UUID) -> (make: String, remove: String) {
        let name = pr.repo.split(separator: "/").last.map(String.init) ?? pr.repo
        let folder = ".worktrees/\(branch)/\(name)-\(tag.uuidString.prefix(8).lowercased())"
        let guardSteps = SandboxCredentials.isEnabled ? SandboxGitGuard.functions + "\n" : ""
        let find = """
            cd \(SessionScript.shellPath(harness)) || { echo "The harness isn't checked out here." >&2; exit 1; }
            \(guardSteps)if [ -e \(SessionScript.quoted("projects/\(name)"))/.git ]; then g=\(SessionScript.quoted("projects/\(name)"))
            elif git remote get-url origin 2>/dev/null | grep -qiE \(SessionScript.quoted("[/:]\(pr.repo)(\\.git)?/?$")); then g=.
            else echo "\(pr.repo) isn't cloned in the harness's projects/." >&2; exit 1; fi
            \(SandboxCredentials.isEnabled ? "why=$(gannin_check \"$g\") || { echo \"$why\" >&2; exit 1; }\n" : "")
            """
        let make = find + """
            git -C "$g" fetch --quiet origin \(SessionScript.quoted("pull/\(pr.number)/head")) || exit 1
            mkdir -p \(SessionScript.quoted(".worktrees/\(branch)"))
            git -C "$g" worktree add --quiet --detach "$PWD"/\(SessionScript.quoted(folder)) FETCH_HEAD >&2 || exit 1
            echo "$PWD"/\(SessionScript.quoted(folder))
            """
        let remove = find + #"git -C "$g" worktree remove --force "$PWD"/"# + SessionScript.quoted(folder) + " 2>/dev/null || rm -rf \"$PWD\"/\(SessionScript.quoted(folder))\n"
        return (make + "\n", remove)
    }

    /// What a one-shot reviewer is asked: who it is, the PR, the earlier
    /// stages' findings, and the fenced JSON list Pair review's extras end
    /// with.
    static func oneShotPrompt(_ pr: PullRequestReference, step: ReviewStepRun, run: ReviewRun, specialist: HarnessSpecialist?) -> String {
        let instructions = stepInstructions(step, of: run, specialist: specialist)
        return """
            Review pull request \(pr.repo)#\(pr.number), "\(pr.title)" (\(pr.url.absoluteString)), checked out in this folder. This is a \
            review: don't edit any files. `gh pr view \(pr.number) --repo \(pr.repo)` and `gh pr diff \(pr.number) --repo \(pr.repo)` show \
            what it changes. Comment only on lines the diff changes or shows.\(instructions.isEmpty ? "" : "\n\n" + instructions)

            End with your findings as one fenced ```json list, most important first: \
            [{"path": "<path in the repo>", "line": <line in the new file>, "severity": "blocker" | "major" | "minor" | "nit", \
            "category": \(ReviewCategory.promptList), "comment": "<what's wrong and what to do>"}]. When there's nothing to raise, the list is empty (`[]`).
            """
    }

    // MARK: After an interactive session

    /// A PR the session opened gets the review its workflow's steps after
    /// the session make, run by itself in the background, with a note in
    /// the session's activity of where it is.
    func runStepsAfter(_ url: URL, for id: UUID) {
        guard let session = sessions[id], let after = session.workflow?.after, !after.steps.isEmpty,
              let repo = session.harnessRepo, let path = Self.harnessPath(org: session.org, repo: repo) else { return }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 4, parts[2] == "pull", let number = Int(parts[3]) else { return }
        let prRepo = "\(parts[0])/\(parts[1])"
        Task {
            guard let facts = try? await chargingTo(.details, { try await api()?.pullRequestFacts(repo: prRepo, number: number) }) else {
                noteWorkflow("Couldn't look up \(prRepo)#\(number) on GitHub, so \(after.name) didn't review it.", for: id)
                return
            }
            let pr = PullRequestReference(org: session.org, id: facts.id, number: number, title: facts.title, repo: prRepo, url: url)
            let review = await startReview(of: pr, harness: HarnessConfig(repo: repo), harnessPath: path, reveals: false, workflow: after)
            _ = open(review)
            noteWorkflow("Started \(after.name) on \(prRepo)#\(number), as the session's workflow says. Its review is in Reviews.", for: id)
        }
    }

    /// A line for the session's workflow panel: what its steps did.
    func noteWorkflow(_ text: String, for id: UUID) {
        update(id) { session in
            let notes = session.workflow?.notes ?? []
            session.workflow?.notes = notes + [text]
        }
    }

    /// What review routing rules match a PR on: its repo, author, labels
    /// and changed paths. Looked up only when the project has review rules;
    /// a failed lookup matches on the repo alone.
    func reviewSubject(_ pr: PullRequestReference, org: String, setup: HarnessConfig) async -> WorkflowSubject {
        var subject = WorkflowSubject(repo: pr.repo)
        guard !(agentWorkflows(org, setup)[.review].rules ?? []).isEmpty else { return subject }
        if let facts = try? await chargingTo(.details, { try await api()?.pullRequestFacts(repo: pr.repo, number: pr.number) }) {
            subject.author = facts.author
            subject.labels = facts.labels
        }
        subject.paths = (try? await chargingTo(.details, { try await api()?.pullRequestFilePaths(repo: pr.repo, number: pr.number) })) ?? []
        return subject
    }
}

extension GitHubAPI {
    /// A PR's node ID, title, author and labels.
    func pullRequestFacts(repo: String, number: Int) async throws -> (id: String, title: String, author: String?, labels: [String]) {
        struct Label: Decodable { let name: String }
        struct Labels: Decodable { let nodes: [Label?] }
        struct Author: Decodable { let login: String }
        struct PullRequest: Decodable { let id: String; let title: String; let author: Author?; let labels: Labels? }
        struct Repository: Decodable { let pullRequest: PullRequest? }
        struct Response: Decodable { let repository: Repository? }
        let parts = repo.split(separator: "/").map(String.init)
        guard parts.count == 2 else { throw URLError(.badURL) }
        let response: Response = try await query("""
            query($owner: String!, $name: String!, $number: Int!) {
              repository(owner: $owner, name: $name) {
                pullRequest(number: $number) { id title author { login } labels(first: 50) { nodes { name } } }
              }
            }
            """, values: ["owner": parts[0], "name": parts[1], "number": number])
        guard let pr = response.repository?.pullRequest else { throw URLError(.fileDoesNotExist) }
        return (pr.id, pr.title, pr.author?.login, pr.labels?.nodes.compactMap { $0?.name } ?? [])
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
