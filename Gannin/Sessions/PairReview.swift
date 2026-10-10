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

    var isOver: Bool { [.settled, .limit, .stopped].contains(phase) }

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
    var canPairReview: Bool { !isHelper && !isPullRequestReview && !isPlanning && !isAsk }

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
        var pairing = session.pairing ?? PairReview()
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
        let said = note.isEmpty ? "" : "\n\nThe agent working on it says: \(note)"
        if let reviewerID = pairing.reviewerID, let reviewer = sessions[reviewerID] {
            pairing.phase = .reviewing
            update(id) { $0.pairing = pairing }
            let folder = session.isInHarness ? ".worktrees/\(session.branch)/" : "the worktree"
            let prompt = """
                The agent working on \(session.longReference) has changed things since your last look.\(said)

                Look at every change in \(folder) again as it is now, committed or not. Leave out findings it has dealt with, \
                and don't raise again ones it explained away unless you still disagree, saying why. Don't edit anything. \
                End the same way with the fenced JSON list, empty (`[]`) when there's nothing left to fix.
                """
            if !send(prompt, toReviewer: reviewer) {
                stopPairReview(id, note: "Stopped: the reviewer's Claude Code had exited")
            }
        } else {
            let learnings = reviewLearnings(for: session)
            let prompt = Self.reviewPrompt(for: session, learnings: learnings) + said + """


                Gannin passes your findings to that agent and asks you to look again once it has dealt with them. \
                When there's nothing to fix, end with an empty list (`[]`).
                """
            guard let reviewer = startHelper(for: id, role: "Review", prompt: prompt, reviewer: true, reveals: false) else { return }
            pairing.reviewerID = reviewer.id
            pairing.phase = .reviewing
            update(id) { $0.pairing = pairing }
            _ = open(reviewer)
        }
    }

    /// Pasted now if the reviewer's waiting, else once it is, resuming it
    /// if it isn't running. False when claude has exited and left its shell.
    private func send(_ prompt: String, toReviewer reviewer: CodeSession) -> Bool {
        let id = reviewer.id
        guard isRunning(id) else {
            pendingPrompts[id] = prompt
            _ = open(reviewer)
            return true
        }
        switch state(id) {
        case .idle:
            submit(prompt, to: id)
        case .starting, .working, .needsYou:
            pendingPrompts[id] = prompt
        case .exited, .stopped:
            return false
        }
        return true
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
    /// round with its JSON list, the round goes to the working agent.
    func pairRoundRead(_ reviewerID: UUID) {
        guard let parent = pairReviewed(by: reviewerID), var pairing = parent.pairing, pairing.phase == .reviewing,
              let transcript = transcripts[reviewerID], let reply = transcript.lastReplyID, reply != pairing.lastReply,
              let findings = transcript.listedFindings else { return }
        pairing.finishRound(findings: findings.count, reply: reply)
        update(parent.id) { $0.pairing = pairing }
        let script = parent.readyForReviewScript
        switch pairing.phase {
        case .settled:
            deliver("The reviewer found nothing more to fix after \(pairing.round) round\(pairing.round == 1 ? "" : "s"). Go ahead: open the pull request, or mark it ready for review, as the brief and the team's skills say.", to: parent.id)
            flag(parent.id, title: "Review settled", body: pairing.status, replies: false)
            end(reviewerID)
        case .limit:
            deliver(Self.findingsPrompt(findings, round: pairing.round, script: script, last: true), to: parent.id)
            flag(parent.id, title: "Review stopped after \(pairing.round) rounds", body: "\(pairing.findings) finding\(pairing.findings == 1 ? "" : "s") went to Claude in the last round.", replies: false)
            end(reviewerID)
        default:
            deliver(Self.findingsPrompt(findings, round: pairing.round, script: script, last: false), to: parent.id)
        }
    }

    /// The reviewer's findings, as the working agent is told them.
    static func findingsPrompt(_ findings: [SessionTranscript.Finding], round: Int, script: String, last: Bool) -> String {
        let list = findings.enumerated().map { index, finding in
            "\(index + 1). `\(finding.line.map { "\(finding.path):\($0)" } ?? finding.path)`: \(finding.comment)"
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
                        .disabled(!sessions.isRunning(session.id))
                        .help("Start a round now, without waiting for claude to ask")
                }
            }
        } header: {
            Text("Review by a second agent")
        }
    }
}
