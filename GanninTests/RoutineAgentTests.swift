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
