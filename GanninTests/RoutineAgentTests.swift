import Foundation
import Testing
@testable import Gannin

/// A scheduled routine as one choice of how far it goes, and the agent it
/// runs with.
@MainActor
struct RoutineAgentTests {
    @Test func reachIsAReportOrMaintenanceOnALimit() {
        var routine = Routine.new(org: "acme", harnessRepo: "acme/harness", kind: .report)
        #expect(routine.reach == .report)
        #expect(routine.kind.isScheduledTask)
        routine.reach = .draftPR
        #expect(routine.kind == .code && routine.limit == .draftPR)
        routine.reach = .report
        #expect(routine.kind == .report)
        // A report still commits and pushes nothing.
        let tools = RoutineRunInfo(routine: routine, run: UUID()).disallowedTools
        #expect(tools.contains("Bash(git commit:*)") && tools.contains("Bash(git push:*)"))
    }

    @Test func aReportIsToldWhichReposToRead() {
        var routine = Routine.new(org: "acme", harnessRepo: "acme/harness", kind: .report)
        routine.prompt = "Audit for secrets."
        #expect(SessionStore.reportTask(routine) == "Audit for secrets.")
        routine.repos = ["acme/api", "acme/web"]
        #expect(SessionStore.reportTask(routine).hasSuffix("`projects/<name>`: acme/api, acme/web."))
    }

    @Test func aRoutineSavedBeforeAgentsStillLoads() throws {
        var routine = Routine.new(org: "acme", harnessRepo: "acme/harness", kind: .report)
        routine.specialist = "personal/coach"
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(routine)) as? [String: Any])
        #expect(object["specialist"] as? String == "personal/coach")
        object.removeValue(forKey: "specialist")
        let old = try JSONDecoder().decode(Routine.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.specialist == nil && old.workflow == nil)
    }
}

/// Draft with Claude for a routine: only what Gannin offers is taken.
@MainActor
struct RoutineDraftingTests {
    @Test func aReplyFillsTheEditorWithKnownChoicesOnly() throws {
        let text = #"{"name": "Weekly security audit", "task": "Look for leaked secrets.", "repos": ["ACME/api", "acme/unknown"], "may": "report", "schedule": {"form": "weekly", "weekday": 2, "time": "08:30"}, "runWith": {"specialist": "security"}, "message": "Drafted."}"#
        let reply = try #require(ScriptRunner.json(RoutineDrafting.Reply.self, in: text))
        var routine = Routine.new(org: "acme", harnessRepo: "acme/harness", kind: .report)
        routine.reach = .draftPR
        var repos: [String] = []
        var schedule = ScheduleDraft(routine.schedule)
        RoutineDrafting.apply(reply, to: &routine, repos: &repos, schedule: &schedule, knownRepos: ["acme/api", "acme/web"],
                              specialists: [RoutineDrafting.Choice(id: "security", label: "Security")], workflows: [])
        #expect(routine.name == "Weekly security audit")
        #expect(routine.prompt == "Look for leaked secrets.")
        #expect(repos == ["acme/api"])
        #expect(routine.reach == .report)
        #expect(routine.specialist == "security" && routine.workflow == nil)
        #expect(schedule.schedule(for: .report) == .weekly(weekday: 2, TimeOfDay(hour: 8, minute: 30)))
    }

    @Test func aSpecialistGanninDoesntHaveIsLeftOut() throws {
        let reply = try #require(ScriptRunner.json(RoutineDrafting.Reply.self, in: #"{"runWith": {"specialist": "ghost"}, "message": "?"}"#))
        var routine = Routine.new(org: "acme", harnessRepo: "acme/harness", kind: .report)
        var repos: [String] = []
        var schedule = ScheduleDraft(routine.schedule)
        RoutineDrafting.apply(reply, to: &routine, repos: &repos, schedule: &schedule, knownRepos: [], specialists: [], workflows: [])
        #expect(routine.specialist == nil)
        #expect(RoutineDrafting.timeOfDay("25:00") == nil)
    }
}
