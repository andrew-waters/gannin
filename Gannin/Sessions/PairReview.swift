import SwiftUI

/// A Work on This session's change reviewed by a second agent before it
/// goes up (andrew-waters/gannin#68, `plans/2026-10-09-pair-review.md`).
/// The working agent runs `ready-for-review` in its folder's `.gannin/`
/// (`SessionScript.readyForReview`); Gannin starts a reviewer helper, which
/// can't edit, pastes its findings back, and asks it to look again each
/// time the working agent says it has dealt with them, until a round finds
/// nothing, `maxRounds` have gone, or you stop it.
struct PairReview: Codable, Hashable {
    enum Phase: String, Codable {
        /// The reviewer is looking.
        case reviewing
        /// Its findings went to the working agent, which is dealing with them.
        case fixing
        /// A round found nothing more.
        case settled
        /// `maxRounds` went by with findings still coming.
        case limit
        /// You stopped it, or the reviewer couldn't go on (`note`).
        case stopped
    }

    static let maxRounds = 3

    /// The reviewer helper; nil until the first request.
    var reviewerID: UUID?
    /// Rounds the reviewer has finished.
    var round = 0
    var phase: Phase = .reviewing
    /// The reviewer's reply last taken as a round, by its transcript ID, so
    /// a transcript read again (a relaunch) isn't taken twice.
    var lastReply: String?
    /// The last round's findings.
    var findings = 0
    var endedAt: Date?
    /// Why it stopped, when it wasn't you.
    var note: String?
    /// The claude reviewer's findings this round, once it has answered and
    /// until the round finishes (`finishMergedRound`).
    var claudeFindings: [SessionTranscript.Finding]?
    /// This round's extra reviewers, by `ExtraReviewer.id`: those that
    /// started, and how each is getting on. Kept after the round for the
    /// panel, until the next one starts.
    var extras: [String: ExtraReview]?

    /// An extra reviewer's part in a round.
    struct ExtraReview: Codable, Hashable {
        enum State: String, Codable {
            case running
            /// Its findings (possibly none) are in `findings`.
            case answered
            /// It couldn't review; `message` says why. It counts as having
            /// found nothing, so the round isn't held up.
            case failed
        }

        var state: State = .running
        var findings: [SessionTranscript.Finding] = []
        var message: String?
        /// Which start of the reviewer this is, so one that outlives its
        /// round (you stopped the loop and started another) can't answer
        /// for the new one.
        var run = UUID()
    }

    var isOver: Bool { [.settled, .limit, .stopped].contains(phase) }

    /// Fails any extra still running in a round that is waiting on it: one
    /// saved by a Gannin that quit mid-round has no run left to answer, and
    /// would hold the round up for good. A review you stopped keeps its
    /// extras as they were, since it wasn't the quit that ended them.
    /// Returns whether there was one.
    mutating func abandonRunningExtras(_ message: String) -> Bool {
        guard phase == .reviewing else { return false }
        var found = false
        for (id, extra) in extras ?? [:] where extra.state == .running {
            extras?[id]?.state = .failed
            extras?[id]?.message = message
            found = true
        }
        return found
    }

    /// Starts a round's extra reviewers, none having answered.
    mutating func startExtras(_ reviewers: [ExtraReviewer]) {
        claudeFindings = nil
        extras = reviewers.isEmpty ? nil : Dictionary(uniqueKeysWithValues: reviewers.map { ($0.id, ExtraReview()) })
    }

    var isWaitingOnExtras: Bool { extras?.values.contains { $0.state == .running } ?? false }

    mutating func claudeAnswered(_ findings: [SessionTranscript.Finding], reply: String) {
        claudeFindings = findings
        lastReply = reply
    }

    /// Records an extra reviewer's outcome, if it's the run this round is
    /// waiting on. Returns whether it was.
    mutating func extraFinished(_ reviewer: ExtraReviewer, run: UUID, outcome: ExtraReviewer.Outcome) -> Bool {
        guard phase == .reviewing, var extra = extras?[reviewer.id], extra.state == .running, extra.run == run else { return false }
        switch outcome {
        case .findings(let findings):
            extra.state = .answered
            extra.findings = findings
        case .failed(let message):
            extra.state = .failed
            extra.message = message
        }
        extras?[reviewer.id] = extra
        return true
    }

    /// Claude has answered and every extra that started has too (or failed).
    var isRoundComplete: Bool { claudeFindings != nil && !isWaitingOnExtras }

    /// Claude's findings and those of the extras that answered, as one list.
    var mergedFindings: [SessionTranscript.Finding] {
        let answered = ExtraReviewer.allCases.compactMap { reviewer in
            extras?[reviewer.id].flatMap { $0.state == .answered ? (reviewer.title, $0.findings) : nil }
        }
        return Self.merge(claude: claudeFindings ?? [], extras: answered)
    }

    /// Finishes the round with the merged findings.
    mutating func finishMergedRound(at date: Date = .now) {
        finishRound(findings: mergedFindings.count, reply: lastReply ?? "", at: date)
        claudeFindings = nil
    }

    /// One list from the reviewers' lists, claude's first. Findings from
    /// different reviewers on the same line of the same file are one, credited
    /// to both with each one's comment (two models rarely word a problem the
    /// same way); two on the same line from one reviewer stay separate, as do
    /// ones with no line. With no extra reviewer's list it is claude's,
    /// unlabelled; with one, every finding says who raised it.
    static func merge(claude: [SessionTranscript.Finding], extras: [(reviewer: String, findings: [SessionTranscript.Finding])]) -> [SessionTranscript.Finding] {
        guard !extras.isEmpty else { return claude }
        /// A finding and who said what about it.
        struct Merged {
            var finding: SessionTranscript.Finding
            var says: [(reviewer: String, comment: String)]
        }
        var merged: [Merged] = []
        for (reviewer, findings) in [("claude", claude)] + extras.map({ ($0.reviewer, $0.findings) }) {
            for finding in findings {
                let match: Int? = finding.line == nil ? nil : merged.firstIndex { entry in
                    entry.finding.path == finding.path && entry.finding.line == finding.line && !entry.says.contains { $0.reviewer == reviewer }
                }
                if let match {
                    merged[match].says.append((reviewer, finding.comment))
                } else {
                    merged.append(Merged(finding: finding, says: [(reviewer, finding.comment)]))
                }
            }
        }
        return merged.map { entry in
            var labelled = entry.finding
            labelled.reviewer = entry.says.map(\.reviewer).joined(separator: " and ")
            let comments = entry.says.map(\.comment)
            // Said the same by all of them, or each in their own words.
            labelled.comment = Set(comments).count == 1 ? comments[0] : entry.says.map { "\($0.reviewer): \($0.comment)" }.joined(separator: " ")
            return labelled
        }
    }

    /// A round the reviewer finished with `findings`: settled with none,
    /// at the limit on the last round, else back to the working agent.
    mutating func finishRound(findings: Int, reply: String, at date: Date = .now) {
        round += 1
        self.findings = findings
        lastReply = reply
        phase = findings == 0 ? .settled : round >= Self.maxRounds ? .limit : .fixing
        if isOver { endedAt = date }
    }

    /// The same in a word or two, for a tab, with its colour.
    var shortStatus: String {
        switch phase {
        case .reviewing: "Reviewing"
        case .fixing: "\(findings) to fix"
        case .settled: "Reviewed"
        case .limit: "Last round"
        case .stopped: "Review stopped"
        }
    }

    var tint: Color {
        switch phase {
        case .reviewing: ChartPalette.blue
        case .fixing, .limit: .orange
        case .settled: .green
        case .stopped: .secondary
        }
    }

    /// What it's doing or how it ended, in a line.
    var status: String {
        let rounds = "\(round) round\(round == 1 ? "" : "s")"
        let found = "\(findings) finding\(findings == 1 ? "" : "s")"
        switch phase {
        case .reviewing: return "Round \(round + 1) of \(Self.maxRounds): the reviewer is looking"
        case .fixing: return "Round \(round) of \(Self.maxRounds): \(found) sent back, being dealt with"
        case .settled: return "Settled after \(rounds): nothing more to fix"
        case .limit: return "Stopped after \(rounds), the last with \(found)"
        case .stopped: return note ?? "Stopped by you after \(rounds)"
        }
    }
}

extension CodeSession {
    /// Issue sessions only: not helpers, reviews of PRs, plans or Asks.
    var canPairReview: Bool { !isHelper && !isPullRequestReview && !isPlanning && !isAsk && !isRefine }

    /// The script that asks for a review, as claude runs it from where it
    /// starts (the harness root, or an older session's worktree).
    var readyForReviewScript: String {
        isInHarness ? ".worktrees/\(branch)/.gannin/ready-for-review" : ".gannin/ready-for-review"
    }
}

extension SessionStore {
    /// Review sessions' work with a second agent by default.
    static let pairReviewKey = "pairReview"

    /// The session's own choice, else the user's default (on).
    func pairsReview(_ id: UUID) -> Bool {
        sessions[id]?.pairsReview ?? (UserDefaults.standard.object(forKey: Self.pairReviewKey) as? Bool ?? true)
    }

    func setPairsReview(_ isOn: Bool, for id: UUID) {
        update(id) { $0.pairsReview = isOn }
    }

    /// The working session whose pair reviewer this is.
    func pairReviewed(by reviewerID: UUID) -> CodeSession? {
        guard let parentID = sessions[reviewerID]?.parentID, let parent = sessions[parentID],
              parent.pairing?.reviewerID == reviewerID else { return nil }
        return parent
    }

    /// Whether a session's turn ending shouldn't flag you: a pair reviewer
    /// (its rounds go to the working agent), or the working agent waiting
    /// on one. The loop's end flags you instead.
    func isQuietForPairReview(_ id: UUID) -> Bool {
        pairReviewed(by: id) != nil || sessions[id]?.pairing?.phase == .reviewing
    }

    /// The harness's learnings for the session's repos and its PRs', for a
    /// reviewer to follow.
    func reviewLearnings(for parent: CodeSession) -> [HarnessLearning] {
        let repos = [parent.issue.repo] + (pullRequestInfo[parent.id] ?? []).map(\.repo)
        var seen: Set<String> = []
        return (harnessStore.anyIndex(org: parent.org, repo: parent.harnessRepo ?? parent.repo).map { index in repos.flatMap { index.learnings(for: $0) } } ?? [])
            .filter { seen.insert($0.id).inserted }
    }

    /// The hook file's line: a token new each run, then the note.
    func reviewRequestRead(_ line: String, for id: UUID) {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard let token = parts.first, let session = sessions[id], session.reviewRequest != token else { return }
        update(id) { $0.reviewRequest = token }
        guard session.canPairReview else { return }
        reviewRequested(id, note: parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : "")
    }

    /// The working agent says its change is ready (or you asked, `byYou`):
    /// the reviewer starts, or looks again. Off, or once the loop's ended
    /// at its limit or by you, claude is told to carry on instead.
    func reviewRequested(_ id: UUID, note: String, byYou: Bool = false) {
        guard let session = sessions[id], session.canPairReview else { return }
        guard byYou || pairsReview(id) else {
            deliver("Pair review is off for this session, so no second agent will look at the change. Carry on.", to: id)
            return
        }
        pairReviewProblems[id] = nil
        // Findings go to claude's prompt, so without claude they'd have nowhere to land.
        if byYou, !isRunning(id) {
            pairReviewProblems[id] = "Claude Code isn't running in this session's tab, so there's nowhere to send findings. Open the session first."
            return
        }
        var pairing = session.pairing ?? PairReview()
        replaceFailedReviewer(of: id, in: &pairing)
        if pairing.isOver {
            if !byYou, pairing.phase != .settled {
                deliver("The review by a second agent has ended (\(pairing.status.lowercased())), so no reviewer will look again. Carry on, and leave anything outstanding for the pull request's description.", to: id)
                return
            }
            // More changes since it settled, or you asked: a fresh loop.
            pairing = PairReview(reviewerID: pairing.reviewerID, lastReply: pairing.lastReply)
        } else if pairing.phase == .reviewing, pairing.reviewerID.flatMap({ sessions[$0] }) != nil {
            // Already looking: it'll see the change as it is when it reads it.
            return
        }
        // A round still waiting on an extra from before (its reviewer was
        // replaced) is over, so its run mustn't go on beside the new one.
        cancelRunningExtras(of: session.pairing)
        let said = note.isEmpty ? "" : "\n\nThe agent working on it says: \(note)"
        let extras = enabledExtraReviewers(for: session)
        if let reviewerID = pairing.reviewerID, let reviewer = sessions[reviewerID] {
            pairing.phase = .reviewing
            pairing.startExtras(extras)
            update(id) { $0.pairing = pairing }
            startExtraReviewers(extras, for: session, said: said)
            let folder = session.isInHarness ? ".worktrees/\(session.branch)/" : "the worktree"
            let prompt = """
                The agent working on \(session.longReference) has changed things since your last look.\(said)

                Look at every change in \(folder) again as it is now, committed or not. Leave out findings it has dealt with, \
                and don't raise again ones it explained away unless you still disagree, saying why. Don't edit anything. \
                End the same way with the fenced JSON list, empty (`[]`) when there's nothing left to fix.
                """
            send(prompt, toReviewer: reviewer)
            if byYou { reveal(reviewer.id) }
        } else {
            let learnings = reviewLearnings(for: session)
            let prompt = Self.reviewPrompt(for: session, learnings: learnings) + said + """


                Gannin passes your findings to that agent and asks you to look again once it has dealt with them. \
                When there's nothing to fix, end with an empty list (`[]`).
                """
            guard let reviewer = startHelper(for: id, role: "Review", prompt: prompt, reviewer: true, reveals: false) else { return }
            pairing.reviewerID = reviewer.id
            pairing.phase = .reviewing
            pairing.startExtras(extras)
            update(id) { $0.pairing = pairing }
            startExtraReviewers(extras, for: session, said: said)
            _ = open(reviewer)
            if byYou { reveal(reviewer.id) }
        }
    }

    /// The project's extra reviewers that can run for the session: only on
    /// this Mac and outside a sandbox, since they use a CLI installed and
    /// signed in here.
    func enabledExtraReviewers(for session: CodeSession) -> [ExtraReviewer] {
        guard !session.isRemote, !session.isSandboxed, Self.worktree(for: session) != nil else { return [] }
        return extraReviewers(session)
    }

    /// Runs each extra reviewer once, on a copy of the worktree, and takes
    /// its outcome into the round. The prompt is the claude reviewer's
    /// first one, pointed at the copy.
    private func startExtraReviewers(_ reviewers: [ExtraReviewer], for session: CodeSession, said: String) {
        guard !reviewers.isEmpty, let folder = Self.worktree(for: session) else { return }
        let prompt = Self.reviewPrompt(for: session, learnings: reviewLearnings(for: session), inCopy: true) + said
        for reviewer in reviewers {
            guard let run = sessions[session.id]?.pairing?.extras?[reviewer.id]?.run else { continue }
            Task {
                let outcome = await reviewer.review(folder: folder, prompt: prompt, tag: run.uuidString) { script in
                    await Task.detached { ClaudeRunner.run(script, place: .local) }.value
                }
                extraFinished(reviewer, run: run, outcome: outcome, for: session.id)
            }
        }
    }

    /// Stops the extras `pairing` is still waiting on, on a copy of the
    /// worktree each. Their results would be ignored anyway; this saves the
    /// CPU, disk and quota until their own timeout.
    func cancelRunningExtras(of pairing: PairReview?) {
        for (id, extra) in pairing?.extras ?? [:] where extra.state == .running {
            guard let reviewer = ExtraReviewer(rawValue: id) else { continue }
            let script = reviewer.cancelScript(tag: extra.run.uuidString)
            Task.detached { _ = ClaudeRunner.run(script, place: .local) }
        }
    }

    /// An extra reviewer's run ended: its findings, or why it has none,
    /// join the round, which finishes if nothing else is awaited.
    func extraFinished(_ reviewer: ExtraReviewer, run: UUID, outcome: ExtraReviewer.Outcome, for id: UUID) {
        guard var pairing = sessions[id]?.pairing, pairing.extraFinished(reviewer, run: run, outcome: outcome) else { return }
        update(id) { $0.pairing = pairing }
        finishRoundIfReady(id)
    }

    /// Forgets the pairing's reviewer when its sandbox failed to start: a
    /// prompt sent to it would wait for a claude that never started, and a
    /// reviewer still `reviewing` would hide the request. The cleared
    /// pairing is kept before a new reviewer is made, so a failure to make
    /// one doesn't repeat this. Returns whether it did.
    @discardableResult
    func replaceFailedReviewer(of id: UUID, in pairing: inout PairReview) -> Bool {
        guard let reviewerID = pairing.reviewerID, sessions[reviewerID]?.isSandboxed == true,
              SandboxStatus(sandboxStatus[reviewerID]).state == .failed else { return false }
        pendingPrompts[reviewerID] = nil
        remove(reviewerID)
        pairing.reviewerID = nil
        pairing.lastReply = nil
        update(id) { $0.pairing = pairing }
        return true
    }

    /// Pasted now if the reviewer's waiting, else once it is, resuming it
    /// if it isn't running or claude has exited and left its shell.
    private func send(_ prompt: String, toReviewer reviewer: CodeSession) {
        let id = reviewer.id
        guard isRunning(id) else {
            pendingPrompts[id] = prompt
            _ = open(reviewer)
            return
        }
        switch state(id) {
        case .idle:
            submit(prompt, to: id)
        case .starting, .working, .needsYou:
            pendingPrompts[id] = prompt
        case .exited, .stopped:
            // Only the shell is left: a paste would go to bash, so start claude again.
            pendingPrompts[id] = prompt
            restart(reviewer)
        }
    }

    /// To the working agent: now if it's waiting for a prompt, else when its
    /// turn ends (or it next starts).
    func deliver(_ text: String, to id: UUID) {
        if isRunning(id), state(id) == .idle {
            submit(text, to: id)
        } else {
            pendingPrompts[id] = [pendingPrompts[id], text].compactMap { $0 }.joined(separator: "\n\n")
        }
    }

    /// A transcript read: if it's a pair reviewer that has just ended a
    /// round with its JSON list, that's claude's part of the round.
    func pairRoundRead(_ reviewerID: UUID) {
        guard let parent = pairReviewed(by: reviewerID), var pairing = parent.pairing, pairing.phase == .reviewing,
              let transcript = transcripts[reviewerID], let reply = transcript.lastReplyID, reply != pairing.lastReply,
              let findings = transcript.listedFindings else { return }
        pairing.claudeAnswered(findings, reply: reply)
        update(parent.id) { $0.pairing = pairing }
        finishRoundIfReady(parent.id)
    }

    /// Once claude and every extra reviewer that started have answered (or
    /// failed), the round goes to the working agent. Both sides call this
    /// whichever finishes last, and the phase leaving `reviewing` stops a
    /// second call finishing it again.
    func finishRoundIfReady(_ id: UUID) {
        guard let parent = sessions[id], var pairing = parent.pairing, pairing.phase == .reviewing, pairing.isRoundComplete else { return }
        let findings = pairing.mergedFindings
        pairing.finishMergedRound()
        update(id) { $0.pairing = pairing }
        let script = parent.readyForReviewScript
        switch pairing.phase {
        case .settled:
            deliver("The reviewer found nothing more to fix after \(pairing.round) round\(pairing.round == 1 ? "" : "s"). Go ahead: open the pull request, or mark it ready for review, as the brief and the team's skills say.", to: id)
            flag(id, title: "Review settled", body: pairing.status, replies: false)
            if let reviewerID = pairing.reviewerID { end(reviewerID) }
        case .limit:
            deliver(Self.findingsPrompt(findings, round: pairing.round, script: script, last: true), to: id)
            flag(id, title: "Review stopped after \(pairing.round) rounds", body: "\(pairing.findings) finding\(pairing.findings == 1 ? "" : "s") went to Claude in the last round.", replies: false)
            if let reviewerID = pairing.reviewerID { end(reviewerID) }
        default:
            deliver(Self.findingsPrompt(findings, round: pairing.round, script: script, last: false), to: id)
        }
    }

    /// The reviewers' findings, as the working agent is told them; each says
    /// who raised it when an extra reviewer took part.
    static func findingsPrompt(_ findings: [SessionTranscript.Finding], round: Int, script: String, last: Bool) -> String {
        let list = findings.enumerated().map { index, finding in
            let by = finding.reviewer.map { " (\($0))" } ?? ""
            return "\(index + 1). `\(finding.line.map { "\(finding.path):\($0)" } ?? finding.path)`\(by): \(finding.comment)"
        }
        let next = last
            ? "That was the last round, so the reviewer won't look again and there's no need to run \(script). Fix what you can, commit, and leave anything outstanding for the pull request's description."
            : "Fix those you agree with and say briefly why not for the rest. Commit, then run `\(script) \"<what you changed>\"` so it can look again."
        return """
            A second agent reviewed your changes (round \(round) of \(PairReview.maxRounds)) and found \(findings.count) thing\(findings.count == 1 ? "" : "s"):

            \(list.joined(separator: "\n"))

            \(next)
            """
    }

    /// Ends the loop: by you, or because the reviewer couldn't go on. A
    /// working agent waiting on it is told to carry on.
    func stopPairReview(_ id: UUID, note: String? = nil) {
        guard var pairing = sessions[id]?.pairing, !pairing.isOver else { return }
        let waiting = pairing.phase == .reviewing
        cancelRunningExtras(of: pairing)
        pairing.phase = .stopped
        pairing.note = note
        pairing.endedAt = .now
        update(id) { $0.pairing = pairing }
        if let reviewerID = pairing.reviewerID {
            pendingPrompts[reviewerID] = nil
            end(reviewerID)
        }
        if waiting {
            deliver("The review by a second agent has been stopped, so no findings are coming. Carry on.", to: id)
        }
        if note != nil { flag(id, title: "Review stopped", body: pairing.status, replies: false) }
    }
}

/// The loop on a session's panel: whether it's on, what it's doing or how
/// it ended, the reviewer, and Stop or Review Now.
struct PairReviewSection: View {
    @Environment(SessionStore.self) private var sessions
    /// The working session.
    let session: CodeSession

    var body: some View {
        let pairing = session.pairing
        let active = pairing.map { !$0.isOver } ?? false
        Section {
            Toggle("Review when it's ready", isOn: Binding(
                get: { sessions.pairsReview(session.id) },
                set: { sessions.setPairsReview($0, for: session.id) }
            ))
            .help("When claude runs \(session.readyForReviewScript), a second agent that can't edit reviews the change, and its findings go back to claude, up to \(PairReview.maxRounds) rounds")
            LabeledContent("Status") {
                Text(pairing?.status ?? "Waiting for claude to say the change is ready")
                    .multilineTextAlignment(.trailing)
            }
            ForEach(sessions.extraReviewers(session)) { reviewer in
                LabeledContent(reviewer.title) {
                    Text(extraStatus(reviewer, pairing: pairing))
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(pairing?.extras?[reviewer.id]?.state == .failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                }
            }
            HStack {
                if let reviewerID = pairing?.reviewerID, sessions.sessions[reviewerID] != nil {
                    Button("Show Reviewer") { sessions.reveal(reviewerID) }
                }
                Spacer()
                if active {
                    Button("Stop") { sessions.stopPairReview(session.id) }
                        .help("End the loop; claude is told to carry on if it's waiting for findings")
                } else {
                    Button("Review Now") { sessions.reviewRequested(session.id, note: "", byYou: true) }
                        .help("Start a round now, without waiting for claude to ask")
                }
            }
            if let problem = sessions.pairReviewProblems[session.id] {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Review by a second agent")
        }
    }

    /// An extra reviewer in a line: why it can't be used here, or where it
    /// is in the round.
    private func extraStatus(_ reviewer: ExtraReviewer, pairing: PairReview?) -> String {
        if session.isSandboxed { return "Not available: this session runs in a sandbox, and \(reviewer.title) runs on this Mac" }
        if session.isRemote { return "Not available: this session runs on a server, and \(reviewer.title) runs on this Mac" }
        guard let extra = pairing?.extras?[reviewer.id] else { return "Will join the next round" }
        switch extra.state {
        case .running: return pairing?.phase == .reviewing ? "Looking" : "Stopped with the review"
        case .answered: return "\(extra.findings.count) finding\(extra.findings.count == 1 ? "" : "s")"
        case .failed:
            let why = (extra.message ?? "Failed").trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            return "\(why). The round went ahead without it."
        }
    }
}
