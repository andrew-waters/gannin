import Foundation

/// Draft with Claude for a scheduled routine: from what you say, Claude
/// fills in its name, task, repos, how far it goes, when it runs and who
/// runs it, choosing only from what Gannin offers.
enum RoutineDrafting {
    /// Claude's reply. Every field is optional: it may only ask.
    struct Reply: Decodable {
        struct Schedule: Decodable {
            /// `daily`, `workingDays`, `weekly`, `every` or `cron`.
            var form: String?
            /// `HH:MM`, 24-hour.
            var time: String?
            /// 1 is Sunday, 2 Monday, through 7, Saturday.
            var weekday: Int?
            var hours: Int?
            var cron: String?
        }

        struct RunWith: Decodable {
            var specialist: String?
            var workflow: String?
        }

        var name: String?
        var task: String?
        var repos: [String]?
        /// `report`, `localOnly`, `draftPR` or `readyPR`.
        var may: String?
        var schedule: Schedule?
        var runWith: RunWith?
        var message: String?

        var hasDraft: Bool { name != nil || task != nil || repos != nil || may != nil || schedule != nil || runWith != nil }
    }

    /// One choice Claude can make, as it's told about it.
    struct Choice {
        let id: String
        let label: String
    }

    static func request(ask: String, current: String?, repos: [String], specialists: [Choice], workflows: [Choice]) -> String {
        var parts = [
            """
            Help me set up a routine in Gannin: a task Claude Code runs by itself on a schedule, while nobody watches, in our team's harness. \
            A routine that only reads and writes up what it finds runs as a report; one that changes code works in worktrees of its repos on a branch of its own. \
            What I want: \(ask)
            """,
            """
            Reply with only JSON:
            {"name": "short name", "task": "what the session is told, as instructions: what to look at or do, how, and what to write up at the end", \
            "repos": ["owner/name"], "may": "report" | "localOnly" | "draftPR" | "readyPR", \
            "schedule": {"form": "daily" | "workingDays" | "weekly" | "every" | "cron", "time": "HH:MM", "weekday": 2, "hours": 6, "cron": "0 9 * * 1"}, \
            "runWith": {"specialist": "name"} or {"workflow": "id"} or null, "message": "what you say to me"}
            - may: report unless I've asked for code to be changed. localOnly commits and never pushes; draftPR may open a draft pull request; readyPR one ready for review. Never pick more than the task needs.
            - schedule: weekday is 1 for Sunday, 2 for Monday, through 7 for Saturday; workingDays is the org's working week; every takes hours; use cron only when nothing else fits.
            - repos: only from the list below, as written. Leave it out when the task is about the harness alone.
            - runWith: a specialist or workflow from the lists below when one fits the task, else null for my default.
            """,
            "Repos: " + (repos.isEmpty ? "(none known)" : repos.joined(separator: ", ")),
        ]
        parts.append("Specialists (name: title):\n" + (specialists.isEmpty ? "(none)" : specialists.map { "- \($0.id): \($0.label)" }.joined(separator: "\n")))
        parts.append("Workflows for routines (id: name):\n" + (workflows.isEmpty ? "(none)" : workflows.map { "- \($0.id): \($0.label)" }.joined(separator: "\n")))
        if let current { parts.append("What's in the editor now:\n\n\(current)") }
        return parts.joined(separator: "\n\n")
    }

    /// The editor as Claude reads it.
    static func editorText(_ routine: Routine, repos: [String], schedule: RoutineSchedule, runsWith: String?) -> String? {
        guard !routine.name.isEmpty || !routine.prompt.isEmpty else { return nil }
        return """
            Name: \(routine.name)
            Repos: \(repos.isEmpty ? "none" : repos.joined(separator: ", "))
            May: \(routine.reach.rawValue)
            When: \(schedule.summary)
            Run with: \(runsWith ?? "my default")
            Task:
            \(routine.prompt)
            """
    }

    /// Fills the editor from a reply, keeping only choices Gannin offers.
    static func apply(_ reply: Reply, to routine: inout Routine, repos: inout [String], schedule: inout ScheduleDraft, knownRepos: [String], specialists: [Choice], workflows: [Choice]) {
        if let name = reply.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { routine.name = name }
        if let task = reply.task?.trimmingCharacters(in: .whitespacesAndNewlines), !task.isEmpty { routine.prompt = task }
        if let picked = reply.repos {
            repos = picked.compactMap { name in knownRepos.first { $0.caseInsensitiveCompare(name) == .orderedSame } }
        }
        if let may = reply.may.flatMap(RoutineReach.init(rawValue:)) { routine.reach = may }
        if let run = reply.runWith {
            if let name = run.specialist, let match = specialists.first(where: { $0.id.caseInsensitiveCompare(name) == .orderedSame }) {
                routine.specialist = match.id
                routine.workflow = nil
            } else if let id = run.workflow, workflows.contains(where: { $0.id == id }) {
                routine.workflow = id
                routine.specialist = nil
            }
        }
        if let drafted = reply.schedule { apply(drafted, to: &schedule) }
    }

    private static func apply(_ drafted: Reply.Schedule, to schedule: inout ScheduleDraft) {
        if let time = drafted.time.flatMap(timeOfDay) { schedule.time = time }
        switch drafted.form {
        case "daily": schedule.form = .daily
        case "workingDays": schedule.form = .workingDays
        case "weekly":
            schedule.form = .weekly
            if let day = drafted.weekday, (1...7).contains(day) { schedule.weekday = day }
        case "every":
            schedule.form = .every
            schedule.unit = .hours
            schedule.interval = min(max(drafted.hours ?? 24, 1), 168)
        case "cron":
            if let cron = drafted.cron, !cron.isEmpty {
                schedule.form = .cron
                schedule.cron = cron
            }
        default: break
        }
    }

    static func timeOfDay(_ text: String) -> TimeOfDay? {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0...23).contains(parts[0]), (0...59).contains(parts[1]) else { return nil }
        return TimeOfDay(hour: parts[0], minute: parts[1])
    }
}
