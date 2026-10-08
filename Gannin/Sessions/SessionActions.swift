import AppKit
import Foundation

/// A one-click answer to what claude is asking: the keys it takes in the
/// terminal.
struct QuickReply: Identifiable, Hashable {
    let title: String
    let keys: String
    var isDestructive = false

    var id: String { keys + title }
}

/// One of a permission or plan prompt's own numbered choices, read off the
/// terminal's screen rather than assumed: claude draws these as "1. Yes",
/// "2. ...", and so on, inside a box near the cursor.
struct PermissionChoice: Identifiable, Equatable {
    let number: Int
    let label: String
    var id: Int { number }
}

/// A prompt kept for sending to any session: "run the tests".
struct PromptSnippet: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var prompt: String

    static let key = "sessionsSnippets"

    static let defaults: [PromptSnippet] = [
        .init(title: "Run the tests", prompt: "Run the tests for what you've changed, and fix anything that fails."),
        .init(title: "Rebase and push", prompt: "Fetch origin, rebase each worktree's branch on its default branch, resolve any conflicts, run the tests, and push."),
        .init(title: "Write the PR description", prompt: "Write or update the pull request description for each PR: what changed, why, and how it was tested. Keep \"Closes\" for the issue."),
        .init(title: "Explain the changes so far", prompt: "Summarise what you've changed so far, file by file, and what's left to do. Don't change anything."),
        .init(title: "Commit what's done", prompt: "Commit what's done in each worktree with clear messages, and push."),
    ]

    static var saved: [PromptSnippet] {
        get {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let snippets = try? JSONDecoder().decode([PromptSnippet].self, from: data) else { return defaults }
            return snippets
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key)
        }
    }
}

extension SessionStore {
    // MARK: Keys

    /// Sends keys as typed, with no Return: a number picking an option, Esc.
    func sendKeys(_ keys: String, to id: UUID) {
        guard let terminal = terminals[id], terminal.isRunning else { return }
        terminal.press(keys)
    }

    /// Esc, which stops claude mid-turn.
    func interrupt(_ id: UUID) {
        sendKeys("\u{1B}", to: id)
    }

    /// Answers to claude's questions: its dialog is closed (Esc), then the
    /// answers go as one message, each question with its answer, which
    /// claude takes as well as picks in its menu and can't be misread.
    func answer(_ answers: [(question: String, answer: String)], to id: UUID) {
        guard terminals[id]?.isRunning == true else { return }
        sendKeys("\u{1B}", to: id)
        let text = answers.count == 1
            ? "My answer to \"\(answers[0].question)\": \(answers[0].answer)"
            : (["My answers to your questions:", ""] + answers.enumerated().map { "\($0.offset + 1). \($0.element.question)\n   \($0.element.answer)" }).joined(separator: "\n")
        Task {
            // Once the dialog has closed.
            try? await Task.sleep(for: .milliseconds(400))
            submit(text, to: id)
        }
    }

    /// The permission or plan prompt's own choices, read off the terminal's
    /// screen: a run of lines reading "1.", "2." and so on, in its last
    /// rows (claude draws its prompt box near the cursor, at the bottom of
    /// what's shown). Empty until the real prompt has drawn, or if its
    /// wording ever changes enough that this can't find it.
    func permissionChoices(for id: UUID) -> [PermissionChoice] {
        guard let terminal = terminals[id] else { return [] }
        // Box drawing (─│┌┐└┘├┤┬┴┼ and their heavy or double forms): when
        // the box redraws shorter than its last frame, the terminal can
        // leave a stale row's border un-erased past the real text, which
        // would otherwise stick to the label with nothing to trim it on.
        let boxDrawing = CharacterSet(charactersIn: UnicodeScalar(0x2500)!...UnicodeScalar(0x257F)!)
        var choices: [PermissionChoice] = []
        for line in terminal.screenLines(last: 20) {
            let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: "❯>").union(.whitespaces))
            guard let dot = trimmed.firstIndex(of: "."), let number = Int(trimmed[..<dot]), number == choices.count + 1 else { continue }
            var label = String(trimmed[trimmed.index(after: dot)...])
            if let stray = label.unicodeScalars.firstIndex(where: boxDrawing.contains) {
                label = String(label.unicodeScalars[..<stray])
            }
            label = label.trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty else { continue }
            choices.append(PermissionChoice(number: number, label: label))
        }
        return choices
    }

    /// Picks one of the prompt's own choices: Return for the first, else
    /// down arrows to it first, as a person reading the same menu would.
    func selectChoice(_ number: Int, to id: UUID) {
        guard number > 1 else {
            sendKeys("\r", to: id)
            return
        }
        sendKeys(String(repeating: "\u{1B}[B", count: number - 1), to: id)
        Task {
            try? await Task.sleep(for: .milliseconds(120))
            sendKeys("\r", to: id)
        }
    }

    /// Hides a permission prompt's card right away, optimistically, rather
    /// than waiting for the hook that confirms it: `key` is the tool's id
    /// it answered. Checked for a few seconds against the session's real
    /// state, since the keys just sent could land on a prompt that's since
    /// redrawn or closed; if the state never leaves `needsYou`, the approval
    /// didn't go through, so the card comes back.
    func confirmApproval(of key: String, for id: UUID) {
        optimisticApprovals[id] = key
        Task {
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(250))
                guard optimisticApprovals[id] == key else { return }
                if state(id) != .needsYou {
                    optimisticApprovals[id] = nil
                    return
                }
            }
            optimisticApprovals[id] = nil
        }
    }

    /// Picks one of a permission prompt's own choices, by number (1 for
    /// its first, usually Allow): its card hides at once
    /// (`confirmApproval`), and the keys that pick it for real go to the
    /// terminal.
    func approvePermission(_ number: Int, for id: UUID) {
        if let tool = transcripts[id]?.pendingTool { confirmApproval(of: tool.id, for: id) }
        selectChoice(number, to: id)
    }

    /// What a notification offers as quick replies: a lone question's
    /// options, else a permission prompt's own choices read off the
    /// terminal (`permissionChoices`, falling back to plain Allow while
    /// they haven't drawn yet) and Deny. Several questions are answered
    /// in Gannin.
    func quickReplies(for id: UUID) -> [QuickReply] {
        if let question = transcripts[id]?.question {
            guard question.items.count == 1, let item = question.items.first, !item.multiSelect else { return [] }
            return item.options.enumerated().map { QuickReply(title: $0.element.label, keys: "answer:\($0.offset)") }
        }
        guard state(id) == .needsYou else { return [] }
        let choices = permissionChoices(for: id)
        guard let first = choices.first else {
            return [
                QuickReply(title: "Allow", keys: "\r"),
                QuickReply(title: "Deny", keys: "\u{1B}", isDestructive: true),
            ]
        }
        return [QuickReply(title: first.label, keys: "choice:\(first.number)")]
            + choices.dropFirst().dropLast().map { QuickReply(title: $0.label, keys: "choice:\($0.number)") }
            + [QuickReply(title: "Deny", keys: "\u{1B}", isDestructive: true)]
    }

    /// A notification's reply: keys, a lone question's option by index, or
    /// one of a permission prompt's own choices by number.
    func handleQuickReply(_ keys: String, for id: UUID) {
        if keys.hasPrefix("answer:"), let index = Int(keys.dropFirst(7)),
           let item = transcripts[id]?.question?.items.first, item.options.indices.contains(index) {
            answer([(item.question, item.options[index].label.replacingOccurrences(of: " (Recommended)", with: ""))], to: id)
        } else if keys.hasPrefix("choice:"), let number = Int(keys.dropFirst(7)) {
            approvePermission(number, for: id)
        } else {
            sendKeys(keys, to: id)
        }
    }

    // MARK: Pull requests, watched

    /// Fetches every session's PRs on the interval in Settings › Sync (a
    /// shorter one while checks run), flagging a session when a check newly
    /// fails or a reviewer says something new. Sessions with nothing running
    /// and no open PR are left alone, and nothing is fetched while it's
    /// turned off or the budget is low.
    func watchPullRequests() {
        guard watchingPullRequests == nil else { return }
        watchingPullRequests = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if SyncSettings.isOn(.sessionPullRequests) && !self.holdsOff() {
                    for session in self.sessions.values where !session.isHelper && self.needsWatching(session) {
                        await self.refreshPullRequests(session.id)
                    }
                }
                let pending = self.pullRequestInfo.values.joined().contains { $0.state == "OPEN" && !$0.pending.isEmpty }
                try? await Task.sleep(for: .seconds(SyncSettings.interval(pending ? .sessionChecks : .sessionPullRequests)))
            }
        }
    }

    private func needsWatching(_ session: CodeSession) -> Bool {
        guard session.archivedAt == nil else { return false }
        return isRunning(session.id) || (pullRequestInfo[session.id] ?? []).contains { $0.state == "OPEN" }
            || (pullRequestInfo[session.id] == nil && !session.pullRequests.isEmpty)
    }

    /// The session's PRs now, from GitHub.
    func refreshPullRequests(_ id: UUID) async {
        guard let session = sessions[id], let api = api() else { return }
        // PRs the branch search found last time are found by it again, so
        // only the others are looked up by URL.
        let searched = foundBySearch[id] ?? []
        let urls = session.pullRequests.filter { !searched.contains($0) }
        do {
            let result = try await chargingTo(.sessionPullRequests) {
                try await api.sessionPullRequests(org: session.org, branch: session.branch, urls: urls)
            }
            let found = result.pullRequests
            foundBySearch[id] = result.searched
            pullRequestErrors[id] = nil
            if pullRequestInfo[id] != found { pullRequestInfo[id] = found }
            noticeNews(in: found, for: id)
        } catch is CancellationError {
        } catch {
            pullRequestErrors[id] = error.localizedDescription
        }
    }

    /// Send new PR feedback to the session's claude by default.
    static let sendsFeedbackKey = "sessionsSendFeedback"

    /// Whether new failures and feedback on the session's PRs go to its
    /// claude: its own choice, else the user's default.
    func sendsFeedback(_ id: UUID) -> Bool {
        sessions[id]?.sendsFeedback ?? UserDefaults.standard.bool(forKey: Self.sendsFeedbackKey)
    }

    func setSendsFeedback(_ sends: Bool, for id: UUID) {
        update(id) { $0.sendsFeedback = sends }
    }

    /// New failures and feedback since the last look, kept with the
    /// session so a relaunch catches up on what came while Gannin was
    /// closed; the very first look only learns what's there. A thread is
    /// new again when someone other than the PR's author or the signed-in
    /// viewer comments on it since the one last seen: not just its latest
    /// comment, so a quick reply of your own (or the session's Claude's,
    /// running gh as you) between checks doesn't swallow someone else's.
    private func noticeNews(in pullRequests: [SessionPullRequest], for id: UUID) {
        guard let session = sessions[id] else { return }
        let me = viewerLogin()
        var keys: Set<String> = []
        var failed: [(pr: SessionPullRequest, checks: [SessionPullRequest.Check])] = []
        var said: [(pr: SessionPullRequest, items: [SessionPullRequest.Feedback])] = []
        // What to show for a new item: the latest comment on it from
        // someone other than the author or you, keyed by the item's ID.
        var highlights: [String: SessionPullRequest.Comment] = [:]
        let seen = session.pullRequestsSeen
        // Each thread's or review's key now, to drop its older ones.
        var current: [String: String] = [:]
        // Threads seen before at an earlier comment.
        var replies: Set<String> = []
        for pr in pullRequests where pr.state == "OPEN" {
            var newChecks: [SessionPullRequest.Check] = []
            for check in pr.failed {
                let key = "check:\(pr.id):\(check.id)"
                keys.insert(key)
                if seen?.contains(key) == false { newChecks.append(check) }
            }
            var newItems: [SessionPullRequest.Feedback] = []
            for item in pr.feedback {
                keys.insert(item.key)
                current[item.id] = item.key
                guard let seen, !seen.contains(item.key) else { continue }
                let priorKey = seen.first { $0.hasPrefix(item.keyPrefix) }
                if priorKey != nil { replies.insert(item.id) }
                let priorURL = priorKey.map { $0.dropFirst(item.keyPrefix.count) }
                let newComments = priorURL.flatMap { url in item.comments.firstIndex { $0.url.absoluteString == url } }
                    .map { Array(item.comments[($0 + 1)...]) } ?? item.comments
                guard let theirs = newComments.last(where: { !isFromAuthorOrViewer($0.author, of: pr, me: me) }) else { continue }
                highlights[item.id] = theirs
                newItems.append(item)
            }
            if !newChecks.isEmpty { failed.append((pr, newChecks)) }
            if !newItems.isEmpty { said.append((pr, newItems)) }
        }
        // Keys of PRs no longer open are kept: a reopened PR's are still seen.
        if let seen, keys.isSubset(of: seen) { return }
        let outdated = (seen ?? []).filter { key in
            current.contains { key.hasPrefix(SessionPullRequest.Feedback.keyPrefix($0.key)) && key != $0.value }
        }
        update(id) { $0.pullRequestsSeen = (seen ?? []).subtracting(outdated).union(keys) }
        guard seen != nil, !failed.isEmpty || !said.isEmpty else { return }

        // Each as a title and what was said, one notification for them all.
        var news = failed.map { ("Checks failed on \($0.pr.repo)#\($0.pr.number)", $0.checks.map(\.name).joined(separator: ", ")) }
        for (pr, items) in said {
            for item in items {
                guard let comment = highlights[item.id] else { continue }
                let what = replies.contains(item.id) ? "replied" : item.verdict ?? (item.location == nil ? "reviewed" : "commented")
                news.append(("@\(comment.author) \(what) on \(pr.repo)#\(pr.number)", comment.body))
            }
        }
        let sent = sendNews(failed: failed, said: said, to: id)
        let pullRequestCount = Set(failed.map(\.pr.id) + said.map(\.pr.id)).count
        let title = news.count == 1 ? news[0].0 : "\(news.count) new on \(pullRequestCount == 1 ? "a pull request" : "\(pullRequestCount) pull requests")"
        var body = news.count == 1
            ? String(news[0].1.prefix(180))
            : news.map { "\($0.0): \($0.1.split(separator: "\n").first ?? "")".prefix(100) }.joined(separator: "\n")
        switch sent {
        case .pasted: body += "\nSent to Claude."
        case .queued: body += "\nWill go to Claude when it finishes its turn."
        case nil: break
        }
        flag(id, title: title, body: body, replies: false)
    }

    /// Whether a login is the PR's own author or the signed-in viewer,
    /// both compared case-insensitively as GitHub's own casing may differ.
    private func isFromAuthorOrViewer(_ login: String, of pr: SessionPullRequest, me: String?) -> Bool {
        if let author = pr.author, login.caseInsensitiveCompare(author) == .orderedSame { return true }
        if let me, login.caseInsensitiveCompare(me) == .orderedSame { return true }
        return false
    }

    enum FeedbackDelivery { case pasted, queued }

    /// Hands what's new to the session's claude, when it's to be told:
    /// pasted now if it's waiting for a prompt, else once it finishes its
    /// turn (`pendingFeedback`). A session that isn't running isn't started
    /// for it. Marked sent only once it's pasted.
    private func sendNews(
        failed: [(pr: SessionPullRequest, checks: [SessionPullRequest.Check])],
        said: [(pr: SessionPullRequest, items: [SessionPullRequest.Feedback])],
        to id: UUID
    ) -> FeedbackDelivery? {
        guard let session = sessions[id], session.reviewOf == nil, !session.isReviewer,
              sendsFeedback(id), isRunning(id) else { return nil }
        let prompt = (failed.map { SessionPrompts.failures($0.pr, in: session) }
            + said.map { SessionPrompts.feedback($0.items, on: $0.pr, in: session) })
            .joined(separator: "\n\n")
        let keys = said.flatMap { $0.items.map(\.key) } + failed.map { "checks:\($0.pr.id):" + $0.pr.failed.map(\.id).joined(separator: ",") }
        switch state(id) {
        case .idle:
            guard submit(prompt, to: id) else { return nil }
            markSent(keys, for: id)
            return .pasted
        case .starting, .working, .needsYou:
            let queued = pendingFeedback[id]
            pendingFeedback[id] = (
                [queued?.prompt, prompt].compactMap { $0 }.joined(separator: "\n\n"),
                (queued?.keys ?? []) + keys
            )
            return .queued
        default:
            // Claude has exited and left its shell, where a paste would go to bash.
            return nil
        }
    }

    /// Feedback queued while claude was busy, now its turn has ended;
    /// left out if it was all sent from the PRs pane meanwhile.
    func sendPendingFeedback(_ id: UUID) {
        guard let pending = pendingFeedback.removeValue(forKey: id) else { return }
        let sent = self.sent[id] ?? []
        guard !pending.keys.allSatisfy(sent.contains), submit(pending.prompt, to: id) else { return }
        markSent(pending.keys, for: id)
    }

    // MARK: Helpers

    /// Another agent on the session's issue, in its folder on its branch,
    /// with its own conversation: writing tests, say, or reviewing what the
    /// first has done (a reviewer can't edit).
    /// A reviewer is given the team's default review prompts and skills
    /// for the issue's repo and its PRs'.
    func startHelper(for parentID: UUID, role: String, prompt: String, reviewer: Bool) -> CodeSession? {
        guard let parent = sessions[parentID] else { return nil }
        var instructions: String?
        if reviewer, let repo = parent.harnessRepo {
            let repos = [parent.issue.repo] + (pullRequestInfo[parentID] ?? []).map(\.repo)
            let issue = parent.issue
            let values = HarnessPromptLibrary.values(reference: issue.reference, title: issue.title, url: issue.url, repo: issue.repo, number: issue.number, branch: parent.branch)
            instructions = launchInstructions(org: parent.org, setup: HarnessConfig(repo: repo), use: .review, repos: repos, choice: nil, values: values)
                .map(Self.reviewInstructions)
        }
        let helper = CodeSession(
            id: UUID(), issue: parent.issue, repo: parent.repo, branch: parent.branch, createdAt: .now,
            connect: parent.connect, remoteWorkspace: parent.remoteWorkspace,
            harnessRepo: parent.harnessRepo, harnessPath: parent.harnessPath, harnessFolder: parent.harnessFolder,
            parentID: parentID, role: role, prompt: prompt, instructions: instructions, isReviewer: reviewer
        )
        let directory = Self.directory(for: helper.id)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.copyItem(at: Self.directory(for: parentID).appending(path: "brief.md"), to: directory.appending(path: "brief.md"))
        add(helper)
        reveal(helper.id)
        return helper
    }

    /// What a reviewer is asked: read the changes, don't edit, and end with
    /// its findings as JSON Gannin turns into comments. `learnings` are the
    /// harness's, followed where they cover the changes.
    static func reviewPrompt(for session: CodeSession, learnings: [HarnessLearning] = []) -> String {
        let folder = session.isInHarness ? ".worktrees/\(session.branch)/" : "this worktree"
        return """
            You're reviewing another agent's work on \(session.issue.reference), "\(session.issue.title)". The brief is in \(session.isInHarness ? "\(folder).gannin/brief.md" : ".gannin/brief.md"). \
            Look at every change in \(folder) (each repo's worktree, against where its branch left origin's default branch, committed or not) \
            for bugs, missed cases, and code that doesn't fit the repo. Don't edit anything.\(HarnessLearning.reviewInstructions(learnings, listsApplied: false).map { "\n\n\($0)\n\n" } ?? " ")\
            End your reply with your findings as a fenced ```json block: a list of {"path": "<repo folder>/<path in the repo>", "line": <line in the new file>, "comment": "<what's wrong and what to do>"}, most important first.
            """
    }

    /// A reviewer's findings, as comments on the session it reviewed, ready
    /// to send. Paths name the repo's folder first (`api/src/x.go`).
    func importFindings(from reviewerID: UUID) -> Int {
        guard let reviewer = sessions[reviewerID], let parentID = reviewer.parentID, let parent = sessions[parentID],
              let findings = transcripts[reviewerID]?.findings, !findings.isEmpty else { return 0 }
        let folder = Self.worktreePath(for: parent)
        for finding in findings {
            var path = finding.path
            if let range = path.range(of: ".worktrees/\(parent.branch)/") { path = String(path[range.upperBound...]) }
            let parts = path.split(separator: "/", maxSplits: 1).map(String.init)
            let (worktreeName, filePath, worktree) = parent.isInHarness && parts.count == 2
                ? (parts[0], parts[1], "\(folder)/\(parts[0])")
                : ((folder as NSString).lastPathComponent, path, folder)
            addDraft(DiffComment(
                worktree: worktree, worktreeName: worktreeName, path: filePath,
                line: finding.line ?? 1, isOld: false, code: "", body: finding.comment
            ), to: parentID)
        }
        return findings.count
    }

    // MARK: Finishing

    /// Not running and nothing done for three days.
    func isStale(_ session: CodeSession) -> Bool {
        guard !isRunning(session.id) else { return false }
        let last = transcripts[session.id]?.lastActivity ?? session.lastActiveAt ?? session.createdAt
        return -last.timeIntervalSinceNow > 3 * 24 * 60 * 60
    }

    /// Whether every PR the session has is merged, so it can be finished.
    func isFinished(_ id: UUID) -> Bool {
        guard let pullRequests = pullRequestInfo[id], !pullRequests.isEmpty else { return false }
        return pullRequests.allSatisfy { $0.state == "MERGED" }
    }

    /// Ends the session and its helpers, removes its worktrees and the
    /// issue's folder (on its box), marks it finished in the harness, and
    /// forgets it. Throws when the worktrees couldn't be removed.
    func finish(_ id: UUID) async throws {
        guard let session = sessions[id] else { return }
        for helper in helpers(of: id) { end(helper.id) }
        end(id)
        try await removeWorktrees(session)
        await recordFinished(id)
        remove(id)
    }

    /// Finishes a review but keeps it, in the history: claude is ended and
    /// its worktree removed (best effort), and its result, your decisions
    /// and comments stay, to read again or resume.
    func archiveReview(_ id: UUID) async {
        guard let session = sessions[id] else { return }
        end(id)
        try? await removeWorktrees(session)
        update(id) { $0.archivedAt = .now }
        closeTab(id)
    }

    /// Back from the history: claude resumes when its tab next shows.
    func resumeReview(_ id: UUID) {
        update(id) { $0.archivedAt = nil }
        reveal(id)
    }

    /// The session's worktrees, and the issue's folder, removed on its box.
    private func removeWorktrees(_ session: CodeSession) async throws {
        let folder = SessionScript.shellPath(Self.worktreePath(for: session))
        let script = session.isInHarness ? """
            cd \(folder) 2>/dev/null || exit 0
            for d in */; do
              d=${d%/}
              [ -e "$d/.git" ] || continue
              common=$(git -C "$d" rev-parse --path-format=absolute --git-common-dir) || exit 1
              git --git-dir="$common" worktree remove --force "$PWD/$d" || exit 1
            done
            cd .. && rm -rf \(folder)
            """ : """
            [ -e \(folder)/.git ] || exit 0
            common=$(git -C \(folder) rev-parse --path-format=absolute --git-common-dir) || exit 1
            git --git-dir="$common" worktree remove --force \(folder)
            """
        let runner: Shell.Runner
        if let connect = session.connect {
            guard let arguments = Shell.sshArguments(connect) else {
                throw SessionError.message("Its worktrees are on a server reached with \(connect), not ssh, so remove them there.")
            }
            runner = .ssh(arguments)
        } else {
            runner = .local
        }
        let result = await Task.detached { Shell.run(script, runner) }.value
        guard result.ok else { throw SessionError.message(result.error.isEmpty ? "Couldn't remove the worktrees." : result.error) }
    }

    /// Adds `finishedAt` to the session's `session.json` in the harness.
    private func recordFinished(_ id: UUID) async {
        guard let session = sessions[id], let repo = session.harnessRepo, let folder = session.harnessFolder else { return }
        let setup = HarnessConfig(repo: repo)
        let path = "\(folder)/session.json"
        _ = try? await harnessStore.commit(org: session.org, setup: setup, refreshing: false) { head in
            let text = try await self.harnessStore.files(setup: setup, at: head, paths: [path])[path] ?? nil
            guard let text, var record = try? SessionRecord.decoder.decode(SessionRecord.self, from: Data(text.utf8)), record.finishedAt == nil else { return nil }
            record.finishedAt = .now
            return HarnessChange(message: "Gannin: \(session.issue.reference) is finished", files: [path: record.json])
        }
    }

    // MARK: Editors

    /// The server's home folder, asked once, for an editor's remote paths.
    func remoteHome(_ session: CodeSession) async -> String? {
        guard let connect = session.connect, let arguments = Shell.sshArguments(connect) else { return nil }
        if let home = remoteHomes[connect] { return home }
        let result = await Task.detached { Shell.run(#"printf %s "$HOME""#, .ssh(arguments)) }.value
        guard result.ok, !result.output.isEmpty else { return nil }
        remoteHomes[connect] = result.output
        return result.output
    }
}

enum SessionError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message): message
        }
    }
}
