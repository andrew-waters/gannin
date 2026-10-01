#if os(macOS)
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

    /// The permission prompt's second choice: allow, and don't ask again.
    func allowAlways(_ id: UUID) {
        sendKeys("\u{1B}[B", to: id)
        Task {
            try? await Task.sleep(for: .milliseconds(120))
            sendKeys("\r", to: id)
        }
    }

    /// What a notification offers as quick replies: a lone question's
    /// options, else Allow and Deny for a permission prompt. Several
    /// questions are answered in Gannin.
    func quickReplies(for id: UUID) -> [QuickReply] {
        if let question = transcripts[id]?.question {
            guard question.items.count == 1, let item = question.items.first, !item.multiSelect else { return [] }
            return item.options.enumerated().map { QuickReply(title: $0.element.label, keys: "answer:\($0.offset)") }
        }
        guard state(id) == .needsYou else { return [] }
        return [
            QuickReply(title: "Allow", keys: "\r"),
            QuickReply(title: "Deny", keys: "\u{1B}", isDestructive: true),
        ]
    }

    /// A notification's reply: keys, or a lone question's option by index.
    func handleQuickReply(_ keys: String, for id: UUID) {
        if keys.hasPrefix("answer:"), let index = Int(keys.dropFirst(7)),
           let item = transcripts[id]?.question?.items.first, item.options.indices.contains(index) {
            answer([(item.question, item.options[index].label.replacingOccurrences(of: " (Recommended)", with: ""))], to: id)
        } else {
            sendKeys(keys, to: id)
        }
    }

    // MARK: Pull requests, watched

    /// Fetches every session's PRs every minute or so (30 seconds while
    /// checks run), flagging a session when a check newly fails or a
    /// reviewer says something new. Sessions with nothing running and no
    /// open PR are left alone.
    func watchPullRequests() {
        guard watchingPullRequests == nil else { return }
        watchingPullRequests = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                for session in self.sessions.values where !session.isHelper && self.needsWatching(session) {
                    await self.refreshPullRequests(session.id)
                }
                let pending = self.pullRequestInfo.values.joined().contains { $0.state == "OPEN" && !$0.pending.isEmpty }
                try? await Task.sleep(for: .seconds(pending ? 30 : 90))
            }
        }
    }

    private func needsWatching(_ session: CodeSession) -> Bool {
        isRunning(session.id) || (pullRequestInfo[session.id] ?? []).contains { $0.state == "OPEN" }
            || (pullRequestInfo[session.id] == nil && !session.pullRequests.isEmpty)
    }

    /// The session's PRs now, from GitHub.
    func refreshPullRequests(_ id: UUID) async {
        guard let session = sessions[id], let api = api() else { return }
        do {
            let found = try await api.sessionPullRequests(org: session.org, branch: session.branch, urls: session.pullRequests)
            pullRequestErrors[id] = nil
            if pullRequestInfo[id] != found { pullRequestInfo[id] = found }
            noticeNews(in: found, for: id)
        } catch is CancellationError {
        } catch {
            pullRequestErrors[id] = error.localizedDescription
        }
    }

    /// New failures and feedback since the last look; the first look only
    /// learns what's there.
    private func noticeNews(in pullRequests: [SessionPullRequest], for id: UUID) {
        var keys: Set<String> = []
        var failed: [(SessionPullRequest, SessionPullRequest.Check)] = []
        var said: [(SessionPullRequest, SessionPullRequest.Feedback)] = []
        for pr in pullRequests where pr.state == "OPEN" {
            for check in pr.failed {
                keys.insert("check:\(pr.id):\(check.id)")
                failed.append((pr, check))
            }
            for item in pr.feedback {
                keys.insert("feedback:\(item.id)")
                said.append((pr, item))
            }
        }
        defer { pullRequestsSeen[id, default: []].formUnion(keys) }
        guard let seen = pullRequestsSeen[id] else { return }
        let newFailures = failed.filter { !seen.contains("check:\($0.0.id):\($0.1.id)") }
        let newFeedback = said.filter { !seen.contains("feedback:\($0.1.id)") }
        if let (pr, _) = newFailures.first {
            let names = newFailures.map(\.1.name).joined(separator: ", ")
            flag(id, title: "Checks failed on \(pr.repo)#\(pr.number)", body: names, replies: false)
        } else if let (pr, item) = newFeedback.first {
            flag(id, title: "@\(item.author) reviewed \(pr.repo)#\(pr.number)", body: String((item.comments.first?.body ?? "").prefix(180)), replies: false)
        }
    }

    // MARK: Helpers

    /// Another agent on the session's issue, in its folder on its branch,
    /// with its own conversation: writing tests, say, or reviewing what the
    /// first has done (a reviewer can't edit).
    func startHelper(for parentID: UUID, role: String, prompt: String, reviewer: Bool) -> CodeSession? {
        guard let parent = sessions[parentID] else { return nil }
        let helper = CodeSession(
            id: UUID(), issue: parent.issue, repo: parent.repo, branch: parent.branch, createdAt: .now,
            connect: parent.connect, remoteWorkspace: parent.remoteWorkspace,
            harnessRepo: parent.harnessRepo, harnessPath: parent.harnessPath, harnessFolder: parent.harnessFolder,
            parentID: parentID, role: role, prompt: prompt, isReviewer: reviewer
        )
        let directory = Self.directory(for: helper.id)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.copyItem(at: Self.directory(for: parentID).appending(path: "brief.md"), to: directory.appending(path: "brief.md"))
        add(helper)
        reveal(helper.id)
        return helper
    }

    /// What a reviewer is asked: read the changes, don't edit, and end with
    /// its findings as JSON Gannin turns into comments.
    static func reviewPrompt(for session: CodeSession) -> String {
        let folder = session.isInHarness ? ".worktrees/\(session.branch)/" : "this worktree"
        return """
            You're reviewing another agent's work on \(session.issue.reference), "\(session.issue.title)". The brief is in \(session.isInHarness ? "\(folder).gannin/brief.md" : ".gannin/brief.md"). \
            Look at every change in \(folder) (each repo's worktree, against where its branch left origin's default branch, committed or not) \
            for bugs, missed cases, and code that doesn't fit the repo. Don't edit anything. \
            End your reply with your findings as a fenced ```json block: a list of {"path": "<repo folder>/<path in the repo>", "line": <line in the new file>, "comment": "<what's wrong and what to do>"}, most important first.
            """
    }

    /// A reviewer's findings, as comments on the session it reviewed, ready
    /// to send. Paths name the repo's folder first (`mono/src/x.go`).
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
        let runner: SessionChanges.Runner
        if let connect = session.connect {
            guard let arguments = SessionChanges.sshArguments(connect) else {
                throw SessionError.message("Its worktrees are on a server reached with \(connect), not ssh, so remove them there.")
            }
            runner = .ssh(arguments)
        } else {
            runner = .local
        }
        let result = await Task.detached { SessionChanges.run(script, runner) }.value
        guard result.ok else { throw SessionError.message(result.error.isEmpty ? "Couldn't remove the worktrees." : result.error) }
        await recordFinished(id)
        remove(id)
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
        guard let connect = session.connect, let arguments = SessionChanges.sshArguments(connect) else { return nil }
        if let home = remoteHomes[connect] { return home }
        let result = await Task.detached { SessionChanges.run(#"printf %s "$HOME""#, .ssh(arguments)) }.value
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
#endif
