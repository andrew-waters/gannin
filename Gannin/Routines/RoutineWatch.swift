import Foundation

/// What a running scheduled run's session comes to on a look: its outcome
/// so far, or that it's past a limit and must stop.
enum RoutineVerdict: Equatable {
    case running
    case needsYou
    case finished
    case overTime
    case overCost
    /// Its claude isn't running, and it hadn't finished.
    case lost
}

extension RoutineVerdict {
    /// The run's verdict from what the session shows. Limits come first:
    /// time and cost count while it waits on you too (R12). A turn ending
    /// counts as finished only once it has been seen working, and not
    /// while its pair review goes on.
    static func judge(state: SessionState, isRunning: Bool, hasWorked: Bool, inPairReview: Bool, elapsed: TimeInterval, cost: Double, maxMinutes: Int, maxCost: Double) -> RoutineVerdict {
        if isRunning, elapsed > TimeInterval(maxMinutes * 60) { return .overTime }
        if isRunning, maxCost > 0, cost > maxCost { return .overCost }
        guard isRunning else { return hasWorked ? .finished : .lost }
        switch state {
        case .needsYou: return .needsYou
        case .exited: return hasWorked ? .finished : .lost
        case .idle where hasWorked && !inPairReview: return .finished
        default: return .running
        }
    }
}

extension SessionStore {
    /// Each look at the scheduled runs going (the scheduler's tick): their
    /// cost and PRs, Needs you while claude asks, Stopped at limit past
    /// their time or cost (R11), and finished when their turn ends.
    func watchRoutineRuns(now: Date = .now) {
        guard let routines else { return }
        for run in routines.activeRuns {
            guard let id = run.session, !stoppingRoutineSessions.contains(id) else { continue }
            guard let session = sessions[id], let info = session.routineRun else {
                routines.updateRun(run.id) { run in
                    run.outcome = .failed
                    run.endedAt = now
                    run.note = "Its session was removed."
                }
                continue
            }
            let state = state(id)
            if state == .working { routineSessionsWorked.insert(id) }
            let cost = ([id] + helpers(of: id).map(\.id)).compactMap { transcripts[$0]?.costUSD }.reduce(0, +)
            let verdict = RoutineVerdict.judge(
                state: state, isRunning: isRunning(id), hasWorked: routineSessionsWorked.contains(id) || transcripts[id]?.lastReply != nil,
                inPairReview: isQuietForPairReview(id), elapsed: now.timeIntervalSince(run.startedAt ?? now),
                cost: cost, maxMinutes: info.maxMinutes, maxCost: info.maxCost
            )
            routines.updateRun(run.id) { run in
                if cost > 0 { run.cost = cost }
                run.pullRequests = session.pullRequests
            }
            switch verdict {
            case .running:
                routines.updateRun(run.id) { $0.outcome = .running }
            case .needsYou:
                // Flagged as any session is (`setState`); the clock runs on.
                routines.updateRun(run.id) { $0.outcome = .needsYou }
            case .finished:
                routines.updateRun(run.id) { run in
                    run.outcome = .finished
                    run.endedAt = now
                }
                let files = info.kind == .report ? "Its files are in the session's Files." : session.pullRequests.isEmpty ? "Open it to see what it did." : "It opened \(session.pullRequests.count == 1 ? "a pull request" : "\(session.pullRequests.count) pull requests")."
                notifyRoutine(id, title: info.kind == .report ? "Report ready" : "Scheduled run finished", body: "\(info.name). \(files)")
            case .overTime, .overCost:
                let why = verdict == .overTime
                    ? "It ran past \(info.maxMinutes) minutes."
                    : "It cost \(cost.formatted(.currency(code: "USD"))), past \(info.maxCost.formatted(.currency(code: "USD")))."
                stopAtLimit(run.id, session: id, why: why, name: info.name)
            case .lost:
                routines.updateRun(run.id) { run in
                    run.outcome = .failed
                    run.endedAt = now
                    run.note = "Claude stopped before it got going. Open its session to see why."
                }
            }
        }
    }

    /// Interrupts claude, then ends it, keeping its worktree and files, and
    /// marks the run Stopped at limit with a notification.
    private func stopAtLimit(_ run: UUID, session id: UUID, why: String, name: String) {
        stoppingRoutineSessions.insert(id)
        interrupt(id)
        for helper in helpers(of: id) where isRunning(helper.id) { end(helper.id) }
        Task {
            try? await Task.sleep(for: .seconds(2))
            end(id)
            stoppingRoutineSessions.remove(id)
            routines?.updateRun(run) { run in
                run.outcome = .stoppedAtLimit
                run.endedAt = .now
                run.note = why
            }
            notifyRoutine(id, title: "Scheduled run stopped at its limit", body: "\(name). \(why) What it did is kept.")
        }
    }
}
