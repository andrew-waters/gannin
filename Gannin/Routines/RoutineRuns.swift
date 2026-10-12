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
    /// A maintenance routine's repos and task, as they were when it ran.
    let repos: [String]
    let task: String
    /// Carried on in the issue's own session rather than one started for
    /// it, so what it did before the run doesn't count, and the session
    /// is handed back when the run ends.
    var resumed: Bool?

    init(routine: Routine, run: UUID, resumed: Bool = false) {
        self.routine = routine.id
        self.run = run
        name = routine.name
        kind = routine.kind
        limit = routine.limit
        maxMinutes = routine.maxMinutes
        maxCost = routine.maxCost
        repos = routine.repos
        task = routine.prompt
        self.resumed = resumed ? true : nil
    }

    /// A maintenance run's task and repos, in its brief where an issue's
    /// description would be.
    var maintenanceSections: [String] {
        var lines = [
            "## Routine maintenance",
            "",
            "Started on a schedule by the routine \"\(name)\" rather than from an issue, so there's no issue for it. Each run has a branch of its own.",
            "",
            "## The task",
            "",
            task.trimmingCharacters(in: .whitespacesAndNewlines),
            "",
        ]
        if !repos.isEmpty {
            lines += ["## Repos", ""] + repos.map { "- \($0)" } + [""]
        }
        return lines
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
            "- Draft PR: once the change is committed, built and checked, push with `git push origin HEAD:<branch>` (this session's branch) and open a draft pull request (`gh pr create --draft`). Don't mark it ready for review or merge it."
        case (true, .readyPR):
            "- Ready PR: once the change is committed, built and checked, push with `git push origin HEAD:<branch>` (this session's branch) and open a pull request ready for review. Don't merge it."
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
    func startUnattended(_ id: UUID, prompt: String? = nil) async -> RoutineStart {
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
        guard submit(prompt ?? SessionScript.openingPrompt(session), to: id) else {
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

// MARK: - Making a run's session

extension SessionStore {
    /// Starts a run of the routine: a report, maintenance, or the issue a
    /// queue window or pin hands it. Read from the app's stores; the run is
    /// recorded by the scheduler.
    func startRoutine(_ routine: Routine, issue: IssueReference?, run: UUID, configs: OrgConfigStore, issues: IssueStore, details: DetailStore, login: String?) async -> RoutineStart {
        let project = configs.scoped(routine.harnessRepo)
        let own = project.config(for: routine.org).harness(repo: routine.harnessRepo)
        let gone = "\(routine.harnessRepo) isn't one of \(routine.org)'s projects any more."
        switch routine.kind {
        case .issueQueue, .pinned:
            guard let issue else { return .failed("There was no issue to work on.") }
            // The queue is the org's: each issue runs in the harness covering
            // its repos, as Work on This picks it; the routine's project only
            // when none does.
            guard let covering = configs.config(for: issue.org).harness(covering: WorkOnThisLauncher.repos(issue, issues: issues)) ?? own else {
                return .failed(gone)
            }
            let goals = configs.scoped(covering.repo).config(for: issue.org).measurables
            return await startIssueRun(routine, issue: issue, run: run, setup: covering, goals: goals, configs: configs, issues: issues, details: details, login: login)
        case .report, .code:
            break
        }
        guard let setup = own else { return .failed(gone) }
        let goals = project.config(for: routine.org).measurables
        switch routine.kind {
        case .report:
            return await startReportRun(routine, run: run, setup: setup)
        case .code:
            guard let path = Self.harnessPath(org: routine.org, repo: setup.repo) else {
                return .failed(Self.unavailable(org: routine.org, harness: setup) ?? "The harness isn't checked out here.")
            }
            let placement = Self.routinePlacement(org: routine.org, repos: routine.repos, configs: configs)
            return await startMaintenanceRun(routine, run: run, setup: setup, harnessPath: path, placement: placement, goals: goals)
        case .issueQueue, .pinned:
            return .failed("There was no issue to work on.")
        }
    }

    /// Where a scheduled code run goes, as Work on This decides (a sandbox
    /// once sandboxing is on, unless a repo needs the Mac).
    static func routinePlacement(org: String, repos: [String], configs: OrgConfigStore) -> SandboxPlacement {
        SandboxPlacement.decide(
            enabled: SandboxCredentials.isEnabled, repos: repos,
            reposNeedingMac: configs.config(for: org).reposNeedingMac, org: org,
            hasGitHubToken: SandboxCredentials.gitHubToken(org: org) != nil,
            connectsBySSH: connectCommand.map { Shell.sshArguments($0) != nil } ?? true
        )
    }

    /// The team's prompts the routine names, else the defaults for `use`.
    func routineInstructions(_ routine: Routine, setup: HarnessConfig, use: PromptUse, repos: [String], values: [String: String]) -> String? {
        var choice: PromptChoice?
        if !routine.teamPrompts.isEmpty {
            let library = promptLibrary(org: routine.org, setup: setup)
            let picked = library.prompts.filter { routine.teamPrompts.contains($0.path) }
            choice = PromptChoice(prompts: Set(picked.map(\.path)), skills: Set(picked.flatMap(\.skills).compactMap { library.skill(named: $0)?.path }))
        }
        return launchInstructions(org: routine.org, setup: setup, use: use, repos: repos, choice: choice, values: values)
    }

    /// A report: an Ask session (on this Mac, its files kept in its folder
    /// for the Files pane and Commit to Harness) with the routine's question
    /// and no code worktree (R4).
    func startReportRun(_ routine: Routine, run: UUID, setup: HarnessConfig) async -> RoutineStart {
        let harnessPath = Self.localHarnessPath(org: routine.org, repo: setup.repo)
        let id = UUID()
        let slug = "\(Date.now.formatted(.iso8601.year().month().day()))-\(id.uuidString.prefix(8).lowercased())"
        let branch = "ask-\(slug)"
        let title = "\(routine.name), \(Date.now.formatted(date: .abbreviated, time: .shortened))"
        let info = RoutineRunInfo(routine: routine, run: run)
        let instructions = routineInstructions(routine, setup: setup, use: .ask, repos: [], values: ["title": title, "repo": setup.repo, "branch": branch])
        var session = CodeSession(
            id: id, issue: IssueReference(org: routine.org, id: "ask-\(id.uuidString)", number: 0, title: title, repo: setup.repo,
                                              url: URL(string: "https://github.com/\(setup.repo)")!),
            repo: setup.repo, branch: branch, createdAt: .now,
            connect: nil, harnessRepo: setup.repo, harnessPath: harnessPath,
            prompt: Self.askPrompt(routine.prompt, branch: branch), instructions: instructions,
            ask: AskInfo(title: title, slug: slug, message: routine.prompt)
        )
        session.routineRun = info
        let directory = Self.directory(for: id)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data((Self.askBrief(session) + "\n" + info.briefSection).utf8).write(to: directory.appending(path: "brief.md"))
        add(session)
        return await startUnattended(id)
    }

    /// Maintenance: a session with no issue, as a quick change without one
    /// is, on a branch of its own per run, told to give each of the
    /// routine's repos a worktree as Work on This lays them out (R5).
    func startMaintenanceRun(_ routine: Routine, run: UUID, setup: HarnessConfig, harnessPath: String, placement: SandboxPlacement, goals: [Measurable]) async -> RoutineStart {
        guard let repo = routine.repos.first else { return .failed("The routine names no repo to work in.") }
        let id = UUID()
        let reference = IssueReference(org: routine.org, id: "routine-\(id.uuidString)", number: 0, title: routine.name, repo: repo,
                                       url: URL(string: "https://github.com/\(repo)")!)
        let branch = Self.routineBranchName(name: routine.name, id: id)
        let instructions = routineInstructions(routine, setup: setup, use: .work, repos: routine.repos,
                                               values: HarnessPromptLibrary.values(reference: "maintenance in \(repo)", title: routine.name, url: reference.url, repo: repo, number: 0, branch: branch))
        var session = CodeSession(
            id: id, issue: reference, repo: setup.repo, branch: branch, createdAt: .now,
            connect: Self.connectCommand, harnessRepo: setup.repo, harnessPath: harnessPath, instructions: instructions,
            sandbox: placement.isSandboxed ? SandboxPlacement.containerName(for: id) : nil, hostReason: placement.reason
        )
        let info = RoutineRunInfo(routine: routine, run: run)
        session.routineRun = info
        session.prompt = Self.maintenancePrompt(session)
        let directory = Self.directory(for: id)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let brief = SessionBrief.make(session: session, record: nil, detail: nil, parent: nil, harness: harnessStore.index(for: routine.org, setup), goals: goals)
        try? Data((brief + "\n" + info.briefSection).utf8).write(to: directory.appending(path: "brief.md"))
        add(session)
        return await startUnattended(id)
    }

    /// An issue from the queue or a pin: its Work on This session (R7, R8),
    /// briefed from what Gannin has cached, its session record committed to
    /// the harness without asking, since scheduling it was the consent (R16).
    func startIssueRun(_ routine: Routine, issue: IssueReference, run: UUID, setup: HarnessConfig, goals: [Measurable], configs: OrgConfigStore,
                       issues: IssueStore, details: DetailStore, login: String?) async -> RoutineStart {
        if let existing = session(forIssue: issue.id) {
            return await resumeIssueRun(existing.id, routine: routine, run: run)
        }
        guard let path = Self.harnessPath(org: issue.org, repo: setup.repo) else {
            return .failed(Self.unavailable(org: issue.org, harness: setup) ?? "The harness isn't checked out here.")
        }
        let history = issues.history(for: issue.org)
        let issueRecord = history?.issues[issue.id]
        let parent = issueRecord?.parentID.flatMap { history?.issues[$0] }
        let detail = details.detail(for: issue.id)
        let repos = WorkOnThisLauncher.repos(issue, issues: issues)
        let instructions = routineInstructions(routine, setup: setup, use: .work, repos: repos, values: WorkOnThisLauncher.values(issue))
        let placement = Self.routinePlacement(org: issue.org, repos: repos, configs: configs)
        let info = RoutineRunInfo(routine: routine, run: run)
        let index = harnessStore.index(for: issue.org, setup)
        let made = start(issue, harness: setup, harnessPath: path, instructions: instructions, placement: placement) { session in
            var scheduled = session
            scheduled.routineRun = info
            return SessionBrief.make(session: scheduled, record: issueRecord, detail: detail, parent: parent, harness: index, goals: goals) + "\n" + info.briefSection
        }
        update(made.id) { session in
            session.routineRun = info
            session.prompt = Self.scheduledIssuePrompt(session, note: routine.prompt)
        }
        // Committed before the terminal starts, so its pull brings the brief.
        await record(made.id, startedBy: login)
        return await startUnattended(made.id)
    }

    /// An issue with a session already carries on in it rather than in a
    /// second beside it. A session mid-turn or asking something is left
    /// alone, and the run tried again later. One that's running is started
    /// again first (claude resumes its conversation), so the run's limits
    /// reach claude (`--disallowedTools`); then it's switched to auto mode
    /// and told to carry on. A run that doesn't start hands it back.
    func resumeIssueRun(_ id: UUID, routine: Routine, run: UUID) async -> RoutineStart {
        guard let session = sessions[id] else { return .failed("The issue's session wasn't found.") }
        if isRunning(id), state(id) == .working || state(id) == .needsYou {
            return .failed("\(session.issue.reference)'s session is busy, so the run will try again.")
        }
        let previous = session.routineRun
        let info = RoutineRunInfo(routine: routine, run: run, resumed: true)
        update(id) { $0.routineRun = info }
        if isRunning(id) {
            end(id)
            let deadline = Date.now.addingTimeInterval(20)
            while isRunning(id), Date.now < deadline {
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        let result: RoutineStart = isRunning(id)
            ? .failed("\(session.issue.reference)'s session didn't stop to take the run's limits, so the run will try again.")
            : await startUnattended(id, prompt: Self.resumedIssuePrompt(session, info: info, note: routine.prompt))
        if case .failed = result { update(id) { $0.routineRun = previous } }
        return result
    }

    /// What a session carrying on for a scheduled run is told: that nobody
    /// is watching, how far it may go, then the routine's own note.
    static func resumedIssuePrompt(_ session: CodeSession, info: RoutineRunInfo, note: String) -> String {
        let extra = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
            Carry on with \(session.issue.reference), "\(session.issue.title)", from where this conversation left off. Gannin has \
            resumed this session by itself for a scheduled run, so nobody is watching now. If you were waiting for a plan to be \
            approved or a question answered, decide for yourself, note why where the work is recorded, and go on.

            \(info.briefSection)
            """ + (extra.isEmpty ? "" : "\n\n" + extra)
    }

    /// An issue run's first prompt: Work on This's, but with nobody to
    /// approve a plan, then the routine's own note.
    static func scheduledIssuePrompt(_ session: CodeSession, note: String) -> String {
        let folder = ".worktrees/\(session.branch)"
        let issue = session.issue
        let extra = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
            You're picking up \(issue.reference), "\(issue.title)", in the team's harness, by yourself on a schedule: nobody is \
            watching. Read \(folder)/.gannin/brief.md first: it has the issue, its discussion, where it sits on the board, any plans \
            for it, and how far this run may go. Work out which repos it touches (those under projects/, or the harness itself when \
            it's the code repo and has no projects/) and look through their code, then write a short plan where the brief says and \
            carry on without waiting for it to be approved. Make the changes in a worktree per repo under \(folder)/, as the brief \
            says, never in projects/ or the harness checkout itself.
            """ + (extra.isEmpty ? "" : "\n\n" + extra)
    }

    /// `routine-<name>-<date>-<4 hex of its ID>`: a new branch each run.
    static func routineBranchName(name: String, id: UUID, on day: Date = .now) -> String {
        let words = String(name.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : " " }).split(separator: " ")
        var slug = ""
        for word in words {
            let next = slug.isEmpty ? String(word) : "\(slug)-\(word)"
            if next.count > 32 { break }
            slug = next
        }
        let date = day.formatted(.iso8601.year().month().day().dateSeparator(.omitted))
        let suffix = id.uuidString.prefix(4).lowercased()
        return (["routine"] + (slug.isEmpty ? [] : [slug]) + [date, suffix]).joined(separator: "-")
    }

    /// A maintenance run's first prompt: the task, and where to work.
    static func maintenancePrompt(_ session: CodeSession) -> String {
        let folder = ".worktrees/\(session.branch)"
        let repos = session.routineRun?.repos ?? [session.issue.repo]
        return """
            You're doing routine maintenance in \(repos.joined(separator: ", ")) for the routine "\(session.routineRun?.name ?? session.issue.title)", \
            in the team's harness, by yourself: nobody is watching. Read \(folder)/.gannin/brief.md first: it has the task and how far \
            you may go. Make the changes in a worktree per repo under \(folder)/, as the brief says, never in projects/ or the harness \
            checkout itself. Don't wait for anyone to approve a plan.

            The task:

            \(session.routineRun?.task.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
            """
    }
}
