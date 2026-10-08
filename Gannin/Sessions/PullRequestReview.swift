import SwiftUI

// MARK: - The review's state

/// What you've made of a review: each finding kept as claude wrote it,
/// edited, or dismissed, and comments of your own.
struct ReviewDraft: Hashable, Codable {
    enum Decision: Hashable, Codable {
        case dismissed, edited(String)
    }

    struct Comment: Identifiable, Hashable, Codable {
        var id = UUID()
        let path: String
        let line: Int
        /// On a removed line, numbered as the file was.
        let isOld: Bool
        var body: String
    }

    var decisions: [String: Decision] = [:]
    var comments: [Comment] = []
    /// The review posted to GitHub, once it has been, when, and which
    /// kind: `APPROVE`, `REQUEST_CHANGES` or `COMMENT`.
    var posted: URL?
    var postedAt: Date?
    var postedEvent: String?

    /// What was posted, as a list shows it: nil before it's posted.
    var postedLabel: (text: String, symbol: String, color: Color)? {
        guard posted != nil else { return nil }
        switch postedEvent {
        case "APPROVE": return ("Approved", "checkmark.circle.fill", ChartPalette.good)
        case "REQUEST_CHANGES": return ("Changes requested", "arrow.uturn.backward.circle.fill", .orange)
        case "COMMENT": return ("Commented", "text.bubble.fill", ChartPalette.blue)
        default: return ("Posted", "checkmark.circle.fill", ChartPalette.good)
        }
    }
}

extension SessionTranscript.Finding {
    /// Stable within one review: where it is and what it says.
    var key: String { "\(path):\(line ?? 0):\(comment.prefix(60))" }

    var severityRank: Int {
        switch severity?.lowercased() {
        case "blocker": 0
        case "major": 1
        case "minor": 2
        case "nit": 3
        default: 2
        }
    }

    var severityColor: Color {
        switch severity?.lowercased() {
        case "blocker": ChartPalette.critical
        case "major": .orange
        case "minor": .yellow
        default: .secondary
        }
    }
}

// MARK: - Starting one

extension SessionStore {
    /// A review agent on the PR, in the org's harness: it can't edit, can
    /// check the PR out to read or run it, and ends with its findings as
    /// JSON for the review tab.
    /// `choice` is what was picked from the team's prompts and skills; nil
    /// takes the defaults for the PR's repo.
    /// `reveals` false starts it without showing its tab (an automatic review).
    func startReview(of pr: PullRequestReference, harness setup: HarnessConfig, harnessPath: String, choice: PromptChoice? = nil, reveals: Bool = true) async -> CodeSession {
        if let existing = review(of: pr.id) {
            if reveals { reveal(existing.id) }
            return existing
        }
        // The files fetch below takes a moment, during which another call
        // for the same PR (a second click, or the notification racing
        // `startAutomaticReview`) would also find no existing review and
        // make a second one. Callers for the same PR share one in-flight
        // task instead.
        if let inFlight = startingReviews[pr.id] {
            let session = await inFlight.value
            if reveals { reveal(session.id) }
            return session
        }
        let task = Task<CodeSession, Never> {
            let branch = Self.reviewBranch(pr)
            let values = HarnessPromptLibrary.values(reference: "\(pr.repo)#\(pr.number)", title: pr.title, url: pr.url, repo: pr.repo, number: pr.number, branch: branch)
            let instructions = launchInstructions(org: pr.org, setup: setup, use: .review, repos: [pr.repo], choice: choice, values: values)
            let learnings = await reviewLearnings(org: pr.org, harnessRepo: setup.repo, repo: pr.repo, number: pr.number)
            let config = await reviewConfig(org: pr.org, harness: setup, repo: pr.repo).resolved
            var session = CodeSession(
                id: UUID(), issue: IssueReference(org: pr.org, id: pr.id, number: pr.number, title: pr.title, repo: pr.repo, url: pr.url),
                repo: setup.repo, branch: branch, createdAt: .now, pullRequests: [pr.url],
                connect: Self.connectCommand, harnessRepo: setup.repo, harnessPath: harnessPath,
                role: "Review", prompt: Self.pullRequestReviewPrompt(pr, branch: branch, learnings: learnings, config: config),
                instructions: instructions.map(Self.reviewInstructions), isReviewer: true, reviewOf: pr
            )
            session.reviewConfig = config.isEmpty ? nil : config
            let directory = Self.directory(for: session.id)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let brief = "# Review of \(pr.repo)#\(pr.number): \(pr.title)\n\n\(pr.url.absoluteString)\n"
            try? Data(brief.utf8).write(to: directory.appending(path: "brief.md"))
            add(session)
            return session
        }
        startingReviews[pr.id] = task
        let session = await task.value
        startingReviews[pr.id] = nil
        if reveals { reveal(session.id) }
        return session
    }

    /// The harness's learnings covering the PR's current files: fetched
    /// afresh each time, since what covers the PR when the review starts
    /// may fall short once its diff grows, and `Review Again` and the
    /// watched look-again prompt (`AutoReview.reviewAgain`) need the same
    /// list as the first prompt.
    func reviewLearnings(org: String, harnessRepo: String?, repo: String, number: Int) async -> [HarnessLearning] {
        var learnings = harnessStore.anyIndex(org: org, repo: harnessRepo ?? repo)?.learnings(for: repo) ?? []
        if let files = try? await chargingTo(.details, { try await api()?.pullRequestFilePaths(repo: repo, number: number) }) {
            learnings = learnings.filter { learning in files.contains { learning.covers($0) } }
        }
        return learnings
    }

    static func reviewBranch(_ pr: PullRequestReference) -> String {
        "review-\(pr.repo.split(separator: "/").last ?? "")-\(pr.number)"
    }

    /// The team's instructions for a review, which mustn't change how it
    /// ends: Gannin reads the JSON.
    static func reviewInstructions(_ instructions: String) -> String {
        "\(instructions)\n\nWhatever these ask, still end your reply with the fenced ```json block as set out above."
    }

    /// `learnings` are the harness's for the PR's repo, which the reviewer
    /// follows where they cover the diff.
    static func pullRequestReviewPrompt(_ pr: PullRequestReference, branch: String, learnings: [HarnessLearning] = [], config: ReviewConfig = ReviewConfig()) -> String {
        let name = pr.repo.split(separator: "/").last.map(String.init) ?? pr.repo
        let owner = pr.repo.split(separator: "/").first.map(String.init) ?? pr.repo
        let threads = "gh api graphql -f query='{ viewer { login } repository(owner: \"\(owner)\", name: \"\(name)\") { pullRequest(number: \(pr.number)) { reviewThreads(first: 100) { nodes { id isResolved path line comments(first: 20) { nodes { author { login } body } } } } } } }'"
        let learned = HarnessLearning.reviewInstructions(learnings).map { "\n\n\($0)" } ?? ""
        let configured = config.reviewInstructions.map { "\n\n\($0)" } ?? ""
        let checksField = config.activeChecks.isEmpty ? "" : #""checks": [{"name": "<a check you were given>", "result": "pass" | "fail" | "inconclusive", "reason": "<why>"}], "#
        return """
            Review pull request \(pr.repo)#\(pr.number), "\(pr.title)" (\(pr.url.absoluteString)). This is a review: don't edit any files.

            Read it with `gh pr view \(pr.number) --repo \(pr.repo) --comments` and `gh pr diff \(pr.number) --repo \(pr.repo)`. For more than the diff, the repo's shared clone is `projects/\(name)` (if it isn't there, `gh repo clone \(pr.repo) projects/\(name)`); check the PR out to read around it or run its tests with `git -C projects/\(name) fetch origin pull/\(pr.number)/head && git -C projects/\(name) worktree add --detach "$PWD/.worktrees/\(branch)/\(name)" FETCH_HEAD`. If the harness has no `projects/` folder and is \(pr.repo) itself, use `git -C .` in place of `git -C projects/\(name)` and don't clone it. Read the repo's CLAUDE.md, and the harness's STANDARDS.md, for how the team works.

            Look for bugs, missed cases, security problems, and code that doesn't fit the repo or the issue it's for. Comment only on lines the diff changes or shows. Say what's good in the summary, not as findings.\(learned)\(configured)

            End your reply with one fenced ```json block, findings most important first:
            {"headline": "<one line: what this PR does>", "summary": "<a few sentences for the PR's author. When writing lists, use bullet points. Do not duplicate text from your comments.>", "verdict": "approve" | "comment" | "request_changes", "effort": <1 to 5: how much work reviewing it by hand is, 1 a glance, 5 hours>, "walkthrough": [{"title": "<an area of the change>", "summary": "<what changes there and why, a sentence or two>", "files": ["<path in the repo>"]}], "flow": ["<one step of what happens when the changed code runs>"], "findings": [{"path": "<path in the repo>", "line": <line in the new file>, "severity": "blocker" | "major" | "minor" | "nit", "category": \(ReviewCategory.promptList), "comment": "<what's wrong and what to do>", "suggestion": "<optional: the replacement for that one line>"}], "resolved": ["<review thread ID>"], \(checksField)\(HarnessLearning.reviewJSONField)}

            `walkthrough` splits the change into a few areas in the order a reviewer should read them, every changed file in one. `flow` is only for a change with a path through the code worth tracing (a request, a sync, a job): its steps in order, else leave it empty. Each finding's `category`: correctness (it does the wrong thing or misses a case), data (data integrity, migrations, APIs and integrations), stability (errors, crashes, availability), security (security and privacy), performance (speed and scale), maintainability (readability, structure, tests, fit with the repo).

            \(HarnessLearning.reviewJSONInstructions)

            If I ask you to look again, end the same way. Before you do, list the PR's review threads with `\(threads)`. In `resolved`, give the ID of each thread that isn't resolved yet, was started by `viewer` (the account you review as), and whose point is now dealt with: fixed in the code, or answered so that nothing more is needed. Check the code rather than taking a reply's word for it. Leave out threads whose point still stands, and don't raise them again as findings unless something about them has changed. On a first review, `resolved` is empty.
            """
    }
}

// MARK: - The PR from GitHub

/// The PR as the review shows it: its facts and every file's diff.
struct ReviewedPullRequest: Equatable {
    struct File: Identifiable, Equatable {
        let path: String
        let status: String
        let additions: Int
        let deletions: Int
        let lines: [DiffLine]

        var id: String { path }

        /// From the first line the diff shows to the last, as a learning's
        /// lines are matched; nil when it shows none.
        var shownLines: ClosedRange<Int>? {
            let numbers = lines.compactMap { $0.newLine ?? $0.oldLine }
            guard let low = numbers.min(), let high = numbers.max() else { return nil }
            return low...high
        }

        /// Whether a comment can sit on the line: GitHub only takes lines
        /// the diff shows.
        func hasLine(_ line: Int, isOld: Bool) -> Bool {
            lines.contains { isOld ? $0.oldLine == line && $0.kind == .removed : $0.newLine == line }
        }
    }

    /// A review comment already on GitHub, on a diff line: from an earlier
    /// review (anyone's, including an earlier pass of this one).
    struct ExistingComment: Identifiable, Equatable {
        let id: Int
        let path: String
        let line: Int
        let isOld: Bool
        let body: String
        let author: String
        let avatarURL: URL?
        let createdAt: Date
        let url: URL?
    }

    let title: String
    let body: String
    let author: String?
    let headSHA: String
    let additions: Int
    let deletions: Int
    let state: String
    let files: [File]
    var existingComments: [ExistingComment] = []

    /// The inline comments GitHub will take (findings kept or edited on
    /// lines the diff shows, and your own), and the findings it won't.
    func comments(for review: SessionTranscript.ReviewResult?, draft: ReviewDraft) -> ([[String: Any]], [SessionTranscript.Finding]) {
        var inline: [[String: Any]] = []
        var general: [SessionTranscript.Finding] = []
        for finding in review?.findings ?? [] {
            let decision = draft.decisions[finding.key]
            if decision == .dismissed { continue }
            var text = finding.comment
            if case .edited(let edited) = decision { text = edited }
            guard let line = finding.line, let file = files.first(where: { $0.path == finding.path }), file.hasLine(line, isOld: false) else {
                general.append(.init(path: finding.path, line: finding.line, comment: text, severity: finding.severity))
                continue
            }
            if let suggestion = finding.suggestion, decision == nil {
                text += "\n\n```suggestion\n\(suggestion)\n```"
            }
            inline.append(["path": finding.path, "line": line, "side": "RIGHT", "body": text])
        }
        for comment in draft.comments {
            inline.append(["path": comment.path, "line": comment.line, "side": comment.isOld ? "LEFT" : "RIGHT", "body": comment.body])
        }
        return (inline, general)
    }

    /// A review's body: the summary, then findings that can't go on a line.
    static func body(summary: String, general: [SessionTranscript.Finding]) -> String {
        var text = summary
        if !general.isEmpty {
            text += "\n\n" + general.map { finding in
                "- `\(finding.path)\(finding.line.map { ":\($0)" } ?? "")`: \(finding.comment)"
            }.joined(separator: "\n")
        }
        return text
    }
}

extension GitHubAPI {
    /// The paths a PR changes, for scoping what a reviewer's told (such as
    /// which learnings apply) without fetching every file's patch. A
    /// renamed file's old path is included too, so a learning scoped to it
    /// still applies to the PR that moves it.
    func pullRequestFilePaths(repo: String, number: Int) async throws -> [String] {
        struct File: Decodable { let filename: String; let previousFilename: String? }
        var paths: [String] = []
        for page in 1...30 {
            let batch: [File] = try await rest("repos/\(repo)/pulls/\(number)/files", query: ["per_page": "100", "page": "\(page)"])
            paths += batch.flatMap { [$0.filename, $0.previousFilename].compactMap { $0 } }
            if batch.count < 100 { break }
        }
        return paths
    }

    func reviewedPullRequest(repo: String, number: Int) async throws -> ReviewedPullRequest {
        struct Pull: Decodable {
            struct User: Decodable { let login: String }
            struct Ref: Decodable { let sha: String }
            let title: String
            let body: String?
            let user: User?
            let head: Ref
            let additions: Int
            let deletions: Int
            let state: String
            let merged: Bool?
        }
        struct File: Decodable {
            let filename: String
            let status: String
            let additions: Int
            let deletions: Int
            let patch: String?
        }
        let pull: Pull = try await rest("repos/\(repo)/pulls/\(number)")
        var files: [ReviewedPullRequest.File] = []
        for page in 1...30 {
            let batch: [File] = try await rest("repos/\(repo)/pulls/\(number)/files", query: ["per_page": "100", "page": "\(page)"])
            files += batch.map { file in
                .init(path: file.filename, status: file.status, additions: file.additions, deletions: file.deletions, lines: GitDiff.lines(of: file.patch ?? "").0)
            }
            if batch.count < 100 { break }
        }
        return ReviewedPullRequest(
            title: pull.title, body: pull.body ?? "", author: pull.user?.login, headSHA: pull.head.sha,
            additions: pull.additions, deletions: pull.deletions,
            state: pull.merged == true ? "merged" : pull.state, files: files,
            existingComments: try await existingComments(repo: repo, number: number)
        )
    }

    /// Review comments already on GitHub, on the lines they're anchored to.
    /// One left on a line a later push made outdated keeps its original
    /// line and side, since GitHub drops `line`/`side` once that happens.
    private func existingComments(repo: String, number: Int) async throws -> [ReviewedPullRequest.ExistingComment] {
        struct Comment: Decodable {
            struct User: Decodable { let login: String; let avatarUrl: URL? }
            let id: Int
            let path: String
            let line: Int?
            let originalLine: Int?
            let side: String?
            let originalSide: String?
            let body: String
            let user: User?
            let createdAt: Date
            let htmlUrl: URL?
        }
        var comments: [ReviewedPullRequest.ExistingComment] = []
        for page in 1...30 {
            let batch: [Comment] = try await rest("repos/\(repo)/pulls/\(number)/comments", query: ["per_page": "100", "page": "\(page)"])
            comments += batch.compactMap { comment in
                guard let line = comment.line ?? comment.originalLine else { return nil }
                return .init(
                    id: comment.id, path: comment.path, line: line, isOld: (comment.side ?? comment.originalSide) == "LEFT",
                    body: comment.body, author: comment.user?.login ?? "ghost", avatarURL: comment.user?.avatarUrl,
                    createdAt: comment.createdAt, url: comment.htmlUrl
                )
            }
            if batch.count < 100 { break }
        }
        return comments
    }

    /// Posts a review with inline comments. A write: not retried.
    /// (Comments are built by `ReviewedPullRequest.comments(for:draft:)`.)
    func postReview(repo: String, number: Int, commit: String, event: String, body: String, comments: [[String: Any]]) async throws -> URL? {
        struct Posted: Decodable { let htmlUrl: URL? }
        let posted: Posted = try await restWrite("POST", "repos/\(repo)/pulls/\(number)/reviews", body: [
            "commit_id": commit, "event": event, "body": body, "comments": comments,
        ])
        return posted.htmlUrl
    }

    /// The threads a review says are dealt with that Gannin will resolve:
    /// review threads on this PR, not resolved yet, started by you. Any
    /// other ID (someone else's thread, another PR's) is left alone.
    func resolvableThreads(_ ids: [String], pullRequest: String) async throws -> [ReviewThread] {
        guard !ids.isEmpty else { return [] }
        struct Author: Decodable { let login: String }
        struct Comment: Decodable { let author: Author?; let body: String; let url: URL? }
        struct Node: Decodable {
            struct PullRequest: Decodable { let id: String }
            let id: String?
            let isResolved: Bool?
            let path: String?
            let line: Int?
            let pullRequest: PullRequest?
            let comments: Connection<Comment>?
        }
        struct Viewer: Decodable { let login: String }
        struct Response: Decodable { let viewer: Viewer; let nodes: [Node?] }
        let response: Response = try await query("""
            query($ids: [ID!]!) {
              viewer { login }
              nodes(ids: $ids) {
                ... on PullRequestReviewThread {
                  id isResolved path line
                  pullRequest { id }
                  comments(first: 1) { nodes { author { login } body url } }
                }
              }
            }
            """, values: ["ids": Array(Set(ids))])
        let me = response.viewer.login
        return response.nodes.compactMap { node in
            guard let node, let id = node.id, node.isResolved == false, node.pullRequest?.id == pullRequest,
                  let first = node.comments?.nodes.first,
                  first.author?.login.caseInsensitiveCompare(me) == .orderedSame else { return nil }
            return ReviewThread(id: id, path: node.path ?? "", line: node.line, body: first.body, url: first.url)
        }
    }

    /// Marks a review thread resolved. A write: not retried.
    func resolveReviewThread(_ id: String) async throws {
        struct Response: Decodable {}
        let _: Response = try await mutate("""
            mutation($thread: ID!) {
              resolveReviewThread(input: { threadId: $thread }) { thread { id } }
            }
            """, variables: ["thread": id])
    }
}

/// A review thread of yours that a review says is dealt with.
struct ReviewThread: Identifiable, Hashable {
    let id: String
    let path: String
    let line: Int?
    /// The thread's first comment, what was asked.
    let body: String
    let url: URL?
}

// MARK: - Starting from a PR

/// Review with Claude on a PR: starts (or opens) its review in the
/// sessions window. Reviews run in the org's harness, as sessions do.
struct ReviewWithClaudeButton: View {
    @Environment(SessionStore.self) private var sessions
    @Environment(OrgConfigStore.self) private var configs
    @Environment(HarnessStore.self) private var harness
    @Environment(\.openWindow) private var openWindow
    let reference: PullRequestReference
    /// While the team's prompts and skills are picked.
    @State private var choosing = false

    var body: some View {
        if let existing = sessions.review(of: reference.id) {
            Button {
                sessions.show(existing.id, with: openWindow)
            } label: {
                Label("Open Review", systemImage: "eye")
            }
            .help("Show Claude's review of this PR")
        } else {
            let blocked = unavailable
            let config = configs.config(for: reference.org)
            let setup = config.harness(covering: [reference.repo])
            Button {
                if let setup, SessionLaunchSheet<EmptyView>.hasChoices(sessions.promptLibrary(org: reference.org, setup: setup), use: .review, harnesses: config.harnesses) {
                    choosing = true
                } else {
                    start(choice: nil, setup: setup)
                }
            } label: {
                Label("Review with Claude", systemImage: "eye")
            }
            .disabled(blocked != nil)
            .help(blocked ?? "Have Claude review this PR, then go through its findings and post the review to GitHub")
            .sheet(isPresented: $choosing) {
                if let setup {
                    SessionLaunchSheet(
                        title: "Review \(reference.repo)#\(reference.number)", org: reference.org, harnesses: config.harnesses, initial: setup,
                        use: .review, repos: [reference.repo],
                        values: HarnessPromptLibrary.values(reference: "\(reference.repo)#\(reference.number)", title: reference.title, url: reference.url, repo: reference.repo, number: reference.number, branch: SessionStore.reviewBranch(reference)),
                        startTitle: "Start Review"
                    ) { choice, picked in
                        start(choice: choice, setup: picked)
                    }
                }
            }
        }
    }

    private func start(choice: PromptChoice?, setup: HarnessConfig?) {
        guard let setup, let path = SessionStore.harnessPath(org: reference.org, repo: setup.repo) else { return }
        Task {
            let session = await sessions.startReview(of: reference, harness: setup, harnessPath: path, choice: choice)
            sessions.show(session.id, with: openWindow)
        }
    }

    private var unavailable: String? {
        let config = configs.config(for: reference.org)
        guard config.harnesses.count < 2 else { return nil }
        return SessionStore.unavailable(org: reference.org, harness: config.harness(covering: [reference.repo]), what: "Reviews")
    }
}

// MARK: - Explain with Claude

/// Explain in a PR's right-click menu, toolbar or drawer: a one-off
/// question, not a session, so it's available wherever a PR is shown.
struct ExplainPullRequestButton: View {
    let reference: PullRequestReference
    @State private var explaining = false

    var body: some View {
        Button {
            explaining = true
        } label: {
            Label("Explain", systemImage: "text.bubble")
        }
        .help("Have Claude explain what this PR changes and why, in plain terms")
        .sheet(isPresented: $explaining) {
            ExplainPullRequestSheet(reference: reference)
        }
    }
}

/// Claude's explanation of a PR, asked fresh each time the sheet opens
/// (`ClaudeRunner.ask`, not a session): what it reads with `gh`, and what
/// it's told to reply with.
private struct ExplainPullRequestSheet: View {
    @Environment(\.dismiss) private var dismiss
    let reference: PullRequestReference

    @State private var text = ""
    @State private var working = false
    @State private var status: String?

    var body: some View {
        VStack(spacing: 0) {
            Text("Explain \(reference.repo)#\(reference.number)").font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            Divider()
            ScrollView {
                Group {
                    if text.isEmpty {
                        HStack(spacing: 8) {
                            if working { ProgressView().controlSize(.small) }
                            Text(working ? "Claude is reading it." : "Nothing yet.").foregroundStyle(.secondary)
                        }
                    } else {
                        Text(text)
                            .font(.body)
                            .lineSpacing(4)
                            .textSelection(.enabled)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                if let status { Text(status).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
                if working && !text.isEmpty { ProgressView().controlSize(.small) }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(text.isEmpty ? "Explain" : "Explain Again") { explain() }
                    .disabled(working)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    status = "Copied"
                }
                .disabled(text.isEmpty)
            }
            .padding(12)
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 420, idealHeight: 480)
        .onAppear { if text.isEmpty { explain() } }
    }

    private func explain() {
        working = true
        status = nil
        let prompt = """
            Explain pull request \(reference.repo)#\(reference.number), "\(reference.title)" (\(reference.url.absoluteString)), for someone who hasn't read it: explain the code, not just the PR description.

            Read the actual changes with `gh pr diff \(reference.number) --repo \(reference.repo)` first, then `gh pr view \(reference.number) --repo \(reference.repo) --comments` for the stated intent and discussion. Base the explanation on what the diff does, not a reworded version of the title or description.

            Reply with the explanation only, no preamble: a short paragraph on what the code does and why, then a few bullet points on the notable changes if there are several, naming the functions, types or files involved. Don't review it or suggest changes.
            """
        Task {
            do {
                text = try await ClaudeRunner.ask(prompt, org: reference.org, tools: ["Bash"])
            } catch {
                status = error.localizedDescription
            }
            working = false
        }
    }
}

// MARK: - The review tab

/// A review's tab: the PR's files and diff with claude's findings and any
/// existing review comments on their lines, its summary and verdict, and
/// beneath, the conversation for asking it more. The file list's first row
/// is the PR's own conversation comments. Findings are kept, edited or
/// dismissed, comments of your own added on any line, and Post Review sends
/// what's kept to GitHub as one review.
struct PullRequestReviewView: View {
    @Environment(SessionStore.self) private var sessions
    @Environment(AuthStore.self) private var auth
    @Environment(HarnessStore.self) private var harness
    @Environment(DetailStore.self) private var details
    let session: CodeSession
    @State private var pullRequest: ReviewedPullRequest?
    @State private var error: String?
    @State private var selectedFile: String?
    /// Nil until toggled: shown while claude runs or hasn't reviewed yet,
    /// so a review read from the history doesn't start claude.
    @State private var conversation: Bool?
    @State private var confirmingFinish = false
    @State private var posting = false
    /// While Review Again's files fetch is in flight: the button stays
    /// enabled until claude's state turns to working, so a second click in
    /// that gap would paste the prompt twice.
    @State private var reviewingAgain = false
    /// The PR's state on GitHub (conflicts, checks, review decision, open
    /// threads), for whether it can merge.
    @State private var status: SessionPullRequest?
    /// Findings shown: those of one category or severity, or all.
    @State private var filter: FindingFilter?

    private var reference: PullRequestReference { session.reviewOf! }

    /// Findings narrowed to one category or severity.
    enum FindingFilter: Hashable {
        case category(ReviewCategory)
        case severity(ReviewSeverity)

        var title: String {
            switch self {
            case .category(let category): category.shortTitle
            case .severity(let severity): severity.title
            }
        }

        func admits(_ finding: SessionTranscript.Finding) -> Bool {
            switch self {
            case .category(let category): ReviewCategory(finding.category) == category
            case .severity(let severity): (ReviewSeverity(finding.severity) ?? .minor) == severity
            }
        }
    }

    private func visible(_ findings: [SessionTranscript.Finding]) -> [SessionTranscript.Finding] {
        guard let filter else { return findings }
        return findings.filter(filter.admits)
    }

    private static let overviewTag = "\u{0}overview"

    private func readiness(_ review: SessionTranscript.ReviewResult?) -> ReviewReadiness {
        let state = sessions.state(session.id)
        return ReviewReadiness(
            status: status, pullRequest: pullRequest, review: review,
            draft: sessions.reviewDrafts[session.id] ?? ReviewDraft(),
            isReviewing: sessions.isRunning(session.id) && (state == .working || state == .starting),
            config: session.reviewConfig,
            isStale: sessions.sessions[session.id]?.watch?.hasNewCommits == true
        )
    }

    var body: some View {
        let transcript = sessions.transcripts[session.id]
        let review = transcript?.review ?? session.reviewResult
        let showsConversation = conversation ?? (session.archivedAt == nil && (sessions.isRunning(session.id) || session.reviewResult == nil))
        VStack(spacing: 0) {
            header(review: review, transcript: transcript)
            Divider()
            VSplitView {
                HSplitView {
                    fileList(review: review)
                        .frame(minWidth: 220, idealWidth: 280, maxWidth: 420)
                    diffColumn(review: review)
                        .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(minHeight: 260, maxHeight: .infinity)
                if showsConversation {
                    VStack(spacing: 0) {
                        TerminalHost(session: session)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        Divider()
                        SessionComposer(session: session)
                    }
                    .frame(minHeight: 160, idealHeight: 240)
                }
            }
        }
        .task(id: session.id) { await load() }
        .task(id: review?.summary) { await loadStatus() }
        .task(id: reference.id) { await details.load(reference.id) }
        .confirmationDialog("Finish this review?", isPresented: $confirmingFinish) {
            Button("Finish Review") { Task { await sessions.archiveReview(session.id) } }
        } message: {
            Text("The reviewer is ended and its checkout removed. The review, your decisions and comments stay in Agents › Reviews, to read again or resume.")
        }
        .sheet(isPresented: $posting) {
            if let pullRequest {
                PostReviewSheet(session: session, pullRequest: pullRequest, review: review)
            }
        }
    }

    private func load() async {
        guard let api = auth.api else { return }
        do {
            let fetched = try await api.reviewedPullRequest(repo: reference.repo, number: reference.number)
            pullRequest = fetched
            error = nil
            if selectedFile == nil { selectedFile = Self.overviewTag }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadStatus() async {
        guard let api = auth.api else { return }
        let found = try? await chargingTo(.sessionPullRequests) {
            try await api.sessionPullRequests(org: reference.org, branch: SessionStore.reviewBranch(reference), urls: [reference.url])
        }
        if let found { status = found.pullRequests.first { $0.id == reference.id } }
    }

    /// Opens what an Overview item points at.
    private func open(_ action: ReviewReadiness.Action) {
        switch action {
        case .file(let path): selectedFile = path
        case .general: selectedFile = "\u{0}general"
        case .url(let url): NSWorkspace.shared.open(url)
        }
    }

    // MARK: Header

    private func header(review: SessionTranscript.ReviewResult?, transcript: SessionTranscript?) -> some View {
        let state = sessions.state(session.id)
        let draft = sessions.reviewDrafts[session.id] ?? ReviewDraft()
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Link(destination: reference.url) {
                        Text(reference.title)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    .help("Open the pull request on GitHub")
                    HStack(spacing: 8) {
                        Link(destination: reference.url) {
                            Label(reference.repo + "#" + String(reference.number), systemImage: "arrow.up.right.square")
                        }
                        .help("Open the pull request on GitHub")
                        if let pullRequest {
                            if let author = pullRequest.author { Text("by \(author)") }
                            Text("+\(pullRequest.additions)").foregroundStyle(ChartPalette.good)
                            Text("-\(pullRequest.deletions)").foregroundStyle(ChartPalette.critical)
                            Text("\(pullRequest.files.count) files")
                            if pullRequest.state != "open" { Text(pullRequest.state.capitalized).foregroundStyle(.purple) }
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                status(state: state, transcript: transcript, hasReview: review != nil)
                let showsConversation = conversation ?? (session.archivedAt == nil && (sessions.isRunning(session.id) || session.reviewResult == nil))
                if session.archivedAt == nil {
                    Button {
                        conversation = !showsConversation
                    } label: {
                        Label("Conversation", systemImage: showsConversation ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right")
                    }
                    .help(showsConversation ? "Hide the conversation with the reviewer" : "Ask the reviewer more (resumes claude)")
                }
                Link(destination: reference.url) {
                    Label("Open on GitHub", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.bordered)
                Button("Review Again") {
                    reviewingAgain = true
                    Task {
                        defer { reviewingAgain = false }
                        // The diff may cover more of the repo than it did
                        // when the review started, so the learnings fixed
                        // into its first prompt may now fall short.
                        let learnings = await sessions.reviewLearnings(org: reference.org, harnessRepo: session.harnessRepo, repo: reference.repo, number: reference.number)
                        let learned = HarnessLearning.reviewInstructions(learnings).map { "\n\n\($0)" } ?? ""
                        sessions.submit("The PR may have changed. Fetch it again, review it afresh, and end the same way with the JSON block, listing in `resolved` the threads now dealt with.\(learned)", to: session.id)
                        // It's looking at what changed, so the watch needn't.
                        sessions.update(session.id) { session in
                            session.watch?.hasNewCommits = false
                            session.watch?.newComments = 0
                            session.watch?.changedAt = nil
                        }
                        await load()
                    }
                }
                .disabled(!sessions.isRunning(session.id) || state == .working || reviewingAgain)
                .help("Ask claude to review the PR again, as it is now")
                if let posted = draft.posted {
                    Link(destination: posted) {
                        let label = draft.postedLabel ?? ("Posted", "checkmark.circle.fill", ChartPalette.good)
                        Label(draft.postedAt.map { "\(label.text) \($0.formatted(.relative(presentation: .named)))" } ?? label.text, systemImage: label.symbol)
                            .foregroundStyle(label.color)
                    }
                    .help("Open the review on GitHub")
                }
                if review != nil {
                    Toggle("Watch for changes", isOn: Binding(
                        get: { sessions.sessions[session.id]?.watch?.isOn ?? false },
                        set: { sessions.setWatching(session.id, $0) }
                    ))
                    .checkboxToggle()
                    .help("Review it again by itself when new commits are pushed or someone comments, until it's merged or closed")
                }
                if session.archivedAt != nil {
                    Button("Resume") {
                        sessions.resumeReview(session.id)
                        conversation = true
                    }
                    .help("Take it out of the history and pick the conversation back up")
                } else {
                    Button("Finish") { confirmingFinish = true }
                        .help("End the reviewer and keep the review in your history")
                }
                Button("Post Review") { posting = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(pullRequest == nil || (review == nil && draft.comments.isEmpty))
            }
            HStack(spacing: 10) {
                if let review { verdictPill(review.verdict) }
                let ready = readiness(review)
                Button {
                    selectedFile = Self.overviewTag
                } label: {
                    Label(ready.sentence, systemImage: ready.symbol)
                        .foregroundStyle(ready.color)
                        .fontWeight(.medium)
                }
                .buttonStyle(.plain)
                .help("Whether GitHub will take the merge, and what's in the way: see the Overview")
                if let effort = review?.effort { EffortMeter(effort: effort) }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(14)
        .background(.bar)
    }

    @ViewBuilder
    private func status(state: SessionState, transcript: SessionTranscript?, hasReview: Bool) -> some View {
        if let archived = session.archivedAt {
            Label("Finished \(archived.formatted(.relative(presentation: .named)))", systemImage: "archivebox").foregroundStyle(.secondary)
        } else if sessions.reviewDrafts[session.id]?.posted != nil, !(sessions.isRunning(session.id) && (state == .working || state == .starting)) {
            let label = sessions.reviewDrafts[session.id]?.postedLabel ?? ("Posted", "checkmark.circle.fill", ChartPalette.good)
            Label(label.text, systemImage: label.symbol).foregroundStyle(label.color)
        } else if !sessions.isRunning(session.id) {
            Label("Not running", systemImage: "pause.circle").foregroundStyle(.secondary)
        } else if state == .working || state == .starting {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(transcript?.events.last.map { activity($0) } ?? "Starting")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 260, alignment: .leading)
            }
            .foregroundStyle(.secondary)
            .font(.callout)
        } else if state == .needsYou {
            Label("Needs you", systemImage: "questionmark.bubble.fill").foregroundStyle(.orange)
        } else if hasReview {
            Label("Review ready", systemImage: "checkmark.seal.fill").foregroundStyle(ChartPalette.good)
        }
    }

    private func activity(_ event: SessionTranscript.Event) -> String {
        switch event.kind {
        case .tool(let name): "\(name): \(event.text)"
        case .reply: "Writing the review"
        case .prompt: "Reading the PR"
        }
    }

    private func verdictPill(_ verdict: String?) -> some View {
        let (text, color): (String, Color) = switch verdict {
        case "approve": ("Approve", ChartPalette.good)
        case "request_changes": ("Request changes", ChartPalette.critical)
        default: ("Comment", .secondary)
        }
        return Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    // MARK: Files

    private func fileList(review: SessionTranscript.ReviewResult?) -> some View {
        let findings = visible(review?.findings ?? [])
        let drafts = sessions.reviewDrafts[session.id] ?? ReviewDraft()
        return VStack(spacing: 0) {
            if !(review?.findings ?? []).isEmpty {
                filterBar(review?.findings ?? [])
                Divider()
            }
            List(selection: $selectedFile) {
                if let pullRequest {
                    let ready = readiness(review)
                    Label {
                        Text("Overview")
                    } icon: {
                        Image(systemName: ready.symbol).foregroundStyle(ready.color)
                    }
                    .tag(Self.overviewTag)
                    .help("What the PR does, whether it can merge, what needs attention, and its conversation")
                    Label("Comments on this PR", systemImage: "bubble.left.and.bubble.right")
                        .foregroundStyle(.secondary)
                        .tag("\u{0}conversation")
                    let general = findings.filter { finding in !pullRequest.files.contains { $0.path == finding.path } }
                    if !general.isEmpty {
                        Label("\(general.count) not on a changed file", systemImage: "text.bubble")
                            .foregroundStyle(.secondary)
                            .tag("\u{0}general")
                    }
                    let learningCount = Set(applied(to: pullRequest).map(\.id)).union((review?.applied ?? []).map { appliedLearning($0.learning)?.id ?? $0.learning }).count + (review?.learnings?.count ?? 0)
                    if learningCount > 0 {
                        Label(learningCount == 1 ? "1 learning" : "\(learningCount) learnings", systemImage: HarnessKind.learnings.systemImage)
                            .foregroundStyle(.secondary)
                            .tag("\u{0}learnings")
                            .help("Learnings from the harness that cover this PR's files, and any the reviewer suggests keeping")
                    }
                    let config = session.reviewConfig
                    let skipped = pullRequest.files.filter { config?.ignores($0.path) == true }
                    let areas = Self.areas(review?.walkthrough ?? [], files: pullRequest.files.filter { config?.ignores($0.path) != true })
                    ForEach(Array(areas.enumerated()), id: \.offset) { index, area in
                        Section {
                            ForEach(area.files) { file in
                                fileRow(file, findings: findings, drafts: drafts)
                            }
                        } header: {
                            if let title = area.title {
                                HStack(spacing: 6) {
                                    AreaNumber(number: index + 1)
                                    Text(title).lineLimit(1)
                                }
                                .help(area.summary ?? title)
                            } else if areas.count > 1 {
                                Text("Other files")
                            }
                        }
                    }
                    if !skipped.isEmpty {
                        Section {
                            ForEach(skipped) { file in
                                fileRow(file, findings: findings, drafts: drafts).foregroundStyle(.secondary)
                            }
                        } header: {
                            Text("Skipped by the review config")
                                .help("The review config says not to review these, so the reviewer left them alone")
                        }
                    }
                } else {
                    ProgressView()
                }
            }
        }
    }

    /// The PR's files in the walkthrough's areas, in its order, then any it
    /// didn't name; one untitled group when there's no walkthrough.
    static func areas(_ walkthrough: [SessionTranscript.WalkthroughArea], files: [ReviewedPullRequest.File]) -> [(title: String?, summary: String?, files: [ReviewedPullRequest.File])] {
        var placed: Set<String> = []
        var areas: [(title: String?, summary: String?, files: [ReviewedPullRequest.File])] = []
        for area in walkthrough {
            let mine = area.files.compactMap { path in files.first { $0.path == path } }.filter { placed.insert($0.path).inserted }
            if !mine.isEmpty { areas.append((area.title, area.summary, mine)) }
        }
        let rest = files.filter { !placed.contains($0.path) }
        if !rest.isEmpty { areas.append((nil, nil, rest)) }
        return areas
    }

    private func filterBar(_ all: [SessionTranscript.Finding]) -> some View {
        let categories = ReviewCategory.allCases.map { category in (category, all.filter { ReviewCategory($0.category) == category }.count) }.filter { $0.1 > 0 }
        let severities = ReviewSeverity.allCases.map { severity in (severity, all.filter { (ReviewSeverity($0.severity) ?? .minor) == severity }.count) }.filter { $0.1 > 0 }
        return HStack(spacing: 6) {
            Menu {
                Button("All Findings (\(all.count))") { filter = nil }
                Section("Severity") {
                    ForEach(severities, id: \.0) { severity, count in
                        Toggle("\(severity.title) (\(count))", isOn: Binding(get: { filter == .severity(severity) }, set: { filter = $0 ? .severity(severity) : nil }))
                    }
                }
                if !categories.isEmpty {
                    Section("Category") {
                        ForEach(categories, id: \.0) { category, count in
                            Toggle(isOn: Binding(get: { filter == .category(category) }, set: { filter = $0 ? .category(category) : nil })) {
                                Label("\(category.title) (\(count))", systemImage: category.systemImage)
                            }
                        }
                    }
                }
            } label: {
                Label(filter.map { "Findings: \($0.title)" } ?? "All findings", systemImage: "line.3.horizontal.decrease.circle\(filter == nil ? "" : ".fill")")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer()
            if filter != nil {
                Button("Clear") { filter = nil }.buttonStyle(.borderless).font(.caption)
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func fileRow(_ file: ReviewedPullRequest.File, findings: [SessionTranscript.Finding], drafts: ReviewDraft) -> some View {
        let here = findings.filter { $0.path == file.path && drafts.decisions[$0.key] != .dismissed }
        let mine = drafts.comments.filter { $0.path == file.path }.count
        let existing = (pullRequest?.existingComments ?? []).filter { $0.path == file.path }.count
        let learned = learnings(on: file).count
        return HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text((file.path as NSString).lastPathComponent).lineLimit(1)
                Text((file.path as NSString).deletingLastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 4)
            if let worst = here.min(by: { $0.severityRank < $1.severityRank }) {
                Text("\(here.count)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 6)
                    .background(worst.severityColor.opacity(0.25), in: Capsule())
            }
            if existing > 0 {
                Image(systemName: "text.bubble").foregroundStyle(.secondary).font(.caption)
                    .help("\(existing) existing comment\(existing == 1 ? "" : "s")")
            }
            if mine > 0 {
                Image(systemName: "text.bubble.fill").foregroundStyle(Color.accentColor).font(.caption)
            }
            if learned > 0 {
                Image(systemName: HarnessKind.learnings.systemImage)
                    .foregroundStyle(.yellow)
                    .font(.caption)
                    .help(learned == 1 ? "A learning covers this file" : "\(learned) learnings cover this file")
            }
        }
        .tag(file.path)
        .help(file.path)
    }

    // MARK: Diff

    @ViewBuilder
    private func diffColumn(review: SessionTranscript.ReviewResult?) -> some View {
        let findings = visible(review?.findings ?? [])
        if let pullRequest {
            if selectedFile == Self.overviewTag {
                ReviewOverview(
                    session: session, reference: reference, pullRequest: pullRequest, review: review,
                    readiness: readiness(review), status: status, canAsk: sessions.isRunning(session.id),
                    open: open, ask: { text in
                        guard sessions.submit(text, to: session.id) else { return false }
                        conversation = true
                        return true
                    }
                )
            } else if selectedFile == "\u{0}conversation" {
                List { DescriptionSections(id: reference.id, url: reference.url) }
            } else if selectedFile == "\u{0}general" {
                let general = findings.filter { finding in !pullRequest.files.contains { $0.path == finding.path } }
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("These go in the review's body, as GitHub only takes comments on lines the diff shows.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        ForEach(general, id: \.key) { finding in
                            FindingCard(session: session, finding: finding, showsLocation: true)
                        }
                    }
                    .padding(16)
                }
            } else if selectedFile == "\u{0}learnings" {
                learningsColumn(pullRequest: pullRequest, review: review)
            } else if let file = pullRequest.files.first(where: { $0.path == selectedFile }) {
                ReviewDiff(
                    session: session, file: file, findings: findings.filter { $0.path == file.path }, learnings: learnings(on: file),
                    applied: (review?.applied ?? []).filter { $0.path == file.path }, resolve: { appliedLearning($0) },
                    learningURL: { harnessIndex?.url(for: $0.document) },
                    existingComments: pullRequest.existingComments.filter { $0.path == file.path }
                )
                .id(file.path)
            } else {
                ContentUnavailableView("Pick a file", systemImage: "doc.text.magnifyingglass")
            }
        } else if let error {
            ContentUnavailableView("Couldn't load the PR", systemImage: "exclamationmark.triangle", description: Text(error))
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: Learnings

extension PullRequestReviewView {
    /// The harness the reviewer runs in, where its learnings are.
    private var harnessIndex: HarnessIndex? {
        harness.anyIndex(org: reference.org, repo: session.harnessRepo ?? session.repo)
    }

    /// The harness's learnings for the repo whose scope covers a file the PR
    /// changes, on the lines its diff shows when a learning names lines.
    func applied(to pullRequest: ReviewedPullRequest) -> [HarnessLearning] {
        let learnings = harnessIndex?.learnings(for: reference.repo) ?? []
        guard !learnings.isEmpty else { return [] }
        return learnings.filter { learning in pullRequest.files.contains { learning.covers($0.path, lines: $0.shownLines) } }
    }

    /// The learning an `applied` entry names, by its path in the harness.
    func appliedLearning(_ path: String) -> HarnessLearning? {
        let path = path.trimmingCharacters(in: CharacterSet(charactersIn: "`/ "))
        let documents = harnessIndex?.documents(.learnings) ?? []
        let document = documents.first { $0.path == path } ?? documents.first { $0.path.hasSuffix("/" + path) || path.hasSuffix("/" + $0.path) }
        return document.flatMap(HarnessLearning.init(document:))
    }

    /// The learnings covering one file, on the lines its diff shows.
    func learnings(on file: ReviewedPullRequest.File) -> [HarnessLearning] {
        (harnessIndex?.learnings(for: reference.repo) ?? []).filter { $0.covers(file.path, lines: file.shownLines) }
    }

    func learningsColumn(pullRequest: ReviewedPullRequest, review: SessionTranscript.ReviewResult?) -> some View {
        let used = review?.applied ?? []
        let usedPaths = Set(used.compactMap { appliedLearning($0.learning)?.id })
        let applied = applied(to: pullRequest).filter { !usedPaths.contains($0.id) }
        let proposed = review?.learnings ?? []
        let saved = Set((harnessIndex?.documents(.learnings) ?? []).compactMap { $0.frontMatter?["source"]?.first })
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !used.isEmpty {
                    Text("Applied by the reviewer").font(.headline)
                    Text("What each learning changed in this review. Challenge one to have the reviewer look again without it, or edit the learning (or retire it) if it's wrong.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    ForEach(used, id: \.self) { entry in
                        AppliedLearningCard(session: session, entry: entry, learning: appliedLearning(entry.learning), url: appliedLearning(entry.learning).flatMap { harnessIndex?.url(for: $0.document) }, showsLocation: true)
                    }
                }
                if !applied.isEmpty {
                    Text(used.isEmpty ? "Covering this PR" : "Also covering this PR").font(.headline)
                    Text("Learnings in the harness whose scope covers files this PR changes. The reviewer was given them\(used.isEmpty ? "" : " and didn't say it applied these").")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    ForEach(applied) { learning in
                        HarnessLearningRow(learning: learning, url: harnessIndex?.url(for: learning.document), org: reference.org, harnessRepo: session.harnessRepo)
                        Divider()
                    }
                }
                if !proposed.isEmpty {
                    Text("Suggested by the reviewer").font(.headline)
                    Text("Explanations people gave in this PR that later reviews should know. Save one to check and edit it, then commit it to the harness.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    ForEach(proposed, id: \.self) { learning in
                        proposedCard(learning, pullRequest: pullRequest, isSaved: learning.source.map(saved.contains) ?? false)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func proposedCard(_ learning: SessionTranscript.ProposedLearning, pullRequest: ReviewedPullRequest, isSaved: Bool) -> some View {
        var draft = HarnessLearningDraft()
        draft.repo = reference.repo
        draft.rule = learning.rule
        draft.reason = learning.reason ?? ""
        draft.source = learning.source ?? ""
        draft.author = learning.author ?? ""
        draft.issues = ["\(reference.repo)#\(reference.number)"]
        if let path = learning.path, !path.isEmpty {
            let lines = learning.line.map { $0...max($0, learning.endLine ?? $0) }
            draft.paths = HarnessLearning.Scope(path: path, lines: lines).text
            if lines != nil { draft.commit = pullRequest.headSHA }
        }
        return VStack(alignment: .leading, spacing: 6) {
            Text(learning.rule).fixedSize(horizontal: false, vertical: true)
            if let reason = learning.reason {
                Text(reason).font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if !draft.paths.isEmpty {
                    Text(draft.paths).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                if let author = learning.author {
                    Text("From @\(author)").font(.caption).foregroundStyle(.secondary)
                }
                if let source = learning.source.flatMap(URL.init(string:)) {
                    Link(destination: source) { Image(systemName: "arrow.up.right.square") }
                        .help("Open the comment on GitHub")
                }
                Spacer()
                if isSaved {
                    Label("In the harness", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(ChartPalette.good)
                } else {
                    SaveAsLearningButton(org: reference.org, draft: draft)
                }
            }
        }
        .padding(10)
        .background(Color.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// A learning the reviewer applied: the rule, what it changed in the review
/// and any doubt the reviewer had, with Challenge (your objection, sent to
/// the reviewer to look again) and Edit Learning.
private struct AppliedLearningCard: View {
    @Environment(SessionStore.self) private var sessions
    let session: CodeSession
    let entry: SessionTranscript.AppliedLearning
    let learning: HarnessLearning?
    let url: URL?
    let showsLocation: Bool
    @State private var challenging = false
    @State private var objection = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: HarnessKind.learnings.systemImage).foregroundStyle(.yellow)
                Text("Applied: \(learning?.rule ?? entry.learning)")
                    .fontWeight(.medium)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if let url {
                    Link(destination: url) { Image(systemName: "arrow.up.right.square") }
                        .help("Open the learning in the harness on GitHub")
                }
            }
            if showsLocation, let path = entry.path {
                Text(entry.line.map { "\(path):\($0)" } ?? path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            if let note = entry.note {
                Text(note).font(.callout)
            }
            if let concern = entry.concern {
                Label(concern, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            if let reason = learning?.reason {
                Text("Why: \(reason)").font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            HStack(spacing: 8) {
                Button("Challenge") { challenging = true }
                    .disabled(!sessions.isRunning(session.id))
                    .help(sessions.isRunning(session.id) ? "Tell the reviewer why this learning shouldn't apply here, and have it look again" : "Resume the review to challenge it")
                    .popover(isPresented: $challenging, arrowEdge: .bottom) { challengeEditor }
                if let learning {
                    EditLearningButton(org: session.org, learning: learning, harnessRepo: session.harnessRepo)
                }
                if learning == nil {
                    Text("Not in the harness as last fetched").font(.caption).foregroundStyle(.secondary)
                }
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(Color.yellow.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private var challengeEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Why shouldn't it apply here?").font(.headline)
            TextField("It was about the old sync path; this PR replaces it", text: $objection, axis: .vertical)
                .lineLimit(3...8)
                .frame(width: 360)
            HStack {
                Spacer()
                Button("Cancel") { challenging = false }
                Button("Send to Reviewer") {
                    if sessions.submit(SessionStore.challengePrompt(entry, objection: objection), to: session.id) {
                        objection = ""
                        challenging = false
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(objection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
    }
}

extension SessionStore {
    /// Your objection to a learning the reviewer applied, for it to look again.
    static func challengePrompt(_ entry: SessionTranscript.AppliedLearning, objection: String) -> String {
        let place = entry.path.map { path in " on `\(path)\(entry.line.map { ":\($0)" } ?? "")`" } ?? ""
        return """
            You applied the learning `\(entry.learning)`\(place)\(entry.note.map { " (\($0))" } ?? ""). I'm challenging that: \(objection.trimmingCharacters(in: .whitespacesAndNewlines))

            Read the learning and the code again in that light. If it doesn't hold here, take it out of `applied` and raise what it kept you from raising as findings. If the learning itself is wrong or stale, say so in the summary and how it should change. End the same way, with the full JSON block.
            """
    }
}

/// One file's diff with the findings and your comments on their lines, and
/// any review comments already on GitHub.
private struct ReviewDiff: View {
    @Environment(SessionStore.self) private var sessions
    let session: CodeSession
    let file: ReviewedPullRequest.File
    let findings: [SessionTranscript.Finding]
    /// The harness's learnings covering this file.
    let learnings: [HarnessLearning]
    /// What the reviewer says learnings changed on this file.
    let applied: [SessionTranscript.AppliedLearning]
    let resolve: (String) -> HarnessLearning?
    let learningURL: (HarnessLearning) -> URL?
    let existingComments: [ReviewedPullRequest.ExistingComment]
    @State private var hovered: DiffLine.ID?
    @State private var commenting: DiffLine.ID?
    @State private var showsFileLearnings = true

    var body: some View {
        let drafts = sessions.reviewDrafts[session.id] ?? ReviewDraft()
        let placement = learningPlacement()
        let firstLine = placement.firstLine
        let marked = placement.marked
        let fileWide = placement.fileWide
        let appliedAt = placement.appliedAt
        let appliedTop = placement.appliedTop
        // Findings, and existing comments, on lines the diff doesn't show
        // (GitHub keeps an outdated comment's original line, but not in the
        // current diff), at the top.
        let placed = Set(file.lines.compactMap(\.newLine))
        let unplaced = findings.filter { $0.line.map { !placed.contains($0) } ?? true }
        let unplacedExisting = existingComments.filter { comment in !file.lines.contains { matches(comment, $0) } }
        VStack(spacing: 0) {
            HStack {
                Text(file.path).font(.callout.monospaced()).lineLimit(1).truncationMode(.head)
                Spacer()
                Text("+\(file.additions)").foregroundStyle(ChartPalette.good)
                Text("-\(file.deletions)").foregroundStyle(ChartPalette.critical)
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !fileWide.isEmpty {
                        DisclosureGroup(isExpanded: $showsFileLearnings) {
                            ForEach(fileWide) { learning in
                                HarnessLearningRow(learning: learning, url: learningURL(learning), org: session.org, harnessRepo: session.harnessRepo)
                            }
                        } label: {
                            Label(fileWide.count == 1 ? "A learning covers this file" : "\(fileWide.count) learnings cover this file", systemImage: HarnessKind.learnings.systemImage)
                                .font(.callout.weight(.medium))
                        }
                        .padding(10)
                        .background(Color.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        .padding(8)
                    }
                    ForEach(appliedTop, id: \.entry) { pair in
                        AppliedLearningCard(session: session, entry: pair.entry, learning: pair.learning, url: pair.learning.flatMap(learningURL), showsLocation: true)
                            .padding(8)
                    }
                    ForEach(unplaced, id: \.key) { finding in
                        FindingCard(session: session, finding: finding, showsLocation: true)
                            .padding(8)
                    }
                    ForEach(unplacedExisting) { comment in
                        ExistingCommentCard(comment: comment, showsLocation: true)
                            .padding(8)
                    }
                    if file.lines.isEmpty {
                        Text(file.status == "renamed" && file.additions == 0 && file.deletions == 0
                             ? "Renamed, with no changes to its contents."
                             : "No diff to show: a binary file, or too big for GitHub to send.")
                            .foregroundStyle(.secondary)
                            .padding(16)
                    }
                    ForEach(file.lines) { line in
                        ForEach(firstLine[line.id] ?? []) { learning in
                            HarnessLearningRow(learning: learning, url: learningURL(learning), org: session.org, harnessRepo: session.harnessRepo)
                                .padding(.horizontal, 10)
                                .background(Color.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                                .padding(.leading, 40)
                                .padding(.trailing, 8)
                                .padding(.vertical, 4)
                        }
                        DiffRow(sessionID: session.id, filePath: file.path, line: line, isLearned: marked.contains(line.id), hovered: $hovered, commenting: $commenting)
                        if let newLine = line.newLine {
                            ForEach(appliedAt[newLine] ?? [], id: \.entry) { pair in
                                AppliedLearningCard(session: session, entry: pair.entry, learning: pair.learning, url: pair.learning.flatMap(learningURL), showsLocation: false)
                                    .padding(.leading, 40)
                                    .padding(.trailing, 8)
                                    .padding(.vertical, 4)
                            }
                            ForEach(findings.filter { $0.line == newLine }, id: \.key) { finding in
                                FindingCard(session: session, finding: finding, showsLocation: false)
                                    .padding(.leading, 40)
                                    .padding(.trailing, 8)
                                    .padding(.vertical, 4)
                            }
                        }
                        ForEach(existingComments.filter { matches($0, line) }) { comment in
                            ExistingCommentCard(comment: comment, showsLocation: false)
                                .padding(.leading, 40)
                                .padding(.trailing, 8)
                                .padding(.vertical, 4)
                        }
                        ForEach(drafts.comments.filter { $0.path == file.path && matches($0, line) }) { comment in
                            OwnCommentCard(session: session, comment: comment)
                                .padding(.leading, 40)
                                .padding(.trailing, 8)
                                .padding(.vertical, 4)
                        }
                    }
                }
            }
        }
    }

    private typealias Applied = (entry: SessionTranscript.AppliedLearning, learning: HarnessLearning?)

    /// Where the file's learnings go: those on lines by the first shown line
    /// in their range (the lines marked), the reviewer's own account on its
    /// line (else the top) in place of the plain learning, and the rest
    /// (folders, the whole file, lines the diff doesn't show) at the top.
    private func learningPlacement() -> (firstLine: [DiffLine.ID: [HarnessLearning]], marked: Set<DiffLine.ID>, fileWide: [HarnessLearning], appliedAt: [Int: [Applied]], appliedTop: [Applied]) {
        let appliedHere: [Applied] = applied.map { ($0, resolve($0.learning)) }
        let shownApplied = Set(appliedHere.compactMap(\.learning?.id))
        var firstLine: [DiffLine.ID: [HarnessLearning]] = [:]
        var marked: Set<DiffLine.ID> = []
        var placed: Set<String> = []
        for learning in learnings {
            let ranges = learning.scopes.filter { $0.covers(file.path) }.compactMap(\.lines)
            guard !ranges.isEmpty else { continue }
            for line in file.lines {
                guard let number = line.newLine ?? line.oldLine, ranges.contains(where: { $0.contains(number) }) else { continue }
                marked.insert(line.id)
                if placed.insert(learning.id).inserted, !shownApplied.contains(learning.id) {
                    firstLine[line.id, default: []].append(learning)
                }
            }
        }
        let shown = Set(file.lines.compactMap(\.newLine))
        let appliedAt = Dictionary(grouping: appliedHere.filter { $0.entry.line.map(shown.contains) ?? false }) { $0.entry.line ?? 0 }
        let appliedTop = appliedHere.filter { !($0.entry.line.map(shown.contains) ?? false) }
        let fileWide = learnings.filter { !placed.contains($0.id) && !shownApplied.contains($0.id) }
        return (firstLine, marked, fileWide, appliedAt, appliedTop)
    }

    private func matches(_ comment: ReviewDraft.Comment, _ line: DiffLine) -> Bool {
        guard let anchor = line.anchor else { return false }
        return anchor.line == comment.line && anchor.isOld == comment.isOld
    }

    private func matches(_ comment: ReviewedPullRequest.ExistingComment, _ line: DiffLine) -> Bool {
        guard let anchor = line.anchor else { return false }
        return anchor.line == comment.line && anchor.isOld == comment.isOld
    }
}

/// One line of the diff with its comment popover. A dedicated view (not a
/// function on `ReviewDiff`) with narrow, stable inputs: while claude is
/// actively writing the review, `ReviewDiff` rebuilds every row as
/// `findings`/drafts change, but this row only re-renders when its own
/// inputs do, so a comment popover left open doesn't lose the TextEditor's
/// cursor position on every poll tick.
private struct DiffRow: View {
    @Environment(SessionStore.self) private var sessions
    let sessionID: UUID
    let filePath: String
    let line: DiffLine
    /// A learning's lines take it in: marked down the edge.
    var isLearned = false
    @Binding var hovered: DiffLine.ID?
    @Binding var commenting: DiffLine.ID?

    var body: some View {
        let anchor = line.anchor
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            ZStack(alignment: .trailing) {
                Text(anchor.map { "\($0.line)" } ?? "")
                    .foregroundStyle(.tertiary)
                    .opacity(hovered == line.id && anchor != nil ? 0 : 1)
                if hovered == line.id, anchor != nil {
                    Image(systemName: "plus.bubble.fill").foregroundStyle(Color.accentColor)
                }
            }
            .frame(width: 34, alignment: .trailing)
            .padding(.trailing, 6)
            .contentShape(Rectangle())
            .onTapGesture { if anchor != nil { commenting = line.id } }
            Text(line.text.isEmpty ? " " : line.text)
                .foregroundStyle(line.kind == .hunk ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.trailing, 6)
        .background(Self.background(line.kind))
        .overlay(alignment: .leading) {
            if isLearned {
                Rectangle().fill(Color.yellow.opacity(0.7)).frame(width: 3)
                    .help("A learning covers this line")
            }
        }
        .onHover { inside in
            if inside { hovered = line.id } else if hovered == line.id { hovered = nil }
        }
        .popover(isPresented: Binding(get: { commenting == line.id }, set: { if !$0 { commenting = nil } }), arrowEdge: .leading) {
            if let anchor {
                ReviewCommentEditor(location: "\(filePath):\(anchor.line)") { body in
                    sessions.reviewDrafts[sessionID, default: ReviewDraft()].comments.append(
                        .init(path: filePath, line: anchor.line, isOld: anchor.isOld, body: body)
                    )
                    commenting = nil
                } cancel: {
                    commenting = nil
                }
            }
        }
    }

    private static func background(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: ChartPalette.good.opacity(0.14)
        case .removed: ChartPalette.critical.opacity(0.14)
        case .hunk: Color.secondary.opacity(0.1)
        case .context, .note: .clear
        }
    }
}

/// A finding: its severity, what claude says and any suggestion, to keep,
/// edit or dismiss.
private struct FindingCard: View {
    @Environment(SessionStore.self) private var sessions
    let session: CodeSession
    let finding: SessionTranscript.Finding
    let showsLocation: Bool
    @State private var isEditing = false
    @State private var editingText = ""

    var body: some View {
        let decision = sessions.reviewDrafts[session.id]?.decisions[finding.key]
        let dismissed = decision == .dismissed
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text((finding.severity ?? "note").capitalized)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(finding.severityColor.opacity(0.25), in: Capsule())
                if let category = ReviewCategory(finding.category) {
                    CategoryChip(category: category)
                }
                Image(systemName: "sparkle").font(.caption).foregroundStyle(.orange)
                Text("Claude").font(.caption).foregroundStyle(.secondary)
                if showsLocation {
                    Text(finding.line.map { "\(finding.path):\($0)" } ?? finding.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer()
                if dismissed {
                    Button("Restore") { set(nil) }.buttonStyle(.borderless)
                } else if !isEditing {
                    Button("Edit") { editingText = text(decision); isEditing = true }.buttonStyle(.borderless)
                    Button("Dismiss") { set(.dismissed) }.buttonStyle(.borderless)
                }
            }
            .font(.callout)
            if isEditing {
                TextEditor(text: $editingText)
                    .font(.callout)
                    .frame(minHeight: 70)
                HStack {
                    Spacer()
                    Button("Cancel") { isEditing = false }
                    Button("Save") {
                        set(editingText == finding.comment ? nil : .edited(editingText))
                        isEditing = false
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                Text(text(decision))
                    .font(.callout)
                    .strikethrough(dismissed)
                    .foregroundStyle(dismissed ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let suggestion = finding.suggestion, !dismissed {
                    Text(suggestion)
                        .font(.system(size: 11, design: .monospaced))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(ChartPalette.good.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(dismissed ? 0.5 : 1), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(dismissed ? Color.separatorLine : finding.severityColor.opacity(0.7), lineWidth: 1)
        }
        .overlay(alignment: .leading) {
            if !dismissed {
                UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 8).fill(finding.severityColor).frame(width: 4)
            }
        }
    }

    private func text(_ decision: ReviewDraft.Decision?) -> String {
        if case .edited(let text) = decision { return text }
        return finding.comment
    }

    private func set(_ decision: ReviewDraft.Decision?) {
        sessions.reviewDrafts[session.id, default: ReviewDraft()].decisions[finding.key] = decision
    }
}

/// A review comment already on GitHub: read-only, with who left it and
/// when, and a link to it.
private struct ExistingCommentCard: View {
    let comment: ReviewedPullRequest.ExistingComment
    var showsLocation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Avatar(url: comment.avatarURL, size: 16)
                Text(comment.author).font(.callout.weight(.medium))
                if showsLocation {
                    Text("\(comment.path):\(comment.line)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                RelativeDate(date: comment.createdAt).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let url = comment.url {
                    Link(destination: url) { Image(systemName: "arrow.up.right.square") }
                        .help("Open on GitHub")
                }
            }
            MarkdownText(source: comment.body)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(Color.separatorLine, lineWidth: 1) }
    }
}

private struct OwnCommentCard: View {
    @Environment(SessionStore.self) private var sessions
    let session: CodeSession
    let comment: ReviewDraft.Comment

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "text.bubble.fill").foregroundStyle(Color.accentColor)
            Text(comment.body)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                sessions.reviewDrafts[session.id]?.comments.removeAll { $0.id == comment.id }
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Remove your comment")
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct ReviewCommentEditor: View {
    let location: String
    let add: (String) -> Void
    let cancel: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(location).font(.caption.monospaced()).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .frame(width: 340, height: 100)
                .focused($focused)
            HStack {
                Text("Posted with the review").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Add") { add(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .onAppear { focused = true }
    }
}

// MARK: - Posting

/// The review as it'll go to GitHub: approve, comment or request changes,
/// the body (claude's summary, and findings not on a line GitHub takes),
/// and the inline comments: findings kept or edited, and yours, and your
/// threads claude says are dealt with, to resolve. Nothing's sent until Post.
private struct PostReviewSheet: View {
    @Environment(SessionStore.self) private var sessions
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss
    let session: CodeSession
    let pullRequest: ReviewedPullRequest
    let review: SessionTranscript.ReviewResult?
    @State private var event = "COMMENT"
    @State private var bodyText = ""
    @State private var sending = false
    @State private var error: String?
    /// Your threads the review says are dealt with, and those ticked to resolve.
    @State private var threads: [ReviewThread] = []
    @State private var resolving: Set<String> = []
    /// Posted, with threads left that GitHub didn't resolve: Post only
    /// tries those again.
    @State private var isPosted = false
    @AppStorage(SessionStore.recordReviewsKey) private var recordsReview = true

    private var reference: PullRequestReference { session.reviewOf! }

    /// GitHub won't take an approval or a change request on your own PR.
    private var isOwn: Bool {
        guard let me = auth.viewer?.login, let author = pullRequest.author else { return false }
        return me.caseInsensitiveCompare(author) == .orderedSame
    }

    var body: some View {
        let (inline, general) = comments()
        Form {
            Section {
                Picker("Review", selection: $event) {
                    Text("Comment").tag("COMMENT")
                    if !isOwn {
                        Text("Approve").tag("APPROVE")
                        Text("Request Changes").tag("REQUEST_CHANGES")
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text(verbatim: "\(reference.repo)#\(reference.number)")
            } footer: {
                if isOwn {
                    Text("It's your own pull request, so GitHub only takes a comment.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            // An editor rather than a field: a field selects all its text
            // when the sheet gives it focus.
            Section {
                TextEditor(text: $bodyText)
                    .font(.body)
                    .frame(minHeight: 160, idealHeight: 220)
                    .scrollContentBackground(.hidden)
            } header: {
                Text("Body")
            } footer: {
                Text(general.isEmpty ? "" : "\(general.count) finding\(general.count == 1 ? " isn't" : "s aren't") on a line the diff shows, so \(general.count == 1 ? "it's" : "they're") in the body.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("\(inline.count) inline comment\(inline.count == 1 ? "" : "s")") {
                ForEach(Array(inline.enumerated()), id: \.offset) { _, comment in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(comment["path"] as? String ?? ""):\(comment["line"] as? Int ?? 0)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Text(comment["body"] as? String ?? "")
                            .font(.callout)
                            .lineLimit(4)
                    }
                }
            }
            if !threads.isEmpty {
                Section {
                    ForEach(threads) { thread in
                        Toggle(isOn: Binding(
                            get: { resolving.contains(thread.id) },
                            set: { if $0 { resolving.insert(thread.id) } else { resolving.remove(thread.id) } }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(thread.line.map { "\(thread.path):\($0)" } ?? thread.path)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                Text(thread.body)
                                    .font(.callout)
                                    .lineLimit(3)
                            }
                        }
                        .checkboxToggle()
                    }
                } header: {
                    Text("Resolve \(threads.count) thread\(threads.count == 1 ? "" : "s") now dealt with")
                } footer: {
                    Text("Claude says the code or a reply has dealt with these. Ticked ones are resolved once the review is posted.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Toggle("Record it in the harness", isOn: $recordsReview)
                    .checkboxToggle()
            } footer: {
                Text("One commit to \(session.harnessRepo ?? "the harness") with the findings, what you made of them, and later whether their threads were resolved, for Agents › Metrics. It names you as the reviewer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
        }
        .formStyle(.grouped)
        .frame(width: 620, height: 640)
        .task { await loadThreads() }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(sending ? "Posting" : isPosted ? "Resolve Threads" : "Post to GitHub") { post(inline) }
                    .disabled(sending || isPosted && resolving.isEmpty || !isPosted && (bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && inline.isEmpty && event != "APPROVE"))
            }
        }
        .onAppear {
            // Not an approval of commits the review hasn't seen.
            let isStale = sessions.sessions[session.id]?.watch?.hasNewCommits == true
            event = switch isOwn || isStale ? nil : review?.verdict {
            case "approve": "APPROVE"
            case "request_changes": "REQUEST_CHANGES"
            default: "COMMENT"
            }
            bodyText = ReviewedPullRequest.body(summary: review?.summary ?? "", general: general)
        }
    }

    /// The inline comments GitHub will take, and the findings it won't.
    private func comments() -> ([[String: Any]], [SessionTranscript.Finding]) {
        pullRequest.comments(for: review, draft: sessions.reviewDrafts[session.id] ?? ReviewDraft())
    }

    private func loadThreads() async {
        guard let api = auth.api, let ids = review?.resolved, !ids.isEmpty else { return }
        threads = (try? await api.resolvableThreads(ids, pullRequest: reference.id)) ?? []
        resolving = Set(threads.map(\.id))
    }

    private func post(_ inline: [[String: Any]]) {
        guard let api = auth.api else { return }
        sending = true
        error = nil
        let body = bodyText
        let event = event
        let toResolve = threads.filter { resolving.contains($0.id) }
        Task {
            if !isPosted {
                do {
                    let url = try await api.postReview(repo: reference.repo, number: reference.number, commit: pullRequest.headSHA, event: event, body: body, comments: inline)
                    sessions.reviewDrafts[session.id, default: ReviewDraft()].posted = url ?? reference.url
                    sessions.reviewDrafts[session.id, default: ReviewDraft()].postedAt = .now
                    sessions.reviewDrafts[session.id, default: ReviewDraft()].postedEvent = event
                    isPosted = true
                } catch {
                    self.error = "GitHub didn't take it: \(error.localizedDescription)"
                    sending = false
                    return
                }
            }
            // The review's posted; threads GitHub won't resolve are named
            // and the sheet stays open, the rest still go.
            var failed: [ReviewThread] = []
            for thread in toResolve {
                do {
                    try await api.resolveReviewThread(thread.id)
                } catch {
                    failed.append(thread)
                }
            }
            sending = false
            if recordsReview {
                let id = session.id
                Task { await sessions.recordReview(id, posting: true) }
            }
            if failed.isEmpty {
                dismiss()
            } else {
                threads = failed
                resolving = Set(failed.map(\.id))
                self.error = "The review is posted, but GitHub didn't resolve \(failed.count == 1 ? "this thread" : "these threads"). Try again, or resolve \(failed.count == 1 ? "it" : "them") on GitHub."
            }
        }
    }
}

/// Beside a PR in a list, when Claude has a review of it: what the review's
/// doing, and a click to its tab. The store is passed in rather than read
/// from the environment: a table's cells, rebuilt when it sorts, don't
/// always get the page's environment objects.
struct ClaudeReviewBadge: View {
    @Environment(\.openWindow) private var openWindow
    let sessions: SessionStore
    let pullRequestID: String

    var body: some View {
        if let review = sessions.review(of: pullRequestID) {
            let (text, color) = label(review)
            Button {
                sessions.show(review.id, with: openWindow)
            } label: {
                Label(text, systemImage: "eye")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(color.opacity(0.14), in: Capsule())
                    .fixedSize()
            }
            .buttonStyle(.plain)
            .help("Open Claude's review of this PR")
        }
    }

    private func label(_ review: CodeSession) -> (String, Color) {
        let state = sessions.state(review.id)
        let working = sessions.isRunning(review.id) && (state == .working || state == .starting)
        if !working, sessions.reviewDrafts[review.id]?.posted != nil || review.reviewDraft?.posted != nil {
            let label = (sessions.reviewDrafts[review.id] ?? review.reviewDraft)?.postedLabel
            return (label?.text ?? "Posted", label?.color ?? ChartPalette.good)
        }
        guard sessions.isRunning(review.id) else {
            return sessions.transcripts[review.id]?.review != nil ? ("Review ready", ChartPalette.good) : ("Review", .secondary)
        }
        switch state {
        case .needsYou: return ("Needs you", .orange)
        case .starting, .working: return ("Reviewing", ChartPalette.blue)
        default: return sessions.transcripts[review.id]?.review != nil ? ("Review ready", ChartPalette.good) : ("Review", .secondary)
        }
    }
}
