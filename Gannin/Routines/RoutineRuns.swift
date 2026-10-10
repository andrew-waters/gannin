import Foundation
import UserNotifications

/// The routine run a session was started for, kept with it so its limits,
/// tab and outcome know.
struct RoutineRunInfo: Codable, Hashable {
    let routine: UUID
    let run: UUID
    let name: String
    let kind: RoutineKind
    let limit: RoutineLimit
    let maxMinutes: Int
    let maxCost: Double

    init(routine: Routine, run: UUID) {
        self.routine = routine.id
        self.run = run
        name = routine.name
        kind = routine.kind
        limit = routine.limit
        maxMinutes = routine.maxMinutes
        maxCost = routine.maxCost
    }

    /// What claude may not run (`--disallowedTools`), as far as the limit
    /// says (R9). A report commits nothing (R4). Merging is never a
    /// scheduled run's to do. Patterns stop the plain commands, not every
    /// way to push: a guard, not a sandbox.
    var disallowedTools: [String] {
        let push = ["Bash(git push:*)", "Bash(gh pr create:*)"]
        let ready = ["Bash(gh pr ready:*)"]
        let merge = ["Bash(gh pr merge:*)"]
        guard kind.touchesCode else { return ["Bash(git commit:*)"] + push + ready + merge }
        switch limit {
        case .localOnly: return push + ready + merge
        case .draftPR: return ready + merge
        case .readyPR: return merge
        }
    }

    /// What the brief tells claude about running by itself and how far it
    /// may go.
    var briefSection: String {
        let cost = maxCost.formatted(.currency(code: "USD"))
        let allowed: String = switch (kind.touchesCode, limit) {
        case (false, _):
            "- This is a report. Write what you find to the files folder the brief names; don't change code, commit, push or open pull requests. Whoever reads it decides what's shared."
        case (true, .localOnly):
            "- Local only: commit your work on this branch in its worktrees, and stop there. Don't push, open or update a pull request, or comment on GitHub; Gannin won't let `git push` or `gh pr create` run. Someone will look at the branch."
        case (true, .draftPR):
            "- Draft PR: once the change is committed, built and checked, push with `git push origin HEAD` and open a draft pull request (`gh pr create --draft`). Don't mark it ready for review or merge it."
        case (true, .readyPR):
            "- Ready PR: once the change is committed, built and checked, push with `git push origin HEAD` and open a pull request ready for review. Don't merge it."
        }
        return """
            ## Scheduled run

            Gannin started this session by itself, for the routine "\(name)". Nobody is watching it.

            - Don't ask questions or wait for a plan to be approved: decide, write down why where the work is recorded (the plan, the commit, the pull request or the report), and carry on. If you can't go on without a person, stop and say why in your last message.
            - You're in auto mode. A permission prompt or question waits for someone and holds the run up.
            - It's stopped after \(maxMinutes) minutes or \(cost) spent, whichever comes first, keeping what's done. Keep within that.
            \(allowed)

            """
    }
}

extension SessionStore {
    /// How long a scheduled run may take to reach claude's prompt: a
    /// sandbox's first start builds its image.
    static let unattendedStartTimeout: TimeInterval = 15 * 60

    /// Starts a scheduled run's session by itself (R1): its tab added but
    /// not shown, claude started with no prompt, switched to auto mode,
    /// then given its first prompt. A claude that can't reach auto mode is
    /// ended before it does anything, and the run fails saying so.
    func startUnattended(_ id: UUID) async -> RoutineStart {
        guard let session = sessions[id] else { return .failed("The session wasn't made.") }
        addTab(id, after: selectedTab.map { tabOwner($0) })
        _ = open(session)
        let deadline = Date.now.addingTimeInterval(Self.unattendedStartTimeout)
        while state(id) != .idle {
            guard sessions[id] != nil else { return .failed("The session was removed before it started.") }
            if state(id) == .exited || Date.now > deadline {
                end(id)
                return .failed(state(id) == .exited ? "Claude Code exited before it was ready." : "Claude Code didn't reach its prompt in time.")
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        var unattended = await switchMode(id, to: .auto)
        // The prompt box can take a moment to draw after SessionStart.
        if !unattended, !autoUnavailable(id) {
            try? await Task.sleep(for: .seconds(2))
            unattended = await switchMode(id, to: .auto)
        }
        guard unattended else {
            let why = modeNotes[id] ?? "Gannin couldn't switch it to auto mode."
            end(id)
            notifyRoutine(id, title: "Scheduled run didn't start", body: "Auto mode unavailable. \(why)")
            return .failed("Auto mode unavailable. \(why)")
        }
        guard submit(SessionScript.openingPrompt(session), to: id) else {
            end(id)
            return .failed("Claude's terminal closed before it was given its prompt.")
        }
        return .started(session: id)
    }

    /// A notification about a scheduled run, opening its session's tab when
    /// it has one. Off with the rest (Settings > General > Agent).
    func notifyRoutine(_ id: UUID?, title: String, body: String) {
        guard UserDefaults.standard.object(forKey: Self.notifiesKey) as? Bool ?? true else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        if let id, let session = sessions[id] {
            content.subtitle = session.routineRun?.name ?? session.title
            content.threadIdentifier = id.uuidString
            content.userInfo = ["session": id.uuidString]
        }
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "routine-\(UUID().uuidString)", content: content, trigger: nil))
    }
}
