import SwiftUI

/// A pull request from a session: its state, checks and the review on it,
/// for the session's tab to show and hand back to claude.
struct SessionPullRequest: Identifiable, Hashable {
    struct Check: Identifiable, Hashable {
        enum State { case failed, pending, passed, skipped }
        let name: String
        let state: State
        let url: URL?
        /// The Actions run, for `gh run view`.
        let runID: Int?

        var id: String { name + (url?.absoluteString ?? "") }
    }

    struct Comment: Hashable {
        let author: String
        let body: String
        let url: URL
    }

    /// Something a reviewer asked for: an unresolved thread on a line, or
    /// a review's own words.
    struct Feedback: Identifiable, Hashable {
        let id: String
        let author: String
        /// `path:line`, for a thread.
        let location: String?
        /// "changes requested", for a review.
        let verdict: String?
        let comments: [Comment]

        /// Seen at its latest comment, so a reply makes it new again.
        var key: String { keyPrefix + (comments.last?.url.absoluteString ?? "") }
        /// What every key it's had starts with.
        var keyPrefix: String { Self.keyPrefix(id) }
        static func keyPrefix(_ id: String) -> String { "feedback:\(id):" }
        /// Who said the newest thing in it.
        var latestAuthor: String { comments.last?.author ?? author }
    }

    let id: String
    let number: Int
    let title: String
    let url: URL
    let repo: String
    /// Its author's login: their own replies aren't feedback.
    let author: String?
    /// `OPEN`, `MERGED` or `CLOSED`.
    let state: String
    let isDraft: Bool
    /// `APPROVED`, `CHANGES_REQUESTED`, `REVIEW_REQUIRED`.
    let reviewDecision: String?
    /// `CONFLICTING` when it needs a rebase.
    let mergeable: String?
    let checks: [Check]
    let feedback: [Feedback]

    var failed: [Check] { checks.filter { $0.state == .failed } }
    var pending: [Check] { checks.filter { $0.state == .pending } }

    var stateLabel: String {
        switch state {
        case "MERGED": "Merged"
        case "CLOSED": "Closed"
        default: isDraft ? "Draft" : "Open"
        }
    }

    var stateColor: Color {
        switch state {
        case "MERGED": .purple
        case "CLOSED": .secondary
        default: isDraft ? .secondary : .green
        }
    }
}

// MARK: - Prompts

enum SessionPrompts {
    /// Where the repo's code is for claude: its worktree in the issue's
    /// folder, or here for a session from before the harness.
    private static func worktree(for repo: String, in session: CodeSession) -> String {
        let name = repo.split(separator: "/").last.map(String.init) ?? repo
        return session.isInHarness ? "`.worktrees/\(session.branch)/\(name)`" : "this worktree"
    }

    static func failures(_ pr: SessionPullRequest, in session: CodeSession) -> String {
        var lines = ["CI is failing on \(pr.repo)#\(pr.number) (\(pr.url.absoluteString)):", ""]
        for check in pr.failed {
            var line = "- \(check.name)"
            if let url = check.url { line += ": \(url.absoluteString)" }
            if let run = check.runID { line += " (`gh run view \(run) --repo \(pr.repo) --log-failed`)" }
            lines.append(line)
        }
        lines += [
            "",
            "Read the failing logs, find the cause and fix it in \(worktree(for: pr.repo, in: session)). Run what you can locally, then commit and push, and tell me what it was.",
        ]
        return lines.joined(separator: "\n")
    }

    static func feedback(_ items: [SessionPullRequest.Feedback], on pr: SessionPullRequest, in session: CodeSession) -> String {
        var lines = ["Review feedback on \(pr.repo)#\(pr.number) (\(pr.url.absoluteString)):", ""]
        for item in items {
            var heading = "@\(item.author)"
            if let location = item.location { heading += " on `\(location)`" }
            if let verdict = item.verdict { heading += " (\(verdict))" }
            lines.append(heading + ":")
            for comment in item.comments {
                if comment.author != item.author { lines.append("@\(comment.author) replied:") }
                lines += comment.body.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }
            }
            lines.append("")
        }
        lines.append("Address each in \(worktree(for: pr.repo, in: session)), then commit and push. Tell me what you changed, and anything you'd push back on rather than change.")
        return lines.joined(separator: "\n")
    }

    static func diffComments(_ comments: [DiffComment], in session: CodeSession) -> String {
        var lines = ["Comments on your changes so far:", ""]
        for comment in comments {
            let path = session.isInHarness ? ".worktrees/\(session.branch)/\(comment.worktreeName)/\(comment.path)" : comment.path
            lines.append("`\(path):\(comment.line)`\(comment.isOld ? " (a line you removed)" : "")")
            let code = comment.code.trimmingCharacters(in: .whitespaces)
            if !code.isEmpty { lines.append("    \(code)") }
            lines += [comment.body, ""]
        }
        lines.append("Address these, then carry on.")
        return lines.joined(separator: "\n")
    }
}

// MARK: - The pane

/// The session's pull requests: state, review, checks (failures first,
/// with Send to Claude), and the review feedback still open, ticked to send.
struct SessionPullRequestsPane: View {
    @Environment(SessionStore.self) private var sessions
    @Environment(AuthStore.self) private var auth
    let session: CodeSession
    /// Feedback left unticked, by ID.
    @State private var unticked: Set<String> = []
    /// The PR whose "Re-run Failed Checks" confirmation is open, by ID.
    @State private var confirmingRerun: String?
    /// The PR currently re-running checks, by ID.
    @State private var rerunningPR: String?
    /// The PR a re-run failed for, and why.
    @State private var rerunError: (prID: String, message: String)?

    /// A helper's are its issue session's.
    private var owner: UUID { session.parentID ?? session.id }

    var body: some View {
        let pullRequests = sessions.pullRequestInfo[owner]
        let error = sessions.pullRequestErrors[owner]
        if pullRequests == nil, error == nil {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let pullRequests, !pullRequests.isEmpty {
            Form {
                Section {
                    Toggle("Send new feedback to Claude", isOn: Binding(
                        get: { sessions.sendsFeedback(owner) },
                        set: { sessions.setSendsFeedback($0, for: owner) }
                    ))
                    .help("New failing checks and review comments are pasted into the session for Claude to address: now if it's waiting for you, else when it finishes its turn. Settings > General > Agent sets the default.")
                }
                ForEach(pullRequests) { pr in
                    section(pr)
                }
                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView {
                Label("No pull requests yet", systemImage: "arrow.triangle.pull")
            } description: {
                Text(error ?? "When claude opens one, or one is opened from \(session.branch), it shows here with its checks and review.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func section(_ pr: SessionPullRequest) -> some View {
        let running = sessions.isRunning(session.id)
        let sent = sessions.sent[session.id] ?? []
        Section {
            Link(destination: pr.url) {
                Text(pr.title)
                    .fontWeight(.semibold)
                    .multilineTextAlignment(.leading)
            }
            HStack(spacing: 12) {
                Label(pr.stateLabel, systemImage: "circle.fill")
                    .foregroundStyle(pr.stateColor)
                if let review = reviewLabel(pr) {
                    Text(review).foregroundStyle(pr.reviewDecision == "CHANGES_REQUESTED" ? .orange : .secondary)
                }
                if pr.mergeable == "CONFLICTING", pr.state == "OPEN" {
                    Text("Conflicts").foregroundStyle(ChartPalette.critical)
                }
            }
            .font(.callout)
            .labelStyle(DotLabelStyle())

            if !pr.checks.isEmpty {
                LabeledContent("Checks", value: summary(pr.checks))
                ForEach(pr.failed) { check in
                    checkRow(check, color: ChartPalette.critical, symbol: "xmark.circle.fill")
                }
                ForEach(pr.pending.prefix(5)) { check in
                    checkRow(check, color: .orange, symbol: "clock")
                }
                if !pr.failed.isEmpty, pr.state == "OPEN" {
                    let key = "checks:\(pr.id):" + pr.failed.map(\.id).joined(separator: ",")
                    let runIDs = Set(pr.failed.compactMap(\.runID))
                    HStack {
                        if sent.contains(key) { Text("Sent to Claude").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        if !runIDs.isEmpty {
                            Button("Re-run Failed Checks") { confirmingRerun = pr.id }
                                .disabled(rerunningPR == pr.id)
                                .help("Ask GitHub to run the failed jobs again")
                        }
                        Button("Send Failures to Claude") {
                            if sessions.submit(SessionPrompts.failures(pr, in: session), to: session.id) {
                                sessions.markSent([key], for: session.id)
                            }
                        }
                        .disabled(!running)
                        .help(running ? "Paste the failing checks, with how to read their logs, into claude's prompt" : "Start the session first")
                    }
                    .confirmationDialog(
                        "Re-run the failed checks on \(pr.repo)#\(pr.number)?",
                        isPresented: Binding(get: { confirmingRerun == pr.id }, set: { if !$0 { confirmingRerun = nil } })
                    ) {
                        Button("Re-run Failed Checks") { rerun(runIDs, in: pr) }
                    } message: {
                        Text("GitHub re-runs the jobs that failed.")
                    }
                    if let rerunError, rerunError.prID == pr.id {
                        Text(rerunError.message).font(.caption).foregroundStyle(.red)
                    }
                }
            }

            if !pr.feedback.isEmpty, pr.state == "OPEN" {
                ForEach(pr.feedback) { item in
                    feedbackRow(item, on: pr, sent: sent.contains(item.key))
                }
                let picked = pr.feedback.filter { !unticked.contains($0.id) && !sent.contains($0.key) }
                HStack {
                    Spacer()
                    Button(picked.count == 1 ? "Send 1 to Claude" : "Send \(picked.count) to Claude") {
                        if sessions.submit(SessionPrompts.feedback(picked, on: pr, in: session), to: session.id) {
                            sessions.markSent(picked.map(\.key), for: session.id)
                        }
                    }
                    .disabled(!running || picked.isEmpty)
                    .help(running ? "Paste the ticked feedback into claude's prompt, to address and push" : "Start the session first")
                }
            }
        } header: {
            Text("\(pr.repo)#\(pr.number)")
        }
    }

    private func checkRow(_ check: SessionPullRequest.Check, color: Color, symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(color)
            if let url = check.url {
                Link(check.name, destination: url).lineLimit(1)
            } else {
                Text(check.name).lineLimit(1)
            }
        }
        .font(.callout)
    }

    private func feedbackRow(_ item: SessionPullRequest.Feedback, on pr: SessionPullRequest, sent: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Toggle("", isOn: Binding(
                get: { !sent && !unticked.contains(item.id) },
                set: { on in if on { unticked.remove(item.id) } else { unticked.insert(item.id) } }
            ))
            .labelsHidden()
            .checkboxToggle()
            .disabled(sent)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("@\(item.author)").fontWeight(.medium)
                    if let location = item.location {
                        Text(location).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }
                    if let verdict = item.verdict {
                        Text(verdict).font(.caption).foregroundStyle(.orange)
                    }
                    if sent {
                        Text("Sent").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(item.comments.map(\.body).joined(separator: "\n\n"))
                    .font(.callout)
                    .foregroundStyle(sent ? .secondary : .primary)
                    .lineLimit(5)
            }
            Spacer(minLength: 4)
            SaveAsLearningButton(org: session.org, draft: learningDraft(item, on: pr), iconOnly: true)
                .buttonStyle(.borderless)
        }
    }

    /// A thread's words as a learning, scoped to its line: what was said
    /// after the first comment is usually the why.
    private func learningDraft(_ item: SessionPullRequest.Feedback, on pr: SessionPullRequest) -> HarnessLearningDraft {
        let location = item.location?.split(separator: ":", maxSplits: 1).map(String.init) ?? []
        let quote = item.comments.map { "@\($0.author): \($0.body)" }.joined(separator: "\n\n")
        var draft = HarnessLearningDraft.from(
            comment: quote, author: item.comments.last?.author ?? item.author, url: item.comments.last?.url ?? pr.url, repo: pr.repo,
            path: location.first, line: location.count > 1 ? Int(location[1]) : nil
        )
        draft.issues = ["\(pr.repo)#\(pr.number)"]
        return draft
    }

    private func rerun(_ runIDs: Set<Int>, in pr: SessionPullRequest) {
        guard let api = auth.api else { return }
        rerunError = nil
        rerunningPR = pr.id
        Task {
            do {
                for runID in runIDs {
                    try await api.rerunWorkflow(repo: pr.repo, runID: runID, failedOnly: true)
                }
            } catch {
                rerunError = (pr.id, "GitHub didn't take it: \(error.localizedDescription)")
            }
            rerunningPR = nil
        }
    }

    private func reviewLabel(_ pr: SessionPullRequest) -> String? {
        switch pr.reviewDecision {
        case "APPROVED": "Approved"
        case "CHANGES_REQUESTED": "Changes requested"
        case "REVIEW_REQUIRED": pr.state == "OPEN" ? "Review required" : nil
        default: nil
        }
    }

    private func summary(_ checks: [SessionPullRequest.Check]) -> String {
        let failed = checks.filter { $0.state == .failed }.count
        let pending = checks.filter { $0.state == .pending }.count
        let passed = checks.filter { $0.state == .passed }.count
        var parts: [String] = []
        if failed > 0 { parts.append("\(failed) failed") }
        if pending > 0 { parts.append("\(pending) running") }
        if passed > 0 { parts.append("\(passed) passed") }
        return parts.isEmpty ? "None ran" : parts.joined(separator: ", ")
    }
}

/// A small dot before the text, in the label's colour.
private struct DotLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 7))
            configuration.title.foregroundStyle(.primary)
        }
    }
}

// MARK: - GitHub

extension GitHubAPI {
    /// The org's PRs from the branch, and those at the URLs given, each
    /// once: newest first, with the URLs of those the branch search found.
    /// GitHub charges for what's asked, not what comes back, so the search
    /// asks for five PRs and 50 threads each, which a session's branch
    /// never needs more of.
    func sessionPullRequests(org: String, branch: String, urls: [URL]) async throws -> (pullRequests: [SessionPullRequest], searched: Set<URL>) {
        let known = urls.prefix(10).enumerated().map { ("u\($0.offset)", $0.element) }
        let definitions = (["$q: String!"] + known.map { "$\($0.0): URI!" }).joined(separator: ", ")
        let lookups = known.map { "\($0.0): resource(url: $\($0.0)) { ...SessionPR }" }.joined(separator: "\n")
        let query = """
            query(\(definitions)) {
              search(type: ISSUE, query: $q, first: 5) { nodes { ...SessionPR } }
              \(lookups)
            }
            fragment SessionPR on PullRequest {
              id number title url state isDraft reviewDecision mergeable
              author { login }
              repository { nameWithOwner }
              commits(last: 1) { nodes { commit { statusCheckRollup { contexts(first: 80) { nodes {
                __typename
                ... on CheckRun { name status conclusion detailsUrl checkSuite { workflowRun { databaseId } } }
                ... on StatusContext { context state targetUrl }
              } } } } } }
              reviews(last: 30) { nodes { id author { login } state body url } }
              reviewThreads(first: 50) { nodes { id isResolved isOutdated path line originalLine
                comments(last: 20) { nodes { author { login } body url } } } }
            }
            """
        var values: [String: Any] = ["q": "\(GitHubAccounts.scope(org)) is:pr head:\(branch)"]
        for (name, url) in known { values[name] = url.absoluteString }
        let response: SessionPRResponse = try await self.query(query, values: values)
        var seen: Set<String> = []
        let pullRequests = response.pullRequests
            .compactMap { $0.model }
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.number > $1.number }
        return (pullRequests, Set(response.searched.compactMap { $0.model?.url }))
    }
}

/// The search's nodes and each looked-up URL, keyed `u0`, `u1` and so on.
private struct SessionPRResponse: Decodable {
    let pullRequests: [RawPullRequest]
    /// The search's alone.
    let searched: [RawPullRequest]

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    private struct Search: Decodable { let nodes: [RawPullRequest] }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        var found: [RawPullRequest] = []
        var searched: [RawPullRequest] = []
        for key in container.allKeys {
            if key.stringValue == "search" {
                searched = (try? container.decode(Search.self, forKey: key).nodes) ?? []
                found += searched
            } else if key.stringValue.hasPrefix("u"), let pr = try? container.decode(RawPullRequest.self, forKey: key) {
                found.append(pr)
            }
        }
        pullRequests = found
        self.searched = searched
    }
}

/// Every field optional: a search node or URL that isn't a PR comes back
/// as an empty object.
private struct RawPullRequest: Decodable {
    struct Login: Decodable { let login: String }
    struct Repository: Decodable { let nameWithOwner: String }
    struct Context: Decodable {
        struct Suite: Decodable {
            struct Run: Decodable { let databaseId: Int? }
            let workflowRun: Run?
        }
        let __typename: String
        let name: String?
        let status: String?
        let conclusion: String?
        let detailsUrl: String?
        let checkSuite: Suite?
        let context: String?
        let state: String?
        let targetUrl: String?
    }
    struct Rollup: Decodable { let contexts: Connection<Context> }
    struct Commit: Decodable { let statusCheckRollup: Rollup? }
    struct CommitNode: Decodable { let commit: Commit }
    struct Review: Decodable {
        let id: String
        let author: Login?
        let state: String
        let body: String
        let url: URL
    }
    struct Comment: Decodable {
        let author: Login?
        let body: String
        let url: URL
    }
    struct Thread: Decodable {
        let id: String
        let isResolved: Bool
        let isOutdated: Bool
        let path: String
        let line: Int?
        let originalLine: Int?
        let comments: Connection<Comment>
    }

    let id: String?
    let number: Int?
    let title: String?
    let url: URL?
    let state: String?
    let isDraft: Bool?
    let reviewDecision: String?
    let mergeable: String?
    let author: Login?
    let repository: Repository?
    let commits: Connection<CommitNode>?
    let reviews: Connection<Review>?
    let reviewThreads: Connection<Thread>?

    var model: SessionPullRequest? {
        guard let id, let number, let title, let url, let state, let repository else { return nil }
        let contexts = commits?.nodes.last?.commit.statusCheckRollup?.contexts.nodes ?? []
        let checks = contexts.map { context -> SessionPullRequest.Check in
            if context.__typename == "StatusContext" {
                let state: SessionPullRequest.Check.State = switch context.state {
                case "SUCCESS": .passed
                case "FAILURE", "ERROR": .failed
                default: .pending
                }
                return .init(name: context.context ?? "Status", state: state, url: context.targetUrl.flatMap(URL.init(string:)), runID: nil)
            }
            let state: SessionPullRequest.Check.State = if context.status != "COMPLETED" {
                .pending
            } else {
                switch context.conclusion {
                case "SUCCESS", "NEUTRAL": .passed
                case "SKIPPED", "CANCELLED", "STALE": .skipped
                default: .failed
                }
            }
            return .init(name: context.name ?? "Check", state: state, url: context.detailsUrl.flatMap(URL.init(string:)), runID: context.checkSuite?.workflowRun?.databaseId)
        }
        let prAuthor = author?.login
        // Open threads on lines that still exist, then what reviewers said
        // in a review of its own (not the author's, nor an empty approval).
        var feedback: [SessionPullRequest.Feedback] = (reviewThreads?.nodes ?? [])
            .filter { !$0.isResolved && !$0.isOutdated && !$0.comments.nodes.isEmpty }
            .map { thread in
                let comments = thread.comments.nodes.map { SessionPullRequest.Comment(author: $0.author?.login ?? "someone", body: $0.body, url: $0.url) }
                let line = thread.line ?? thread.originalLine
                return .init(id: thread.id, author: comments[0].author, location: line.map { "\(thread.path):\($0)" } ?? thread.path, verdict: nil, comments: comments)
            }
        for review in reviews?.nodes ?? [] where review.author?.login != prAuthor
            && !review.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && ["CHANGES_REQUESTED", "COMMENTED"].contains(review.state) {
            let who = review.author?.login ?? "someone"
            feedback.append(.init(
                id: review.id, author: who, location: nil,
                verdict: review.state == "CHANGES_REQUESTED" ? "changes requested" : nil,
                comments: [.init(author: who, body: review.body, url: review.url)]
            ))
        }
        return SessionPullRequest(
            id: id, number: number, title: title, url: url, repo: repository.nameWithOwner, author: prAuthor, state: state,
            isDraft: isDraft ?? false, reviewDecision: reviewDecision, mergeable: mergeable,
            checks: checks.sorted { order($0.state) < order($1.state) }, feedback: feedback
        )
    }

    private func order(_ state: SessionPullRequest.Check.State) -> Int {
        switch state {
        case .failed: 0
        case .pending: 1
        case .passed: 2
        case .skipped: 3
        }
    }
}
