import Foundation
import Testing
@testable import Gannin

/// Scheduled runs: how far each limit lets them go, and how they start.
struct RoutineRunsTests {
    private func routine(_ kind: RoutineKind, limit: RoutineLimit) -> Routine {
        var routine = Routine.new(org: "acme", harnessRepo: "acme/harness", kind: kind, name: "Tidy dependencies")
        routine.limit = limit
        return routine
    }

    private func session(_ info: RoutineRunInfo?) -> CodeSession {
        let id = UUID(uuidString: "3F9A2C1D-0000-0000-0000-000000000000")!
        var session = CodeSession(
            id: id, issue: IssueReference(org: "acme", id: "I_7", number: 7, title: "Bump the SDK", repo: "acme/app",
                                          url: URL(string: "https://github.com/acme/app/issues/7")!),
            repo: "acme/harness", branch: "7-bump-the-sdk", createdAt: .now,
            harnessRepo: "acme/harness", harnessPath: "~/Code/acme/harness"
        )
        session.routineRun = info
        return session
    }

    @Test func limitsDisallowWhatTheyDontAllow() {
        let local = RoutineRunInfo(routine: routine(.code, limit: .localOnly), run: UUID()).disallowedTools
        #expect(local.contains("Bash(git push:*)"))
        #expect(local.contains("Bash(gh pr create:*)"))
        #expect(local.contains("Bash(gh pr merge:*)"))
        #expect(!local.contains("Bash(git commit:*)"))

        let draft = RoutineRunInfo(routine: routine(.issueQueue, limit: .draftPR), run: UUID()).disallowedTools
        #expect(!draft.contains("Bash(git push:*)"))
        #expect(draft.contains("Bash(gh pr ready:*)"))

        let ready = RoutineRunInfo(routine: routine(.pinned, limit: .readyPR), run: UUID()).disallowedTools
        #expect(ready == ["Bash(gh pr merge:*)"])

        // A report commits nothing, whatever its limit says.
        let report = RoutineRunInfo(routine: routine(.report, limit: .readyPR), run: UUID()).disallowedTools
        #expect(report.contains("Bash(git commit:*)"))
        #expect(report.contains("Bash(git push:*)"))
    }

    @Test func briefSaysHowFarItMayGo() {
        let local = RoutineRunInfo(routine: routine(.code, limit: .localOnly), run: UUID()).briefSection
        #expect(local.contains("## Scheduled run"))
        #expect(local.contains("\"Tidy dependencies\""))
        #expect(local.contains("Local only"))
        #expect(local.contains("60 minutes"))
        #expect(RoutineRunInfo(routine: routine(.code, limit: .draftPR), run: UUID()).briefSection.contains("gh pr create --draft"))
        #expect(RoutineRunInfo(routine: routine(.report, limit: .localOnly), run: UUID()).briefSection.contains("This is a report"))
    }

    @Test func scheduledRunsStartWithNoPromptAndTheirToolsTakenAway() {
        let info = RoutineRunInfo(routine: routine(.code, limit: .localOnly), run: UUID())
        let steps = SessionScript.claudeSteps(session(info), settings: "s.json", shellNote: "")
        #expect(steps.contains(#"claude --session-id "$id""#))
        #expect(steps.contains("--disallowedTools 'Bash(git push:*),Bash(gh pr create:*),Bash(gh pr ready:*),Bash(gh pr merge:*)'"))
        #expect(steps.contains("--settings s.json\n"))
        #expect(!steps.contains("You're picking up"))
        // The prompt Gannin pastes once it's in auto mode.
        #expect(SessionScript.openingPrompt(session(info)).contains("You're picking up acme/app#7"))

        // Any other session is given it as it starts, as before.
        let attended = SessionScript.claudeSteps(session(nil), settings: "s.json", shellNote: "")
        #expect(attended.contains("--settings s.json 'You're picking up") || attended.contains("--settings s.json 'You'\\''re picking up"))
        #expect(!attended.contains("--disallowedTools"))
    }

    @Test func oldSessionsDecodeWithoutARoutine() throws {
        var plain = session(nil)
        plain.routineRun = nil
        let data = try JSONEncoder().encode(plain)
        let decoded = try JSONDecoder().decode(CodeSession.self, from: data)
        #expect(decoded.routineRun == nil)
        let info = RoutineRunInfo(routine: routine(.code, limit: .draftPR), run: UUID())
        let withRun = try JSONDecoder().decode(CodeSession.self, from: JSONEncoder().encode(session(info)))
        #expect(withRun.routineRun == info)
    }
}

/// Maintenance runs: no issue, a branch a run, the task in the brief.
struct MaintenanceRunTests {
    @Test func branchIsNewEachRun() {
        let id = UUID(uuidString: "3F9A2C1D-0000-0000-0000-000000000000")!
        let day = Date(timeIntervalSince1970: 1_791_547_200) // 9 Oct 2026, noon UTC
        let name = SessionStore.routineBranchName(name: "Tidy dependencies!", id: id, on: day)
        #expect(name.hasPrefix("routine-tidy-dependencies-2026100"))
        #expect(name.hasSuffix("-3f9a"))
        #expect(SessionStore.routineBranchName(name: "✨", id: id, on: day).hasPrefix("routine-2026"))
    }

    @Test func briefAndReferences() {
        var routine = Routine.new(org: "acme", harnessRepo: "acme/harness", kind: .code, name: "Tidy dependencies")
        routine.repos = ["acme/app", "acme/api"]
        routine.prompt = "Bump patch versions and run the tests."
        let id = UUID()
        var session = CodeSession(
            id: id, issue: IssueReference(org: "acme", id: "routine-\(id.uuidString)", number: 0, title: routine.name, repo: "acme/app",
                                          url: URL(string: "https://github.com/acme/app")!),
            repo: "acme/harness", branch: SessionStore.routineBranchName(name: routine.name, id: id), createdAt: .now,
            harnessRepo: "acme/harness", harnessPath: "~/Code/acme/harness"
        )
        session.routineRun = RoutineRunInfo(routine: routine, run: UUID())
        #expect(session.hasNoIssue)
        #expect(session.isMaintenance)
        #expect(session.shortReference == "Maintenance")
        #expect(session.longReference == "maintenance in acme/app")
        #expect(SessionStore.harnessFolder(for: session) == "sessions/\(session.branch)")

        let brief = SessionBrief.make(session: session, record: nil, detail: nil, parent: nil, harness: nil)
        #expect(brief.hasPrefix("# Maintenance in acme/app: Tidy dependencies"))
        #expect(brief.contains("## The task\n\nBump patch versions and run the tests."))
        #expect(brief.contains("- acme/api"))
        #expect(brief.contains("The work is in acme/app, acme/api."))
        // Local only: no pull request, and no plan document.
        #expect(brief.contains("this run is Local only, so don't push or open a pull request"))
        #expect(!brief.contains("gh pr create"))
        #expect(!brief.contains("## Description"))
        #expect(brief.contains("Maintenance needs no plan document."))

        session.routineRun = RoutineRunInfo(routine: { var draft = routine; draft.limit = .draftPR; return draft }(), run: UUID())
        let draft = SessionBrief.make(session: session, record: nil, detail: nil, parent: nil, harness: nil)
        #expect(draft.contains("open a draft pull request with `gh pr create --draft`"))
        #expect(draft.contains("Routine maintenance, no issue."))

        let prompt = SessionStore.maintenancePrompt(session)
        #expect(prompt.contains("acme/app, acme/api"))
        #expect(prompt.hasSuffix("Bump patch versions and run the tests."))
    }
}
