import Foundation
import Testing
@testable import Gannin

/// A second agent reviewing a session's change: the rounds, its findings
/// and the script the working agent runs.
struct PairReviewTests {
    private func session(inHarness: Bool = true) -> CodeSession {
        let issue = IssueReference(
            org: "acme", id: "I_1", number: 68, title: "Pair review", repo: "acme/app",
            url: URL(string: "https://github.com/acme/app/issues/68")!
        )
        return CodeSession(
            id: UUID(), issue: issue, repo: "acme/harness", branch: "68-pair-review", createdAt: .now,
            harnessRepo: inHarness ? "acme/harness" : nil, harnessPath: inHarness ? "~/Code/acme/harness" : nil
        )
    }

    private func transcript(_ reply: String) -> SessionTranscript {
        var transcript = SessionTranscript()
        transcript.lastReply = reply
        return transcript
    }

    @Test func roundWithFindingsGoesBackToBeFixed() {
        var pairing = PairReview()
        pairing.finishRound(findings: 2, reply: "a")
        #expect(pairing.phase == .fixing)
        #expect(pairing.round == 1)
        #expect(pairing.lastReply == "a")
        #expect(!pairing.isOver)
    }

    @Test func roundWithNothingSettles() {
        var pairing = PairReview(round: 1, phase: .reviewing)
        pairing.finishRound(findings: 0, reply: "b")
        #expect(pairing.phase == .settled)
        #expect(pairing.endedAt != nil)
        #expect(pairing.status == "Settled after 2 rounds: nothing more to fix")
    }

    @Test func lastRoundStopsAtTheLimit() {
        var pairing = PairReview(round: PairReview.maxRounds - 1, phase: .reviewing)
        pairing.finishRound(findings: 1, reply: "c")
        #expect(pairing.phase == .limit)
        #expect(pairing.isOver)
    }

    @Test func emptyListIsAnAnswer() {
        #expect(transcript("Nothing left.\n\n```json\n[]\n```").listedFindings == [])
        #expect(transcript("Still reading the diff.").listedFindings == nil)
        let found = transcript(#"Two things.\#n```json\#n[{"path": "app/a.swift", "line": 3, "comment": "Off by one"}]\#n```"#).listedFindings
        #expect(found?.count == 1)
        #expect(found?.first?.line == 3)
    }

    @Test func onlyAnIssuesOwnSessionPairs() {
        var helper = session()
        helper.parentID = UUID()
        #expect(session().canPairReview)
        #expect(!helper.canPairReview)
    }

    @Test func scriptPathFollowsWhereClaudeRuns() {
        #expect(session().readyForReviewScript == ".worktrees/68-pair-review/.gannin/ready-for-review")
        #expect(session(inHarness: false).readyForReviewScript == ".gannin/ready-for-review")
    }

    @Test func briefsPullRequestStepAsksForTheReviewFirst() {
        func brief(_ session: CodeSession) -> String {
            SessionBrief.make(session: session, record: nil, detail: nil, parent: nil, harness: nil)
        }
        func asks(_ script: String) -> String {
            "run `\(script) \"<what changed and where to look>\"` and wait for its outcome (opening it as a draft first is fine)."
        }

        let issue = brief(session())
        #expect(issue.contains("Before opening it as ready for review, " + asks(".worktrees/68-pair-review/.gannin/ready-for-review")))
        #expect(brief(session(inHarness: false)).contains(asks(".gannin/ready-for-review")))

        var noIssue = session()
        noIssue.quickChange = QuickChangeInfo(note: "Nudge it", attachments: [], hasIssue: false)
        #expect(brief(noIssue).contains(asks(".worktrees/68-pair-review/.gannin/ready-for-review")))

        var helper = session()
        helper.parentID = UUID()
        #expect(!brief(helper).contains("Before opening it as ready for review"))

        var local = session()
        var routine = Routine.new(org: "acme", harnessRepo: "acme/harness", kind: .code, name: "Tidy dependencies")
        routine.limit = .localOnly
        local.routineRun = RoutineRunInfo(routine: routine, run: UUID())
        #expect(!brief(local).contains("Before opening it as ready for review"))
    }

    @Test func scriptWritesTheRequestIntoTheSessionsFolder() {
        let script = SessionScript.readyForReview(session(), directory: #""$HOME"/.gannin/sessions/x"#)
        #expect(script.hasPrefix("#!/bin/bash\n"))
        #expect(script.contains(#"> "$HOME"/.gannin/sessions/x/review-request"#))
        #expect(script.contains(#"tr '\n' ' '"#))
    }

    @Test func settingsAllowTheScript() throws {
        let json = SessionScript.settings(directory: "/tmp/s", isRemote: true, allowing: [".gannin/ready-for-review"])
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let allow = (object["permissions"] as? [String: Any])?["allow"] as? [String]
        #expect(allow == ["Bash(.gannin/ready-for-review:*)"])
        let none = SessionScript.settings(directory: "/tmp/s", isRemote: true)
        #expect(!none.contains("permissions"))
    }

    @Test func findingsPromptSaysWhatsNext() {
        let findings = [SessionTranscript.Finding(path: "app/a.swift", line: 3, comment: "Off by one")]
        let again = SessionStore.findingsPrompt(findings, round: 1, script: ".gannin/ready-for-review", last: false)
        #expect(again.contains("1. `app/a.swift:3`: Off by one"))
        #expect(again.contains("run `.gannin/ready-for-review"))
        let last = SessionStore.findingsPrompt(findings, round: 3, script: ".gannin/ready-for-review", last: true)
        #expect(last.contains("last round"))
    }

    // MARK: Extra reviewers

    private func finding(_ path: String, _ line: Int?, _ comment: String) -> SessionTranscript.Finding {
        SessionTranscript.Finding(path: path, line: line, comment: comment)
    }

    private func result(_ text: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: ["sessionId": "s", "result": text, "changes": []])
        return String(decoding: data, as: UTF8.self)
    }

    private func outcome(status: Int32 = 0, _ output: String, error: String = "") -> ExtraReviewer.Outcome {
        ExtraReviewer.junie.outcome(for: (status, output, error))
    }

    @Test func junieFindingsAreReadFromItsResultFile() {
        let reply = result("Found one thing.\n\n```json\n[{\"path\": \"app/a.swift\", \"line\": 3, \"comment\": \"Off by one\"}]\n```")
        #expect(outcome(reply) == .findings([finding("app/a.swift", 3, "Off by one")]))
        #expect(outcome(result("Nothing.\n\n```json\n[]\n```")) == .findings([]))
    }

    @Test func junieOutputWithoutAListOrAResultFails() {
        #expect(outcome(result("I looked at it.")) == .failed("Junie replied with no list of findings."))
        #expect(outcome("not json") == .failed("Junie didn't write a result."))
        #expect(outcome("{\"sessionId\": \"s\"}") == .failed("Junie didn't write a result."))
        #expect(outcome(result("```json\n[{\"path\": 1}]\n```")) == .failed("Junie replied with no list of findings."))
    }

    @Test func aFailedJunieRunSaysWhy() {
        #expect(outcome(status: 127, "", error: "junie is not installed on this Mac (not found on PATH)") == .failed("junie is not installed on this Mac (not found on PATH)"))
        #expect(outcome(status: ExtraReviewer.timedOut, "") == .failed("Junie timed out after 10 minutes."))
        #expect(outcome(status: 1, "", error: "Quota could not be found") == .failed("Junie failed: Quota could not be found"))
        #expect(outcome(status: 2, "") == .failed("Junie failed (exit 2)."))
    }

    @Test func junieRunsInACopyAndLeavesItsOwnOutputOut() {
        let script = ExtraReviewer.junie.script(folder: URL(filePath: "/Users/me/code/harness/.worktrees/68-pair-review"), prompt: "Review it")
        #expect(script.contains("'/Users/me/code/harness/.worktrees/68-pair-review'"))
        #expect(script.contains(#"--project "$d/project""#))
        #expect(script.contains("--timeout 600000"))
        #expect(script.contains(#"trap 'rm -rf "$d"' EXIT"#))
        #expect(script.contains(#">"$d/stdout""#))
    }

    /// Runs `args` and returns its status and standard output.
    @discardableResult
    private func run(_ args: [String], in folder: URL? = nil, environment: [String: String] = [:], input: String? = nil) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(filePath: args[0])
        process.arguments = Array(args.dropFirst())
        process.currentDirectoryURL = folder
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let stdin = Pipe()
        process.standardInput = stdin
        try process.run()
        if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
        try stdin.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// A fake `junie` that runs `body` in the project it's given, then writes an empty list.
    private func fakeJunie(in bin: URL, body: String) throws {
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let script = """
            #!/bin/bash
            while [ $# -gt 0 ]; do
              case "$1" in
                --project) project="$2"; shift 2 ;;
                --json-output-file) out="$2"; shift 2 ;;
                --output-format|--timeout) shift 2 ;;
                --skip-update-check) shift ;;
                *) shift ;;
              esac
            done
            # Reads stdin, as a CLI checking for piped input does: the script's own, if it were passed on.
            cat > /dev/null
            cd "$project/repo"
            \(body)
            printf '{"result":"```json\\\\n[]\\\\n```"}' > "$out"
            """
        let url = bin.appending(path: "junie")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    @Test func junieCantChangeTheRealWorktreeOrItsGit() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "ExtraReviewerGit-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let main = root.appending(path: "main"), folder = root.appending(path: "worktrees"), repo = folder.appending(path: "repo")
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        let git = "/usr/bin/git"
        let environment = [
            "PATH": "\(root.appending(path: "bin").path):/usr/bin:/bin", "HOME": root.path, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null",
            "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com",
        ]
        try run([git, "init", "-q", "-b", "main"], in: main, environment: environment)
        try "original\n".write(to: main.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        try run([git, "add", "-A"], in: main, environment: environment)
        try run([git, "commit", "-q", "-m", "first"], in: main, environment: environment)
        try run([git, "worktree", "add", "-q", repo.path, "-b", "feature"], in: main, environment: environment)

        // A submodule's `.git` file, whose git dir has no commondir, mustn't stop the review.
        try FileManager.default.createDirectory(at: root.appending(path: "modules/sub"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appending(path: "sub"), withIntermediateDirectories: true)
        try "gitdir: \(root.path)/modules/sub\n".write(to: folder.appending(path: "sub/.git"), atomically: true, encoding: .utf8)

        // Edits a file, commits, makes a branch and resets: all of it in the copy.
        try fakeJunie(in: root.appending(path: "bin"), body: "echo changed > a.txt; git add -A; git commit -q -m edit; git checkout -q -b other; git reset -q --hard HEAD~1; echo again > b.txt")
        let script = ExtraReviewer.junie.script(folder: folder, prompt: "Review it")
        let result = try run(["/bin/bash", "-s"], environment: environment, input: script)

        #expect(result.status == 0)
        #expect(ExtraReviewer.junie.outcome(for: (result.status, result.output, "")) == .findings([]))
        #expect(try String(contentsOf: repo.appending(path: "a.txt"), encoding: .utf8) == "original\n")
        #expect(!FileManager.default.fileExists(atPath: repo.appending(path: "b.txt").path))
        #expect(try run([git, "rev-parse", "--abbrev-ref", "HEAD"], in: repo, environment: environment).output == "feature\n")
        #expect(try run([git, "branch", "--list", "other"], in: main, environment: environment).output == "")
        #expect(try run([git, "rev-list", "--count", "feature"], in: main, environment: environment).output == "1\n")
        #expect(try run([git, "status", "--porcelain"], in: repo, environment: environment).output == "")
    }

    @Test func aTimedOutJunieAndEverythingItStartedIsStopped() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "ExtraReviewerTimeout-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "worktrees")
        try FileManager.default.createDirectory(at: folder.appending(path: "repo"), withIntermediateDirectories: true)
        let pidFile = root.appending(path: "child.pid")
        try fakeJunie(in: root.appending(path: "bin"), body: "sleep 300 & echo $! > \(pidFile.path); wait")
        let script = ExtraReviewer.junie.script(folder: folder, prompt: "Review it", timeout: 1, slack: 0)
        let environment = ["PATH": "\(root.appending(path: "bin").path):/usr/bin:/bin"]
        let result = try run(["/bin/bash", "-s"], environment: environment, input: script)

        #expect(result.status == ExtraReviewer.timedOut)
        let child = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        // Gone, or on its way out as signals are delivered.
        var alive = true
        for _ in 0..<50 where alive {
            alive = kill(child, 0) == 0
            if alive { Thread.sleep(forTimeInterval: 0.1) }
        }
        #expect(!alive)
    }

    @Test func anExtraLeftRunningByAQuitIsFailedAndDoesntHoldTheRoundUp() throws {
        var pairing = PairReview()
        pairing.startExtras([.junie])
        // Saved mid-round, then read back by the next launch.
        pairing = try JSONDecoder().decode(PairReview.self, from: JSONEncoder().encode(pairing))
        #expect(pairing.isWaitingOnExtras)
        let found = pairing.abandonRunningExtras("Gannin quit while it was running.")
        #expect(found)
        #expect(!pairing.isWaitingOnExtras)
        pairing.claudeAnswered([finding("app/b.swift", nil, "Missing test")], reply: "r1")
        #expect(pairing.isRoundComplete)
        #expect(pairing.mergedFindings.map(\.comment) == ["Missing test"])
        let again = pairing.abandonRunningExtras("x")
        #expect(!again)
    }

    @Test func aRunThatNeverEndsIsGivenUpOn() async {
        let outcome = await ExtraReviewer.junie.review(folder: URL(filePath: "/tmp"), prompt: "x", limit: 0.05) { _ in
            try? await Task.sleep(for: .seconds(30))
            return (0, "", "")
        }
        #expect(outcome == .failed("Junie timed out after 10 minutes."))
    }

    @Test func mergingKeepsEachFindingOnceAndSaysWhoRaisedIt() {
        let both = finding("app/a.swift", 3, "Off by one")
        let merged = PairReview.merge(
            claude: [both, finding("app/b.swift", nil, "Missing test")],
            extras: [("Junie", [both, finding("app/c.swift", 9, "Leaks the file handle")])]
        )
        #expect(merged.map(\.comment) == ["Off by one", "Missing test", "Leaks the file handle"])
        #expect(merged.map(\.reviewer) == ["claude and Junie", "claude", "Junie"])
    }

    @Test func mergingWithNoExtraLeavesClaudesAlone() {
        let list = [finding("app/a.swift", 3, "Off by one")]
        #expect(PairReview.merge(claude: list, extras: []) == list)
        #expect(PairReview.merge(claude: list, extras: []).first?.reviewer == nil)
    }

    @Test func labelsReachTheWorkingAgentOnlyWithAnExtra() {
        var raised = finding("app/a.swift", 3, "Off by one")
        let plain = SessionStore.findingsPrompt([raised], round: 1, script: ".gannin/ready-for-review", last: false)
        #expect(plain.contains("1. `app/a.swift:3`: Off by one"))
        raised.reviewer = "Junie"
        let labelled = SessionStore.findingsPrompt([raised], round: 1, script: ".gannin/ready-for-review", last: false)
        #expect(labelled.contains("1. `app/a.swift:3` (Junie): Off by one"))
    }

    @Test func roundWaitsForJunieThenFinishesOnce() {
        var pairing = PairReview()
        pairing.startExtras([.junie])
        let run = pairing.extras![ExtraReviewer.junie.id]!.run
        pairing.claudeAnswered([], reply: "r1")
        #expect(!pairing.isRoundComplete)

        let taken = pairing.extraFinished(.junie, run: run, outcome: .findings([finding("app/a.swift", 3, "Off by one")]))
        #expect(taken)
        #expect(pairing.isRoundComplete)
        #expect(pairing.mergedFindings.count == 1)
        pairing.finishMergedRound()
        #expect(pairing.phase == .fixing)
        #expect(pairing.findings == 1)
        #expect(pairing.round == 1)

        // A second answer from the same run isn't taken.
        let again = pairing.extraFinished(.junie, run: run, outcome: .findings([]))
        #expect(!again)
    }

    @Test func junieFirstOrClaudeFirstGivesTheSameRound() {
        var pairing = PairReview()
        pairing.startExtras([.junie])
        let run = pairing.extras![ExtraReviewer.junie.id]!.run
        _ = pairing.extraFinished(.junie, run: run, outcome: .findings([]))
        #expect(!pairing.isRoundComplete)
        pairing.claudeAnswered([], reply: "r1")
        #expect(pairing.isRoundComplete)
        pairing.finishMergedRound()
        #expect(pairing.phase == .settled)
    }

    @Test func aFailedJunieDoesntHoldUpClaudesRound() {
        var pairing = PairReview()
        pairing.startExtras([.junie])
        let run = pairing.extras![ExtraReviewer.junie.id]!.run
        pairing.claudeAnswered([finding("app/b.swift", nil, "Missing test")], reply: "r1")
        let taken = pairing.extraFinished(.junie, run: run, outcome: .failed("Junie failed: signed out"))
        #expect(taken)
        #expect(pairing.isRoundComplete)
        #expect(pairing.extras?[ExtraReviewer.junie.id]?.message == "Junie failed: signed out")
        #expect(pairing.mergedFindings.map(\.comment) == ["Missing test"])
        #expect(pairing.mergedFindings.first?.reviewer == nil)
    }

    @Test func aRunFromAnEarlierLoopCantAnswerForTheNewOne() {
        var pairing = PairReview()
        pairing.startExtras([.junie])
        let old = pairing.extras![ExtraReviewer.junie.id]!.run
        pairing.startExtras([.junie])
        let taken = pairing.extraFinished(.junie, run: old, outcome: .findings([]))
        #expect(!taken)
        #expect(pairing.isWaitingOnExtras)
    }

    @Test func withNoExtraTheRoundNeedsOnlyClaude() {
        var pairing = PairReview()
        pairing.startExtras([])
        #expect(pairing.extras == nil)
        pairing.claudeAnswered([finding("app/a.swift", 3, "Off by one")], reply: "r1")
        #expect(pairing.isRoundComplete)
        #expect(pairing.mergedFindings.first?.reviewer == nil)
    }

    @Test func aPairingSavedBeforeExtrasStillDecodes() throws {
        let old = #"{"round": 1, "phase": "fixing", "findings": 2}"#
        let pairing = try JSONDecoder().decode(PairReview.self, from: Data(old.utf8))
        #expect(pairing.extras == nil)
        #expect(pairing.claudeFindings == nil)
    }

    @Test func projectsExtraReviewersDefaultToNoneAndIgnoreUnknownOnes() throws {
        var setup = HarnessConfig(repo: "acme/harness")
        #expect(setup.enabledExtraReviewers.isEmpty)
        setup.setExtraReviewer(.junie, enabled: true)
        #expect(setup.enabledExtraReviewers == [.junie])
        setup.setExtraReviewer(.junie, enabled: false)
        #expect(setup.extraReviewers == nil)

        let saved = #"{"repo": "acme/harness", "extraReviewers": ["junie", "someone-newer"]}"#
        let decoded = try JSONDecoder().decode(HarnessConfig.self, from: Data(saved.utf8))
        #expect(decoded.enabledExtraReviewers == [.junie])
        let before = try JSONDecoder().decode(HarnessConfig.self, from: Data(#"{"repo": "acme/harness"}"#.utf8))
        #expect(before.enabledExtraReviewers.isEmpty)
    }

    @Test func extrasDontRunInASandboxOrOnAServer() {
        let folder = FileManager.default.temporaryDirectory.appending(path: "PairReviewTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SessionStore(harness: HarnessStore(auth: AuthStore()), directory: folder, saveDelay: .seconds(60), defaults: UserDefaults(suiteName: "PairReviewTests-\(UUID().uuidString)")!)
        store.extraReviewers = { _ in [.junie] }
        var local = session()
        #expect(store.enabledExtraReviewers(for: local) == [.junie])
        local.sandbox = "box"
        #expect(store.enabledExtraReviewers(for: local).isEmpty)
        var remote = session()
        remote.connect = "me@server"
        #expect(store.enabledExtraReviewers(for: remote).isEmpty)
    }

    @Test func theCopysPromptNamesNoHarnessFolder() {
        let inRepo = SessionStore.reviewPrompt(for: session())
        let inCopy = SessionStore.reviewPrompt(for: session(), inCopy: true)
        #expect(inRepo.contains(".worktrees/68-pair-review/"))
        #expect(!inCopy.contains(".worktrees/68-pair-review/"))
        #expect(inCopy.contains("The brief is in .gannin/brief.md"))
    }

    // MARK: A reviewer whose sandbox failed

    /// A store with a working session and its reviewer helper in a sandbox, the
    /// pairing saved as `phase`.
    private func paired(_ phase: PairReview.Phase, in folder: URL) -> (store: SessionStore, parent: UUID, reviewer: UUID) {
        let store = SessionStore(harness: HarnessStore(auth: AuthStore()), directory: folder, saveDelay: .seconds(60), defaults: UserDefaults(suiteName: "PairReviewTests-\(UUID().uuidString)")!)
        var parent = session()
        parent.sandbox = SandboxPlacement.containerName(for: parent.id)
        let reviewer = CodeSession(
            id: UUID(), issue: parent.issue, repo: parent.repo, branch: parent.branch, createdAt: .now,
            harnessRepo: parent.harnessRepo, harnessPath: parent.harnessPath,
            parentID: parent.id, role: "Review", prompt: "Review it", isReviewer: true, sandbox: parent.sandbox
        )
        parent.pairing = PairReview(reviewerID: reviewer.id, round: 1, phase: phase, lastReply: "reply")
        store.add(parent)
        store.add(reviewer)
        return (store, parent.id, reviewer.id)
    }

    @Test(arguments: [PairReview.Phase.reviewing, .fixing, .settled, .limit, .stopped])
    func aReviewerWhoseSandboxFailedIsReplaced(phase: PairReview.Phase) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "PairReviewTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (store, parent, reviewer) = paired(phase, in: folder)
        store.sandboxStatus[reviewer] = "failed: The sandbox didn't start."
        store.pendingPrompts[reviewer] = "Look again"
        var pairing = store.sessions[parent]!.pairing!

        #expect(store.replaceFailedReviewer(of: parent, in: &pairing))

        // Nothing is left for a new request to find and wait on, whichever
        // branch of reviewRequested it would have taken.
        #expect(pairing.reviewerID == nil)
        #expect(pairing.lastReply == nil)
        #expect(pairing.phase == phase)
        #expect(store.sessions[parent]?.pairing?.reviewerID == nil)
        #expect(store.sessions[reviewer] == nil)
        #expect(store.helpers(of: parent).isEmpty)
        #expect(store.pendingPrompts[reviewer] == nil)
        // The issue's own session, and so its sandbox, stays.
        #expect(store.sessions[parent] != nil)
    }

    @Test(arguments: [PairReview.Phase.settled, .limit, .stopped])
    func reviewNowSaysWhyWhenTheSessionIsntRunning(phase: PairReview.Phase) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "PairReviewTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (store, parent, _) = paired(phase, in: folder)
        let before = store.sessions[parent]?.pairing

        store.reviewRequested(parent, note: "", byYou: true)

        #expect(store.pairReviewProblems[parent] != nil)
        #expect(store.sessions[parent]?.pairing == before)
    }

    @Test func aReviewerWhoseSandboxStartedIsKept() {
        let folder = FileManager.default.temporaryDirectory.appending(path: "PairReviewTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (store, parent, reviewer) = paired(.reviewing, in: folder)
        var pairing = store.sessions[parent]!.pairing!
        for status in [nil, "starting", "running"] {
            store.sandboxStatus[reviewer] = status
            #expect(!store.replaceFailedReviewer(of: parent, in: &pairing))
        }
        #expect(pairing.reviewerID == reviewer)
        #expect(store.sessions[reviewer] != nil)
    }
}
