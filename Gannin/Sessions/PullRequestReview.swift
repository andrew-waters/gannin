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
    /// When the latest review result arrived. `posted` stays set across
    /// rounds, so only a post at or after this is of the latest result.
    var resultAt: Date?

    /// Whether the author has seen the latest result.
    var postedLatest: Bool {
        guard posted != nil else { return false }
        guard let resultAt else { return true }
        return (postedAt ?? .distantPast) >= resultAt
    }

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
        /// A later push changed the line: `line` is where it was, in an older
        /// commit, and GitHub hides the comment by default.
        var isOutdated = false
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
    /// Reviews already submitted on the PR, anyone's, whose bodies carry
    /// the findings that couldn't go on a line.
    var earlierReviews: [PostedReview] = []
    /// Set when the comments were fetched leniently and that failed, so
    /// `existingComments` and `earlierReviews` may be missing some.
    var existingCommentsError: String?
    /// The signed-in user, whose outdated comments still count as said.
    /// Set by the caller, which already knows it.
    var viewer: String?

    /// How far, in lines, a finding can be from a comment saying the same
    /// and still be covered by it: a push or a re-run often moves the
    /// point a line or two.
    static let lineLeeway = 3

    /// A finding left out of a review because a comment or an earlier
    /// review already says much the same.
    struct Omitted {
        let path: String
        let line: Int?
        /// What the finding said, as it would have been posted.
        let comment: String
        /// Who said it before, and what they said.
        let author: String
        let said: String
        let url: URL?
    }

    /// The inline comments GitHub will take (findings kept or edited on
    /// lines the diff shows, and your own), the findings it won't, and the
    /// findings left out because the PR already says the same.
    func comments(for review: SessionTranscript.ReviewResult?, draft: ReviewDraft) -> ([[String: Any]], [SessionTranscript.Finding], [Omitted]) {
        var inline: [[String: Any]] = []
        var general: [SessionTranscript.Finding] = []
        var omitted: [Omitted] = []
        // This review, if it's already on GitHub (posted from another Mac,
        // or before a relaunch), isn't an earlier one: leaving out what it
        // said would shrink the body so `PostedReview.repeated` misses it.
        let summary = review?.summary.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let earlier = earlierReviews.filter { summary.isEmpty || !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(summary) }
        for finding in review?.findings ?? [] {
            let decision = draft.decisions[finding.key]
            if decision == .dismissed { continue }
            var text = finding.comment
            if case .edited(let edited) = decision { text = edited }
            guard let line = finding.line, let file = files.first(where: { $0.path == finding.path }), file.hasLine(line, isOld: false) else {
                if let before = said(text, path: finding.path, line: finding.line, earlier: earlier) {
                    omitted.append(.init(path: finding.path, line: finding.line, comment: text, author: before.author, said: before.said, url: before.url))
                } else {
                    general.append(.init(path: finding.path, line: finding.line, comment: text, severity: finding.severity))
                }
                continue
            }
            if let before = said(text, path: finding.path, line: line, earlier: earlier) {
                omitted.append(.init(path: finding.path, line: line, comment: text, author: before.author, said: before.said, url: before.url))
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
        return (inline, general, omitted)
    }

    /// Who already said `text` about `path`, and where: a review comment on
    /// the new side near `line` (anywhere in the file for a finding with
    /// no line), or a finding in an earlier review's body about the path.
    /// An outdated comment counts only when it's the viewer's: GitHub hides
    /// it, but it was still sent, while someone else's may be about code
    /// that has since changed.
    private func said(_ text: String, path: String, line: Int?, earlier: [PostedReview]) -> (author: String, said: String, url: URL?)? {
        let comment = existingComments.first { comment in
            guard !comment.isOld, comment.path == path, Self.isSameComment(existing: comment.body, finding: text) else { return false }
            if comment.isOutdated {
                guard let viewer, comment.author.caseInsensitiveCompare(viewer) == .orderedSame else { return false }
                return true
            }
            guard let line else { return true }
            return abs(comment.line - line) <= Self.lineLeeway
        }
        if let comment { return (comment.author, comment.body, comment.url) }
        for review in earlier {
            for entry in Self.findingEntries(in: review.body) {
                if let comment = Self.comment(on: path, in: entry), Self.isSameComment(existing: comment, finding: text) {
                    return (review.author, comment, review.url)
                }
            }
        }
        return nil
    }

    /// The findings in a review body as `body(summary:general:)` writes
    /// them: each starts a line with "- `" and runs until the next, so a
    /// comment over several lines stays whole.
    private static func findingEntries(in body: String) -> [String] {
        var entries: [String] = []
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("- `") {
                entries.append(String(line))
            } else if !entries.isEmpty {
                entries[entries.count - 1] += "\n" + line
            }
        }
        return entries
    }

    /// What a body finding says, when it's about `path` exactly: its lead
    /// is "- `path`: " or "- `path:line`: ".
    private static func comment(on path: String, in entry: String) -> String? {
        let lead = "- `" + path
        guard entry.hasPrefix(lead) else { return nil }
        var rest = entry.dropFirst(lead.count)
        if rest.first == ":" {
            rest = rest.dropFirst()
            guard rest.first?.isNumber == true else { return nil }
            rest = rest.drop { $0.isNumber }
        }
        guard rest.hasPrefix("`:") else { return nil }
        return rest.dropFirst(2).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether an existing comment already says what a finding says: the
    /// comment contains the whole finding, or they share most of their words.
    /// Case, punctuation and suggestion blocks are ignored, since people
    /// reword and Gannin adds the latter. A finding that adds to the comment
    /// isn't covered by it, so containment only works one way.
    static func isSameComment(existing: String, finding: String) -> Bool {
        let x = words(existing), y = words(finding)
        guard !x.isEmpty, !y.isEmpty else { return false }
        let said = " " + x.joined(separator: " ") + " ", asked = y.joined(separator: " ")
        if asked.count >= 20, said.contains(" " + asked + " ") { return true }
        // Sharing a prefix isn't enough: "crashes" and "leaks memory" are different points.
        guard min(x.count, y.count) >= 4 else { return false }
        let shared = Set(x).intersection(y).count
        return Double(shared) / Double(Set(x).union(y).count) >= 0.8
    }

    private static func words(_ text: String) -> [String] {
        text.replacing(/```suggestion.*?```/.dotMatchesNewlines(), with: "")
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
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

/// A review you've submitted on GitHub, as `GitHubAPI.myReviews` reads it.
struct PostedReview: Equatable {
    /// `APPROVE`, `REQUEST_CHANGES` or `COMMENT`, as when posting.
    let event: String
    let body: String
    let commit: String
    let url: URL?
    let submittedAt: Date
    /// Who submitted it; empty when only the viewer's reviews were read.
    var author = ""

    /// The latest of `reviews` whose body begins with a review's summary:
    /// that review, posted from here or from elsewhere.
    static func latest(in reviews: [PostedReview], summary: String) -> PostedReview? {
        let summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { return nil }
        return reviews.last { $0.body.hasPrefix(summary) }
    }

    /// A review that posting `body` as `event` on `commit` would repeat.
    static func repeated(in reviews: [PostedReview], event: String, commit: String, body: String) -> PostedReview? {
        let body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return reviews.last {
            $0.event == event && $0.commit == commit && $0.body.trimmingCharacters(in: .whitespacesAndNewlines) == body
        }
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

    /// The PR's whole unified diff in one request, split by file below.
    /// The per-file `files` endpoint leaves out `patch` for a binary file
    /// or one with too many changes, but the diff itself doesn't single
    /// files out that way, so this is what each file's lines come from.
    func pullRequestDiff(repo: String, number: Int) async throws -> String {
        try await restText("repos/\(repo)/pulls/\(number)", accept: "application/vnd.github.v3.diff")
    }

    /// Splits a full diff into each file's own section, keyed by its
    /// current path (a renamed file's new one), so it reads like the single
    /// file's patch `GitDiff.lines` expects.
    private static func diffSections(_ diff: String) -> [String: String] {
        var sections: [String: String] = [:]
        var path: String?
        var lines: [Substring] = []
        func finish() {
            if let path { sections[path] = lines.joined(separator: "\n") }
            lines = []
        }
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git a/"), let marker = line.range(of: " b/", options: .backwards) {
                finish()
                path = String(line[marker.upperBound...])
            }
            lines.append(line)
        }
        finish()
        return sections
    }

    /// With `lenientComments`, failing to fetch the PR's existing review
    /// comments doesn't fail the fetch: `existingCommentsError` says so instead.
    func reviewedPullRequest(repo: String, number: Int, lenientComments: Bool = false) async throws -> ReviewedPullRequest {
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
        var batches: [File] = []
        for page in 1...30 {
            let batch: [File] = try await rest("repos/\(repo)/pulls/\(number)/files", query: ["per_page": "100", "page": "\(page)"])
            batches += batch
            if batch.count < 100 { break }
        }
        // Each file's own patch is enough for almost every PR, so the whole
        // diff is only fetched when something needs it: a binary file or
        // one with too many changes, which GitHub leaves `patch` out for
        // (a pure rename has none either, but there's nothing to show).
        let missingPatch = batches.contains { $0.patch == nil && !($0.status == "renamed" && $0.additions == 0 && $0.deletions == 0) }
        let sections = missingPatch ? ((try? await pullRequestDiff(repo: repo, number: number)).map(Self.diffSections) ?? [:]) : [:]
        let files = batches.map { file in
            let diff = file.patch ?? sections[file.filename] ?? ""
            return ReviewedPullRequest.File(path: file.filename, status: file.status, additions: file.additions, deletions: file.deletions, lines: GitDiff.lines(of: diff).0)
        }
        var existing: [ReviewedPullRequest.ExistingComment] = []
        var earlier: [PostedReview] = []
        var existingError: String?
        do {
            existing = try await existingComments(repo: repo, number: number)
            earlier = try await reviews(repo: repo, number: number)
        } catch {
            if !lenientComments { throw error }
            existingError = error.localizedDescription
        }
        return ReviewedPullRequest(
            title: pull.title, body: pull.body ?? "", author: pull.user?.login, headSHA: pull.head.sha,
            additions: pull.additions, deletions: pull.deletions,
            state: pull.merged == true ? "merged" : pull.state, files: files,
            existingComments: existing, earlierReviews: earlier, existingCommentsError: existingError
        )
    }

    /// Review comments already on GitHub, on the lines they're anchored to.
    /// One left on a line a later push made outdated keeps its original
    /// line and side, since GitHub drops `line`/`side` once that happens.
    func existingComments(repo: String, number: Int) async throws -> [ReviewedPullRequest.ExistingComment] {
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
                    createdAt: comment.createdAt, url: comment.htmlUrl, isOutdated: comment.line == nil
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

    /// The reviews you've submitted on a PR, oldest first. Pending and
    /// dismissed ones aren't counted.
    func myReviews(repo: String, number: Int) async throws -> [PostedReview] {
        let me = try await viewer().login
        return try await reviews(repo: repo, number: number).filter { $0.author.caseInsensitiveCompare(me) == .orderedSame }
    }

    /// Everyone's submitted reviews on a PR, oldest first. Pending and
    /// dismissed ones aren't counted.
    func reviews(repo: String, number: Int) async throws -> [PostedReview] {
        struct Review: Decodable {
            struct User: Decodable { let login: String }
            let state: String
            let body: String?
            let commitId: String?
            let htmlUrl: URL?
            let submittedAt: Date?
            let user: User?
        }
        var reviews: [PostedReview] = []
        for page in 1...30 {
            let batch: [Review] = try await rest("repos/\(repo)/pulls/\(number)/reviews", query: ["per_page": "100", "page": "\(page)"])
            reviews += batch.compactMap { review in
                guard let login = review.user?.login,
                      let event = ["APPROVED": "APPROVE", "CHANGES_REQUESTED": "REQUEST_CHANGES", "COMMENTED": "COMMENT"][review.state],
                      let at = review.submittedAt else { return nil }
                return PostedReview(event: event, body: review.body ?? "", commit: review.commitId ?? "", url: review.htmlUrl, submittedAt: at, author: login)
            }
            if batch.count < 100 { break }
        }
        return reviews
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
        // resolveReviewThread is nullable: an empty Response would decode
        // past a refusal (no write access) rather than surfacing it.
        struct Response: Decodable {
            struct Payload: Decodable { struct Thread: Decodable { let id: String }; let thread: Thread }
            let resolveReviewThread: Payload
        }
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

/// What opens an Explain window: the PR, and a review's walkthrough when
/// one's already open (the review tab's header), so Claude can build on the
/// areas a review already worked out rather than read the diff cold.
struct ExplainPullRequestRequest: Codable, Hashable {
    let reference: PullRequestReference
    var walkthrough: [SessionTranscript.WalkthroughArea] = []
}

/// Explain in a PR's right-click menu, toolbar or drawer: a one-off
/// question, not a session, so it's available wherever a PR is shown. Opens
/// its own window (`ExplainPullRequestWindow`), so it can sit alongside the
/// PR while Claude reads it.
struct ExplainPullRequestButton: View {
    static let windowID = "explain-pull-request"
    let reference: PullRequestReference
    var walkthrough: [SessionTranscript.WalkthroughArea] = []
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            openWindow(id: Self.windowID, value: ExplainPullRequestRequest(reference: reference, walkthrough: walkthrough))
        } label: {
            Label("Explain", systemImage: "text.bubble")
        }
        .help("Have Claude explain what this PR changes and why, in plain terms")
    }
}

/// Claude's explanation of a PR, asked fresh each time the window opens
/// (`ClaudeRunner.ask`, not a session): what it reads with `gh`, and what
/// it's told to reply with. The window holds one conversation (`--resume`
/// in the same folder), so a follow-up question is answered from the diff
/// and discussion already read, not a fresh `gh` lookup.
struct ExplainPullRequestWindow: View {
    let reference: PullRequestReference
    /// A review's areas, when one's already open for this PR: Claude is
    /// told it can build on them instead of reading the diff cold.
    var walkthrough: [SessionTranscript.WalkthroughArea] = []

    private struct Turn: Identifiable {
        let id: UUID
        let fromClaude: Bool
        var text: String

        init(id: UUID = UUID(), fromClaude: Bool, text: String) {
            self.id = id
            self.fromClaude = fromClaude
            self.text = text
        }
    }

    @State private var text = ""
    @State private var turns: [Turn] = []
    @State private var message = ""
    @State private var working = false
    @State private var status: String?
    @State private var conversation = UUID()

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Group {
                            if text.isEmpty {
                                HStack(spacing: 8) {
                                    if working { ProgressView().controlSize(.small) }
                                    Text(working ? "Claude is reading it." : "Nothing yet.").foregroundStyle(.secondary)
                                }
                            } else {
                                MarkdownText(source: text, reading: 14)
                            }
                        }
                        ForEach(turns) { turn in
                            bubble(turn).id(turn.id)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: turns.count) {
                    if let last = turns.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            if !text.isEmpty {
                Divider()
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Ask a follow-up question", text: $message, axis: .vertical)
                        .lineLimit(1...4)
                        .onSubmit(askFollowUp)
                    Button("Ask") { askFollowUp() }
                        .keyboardShortcut(.return, modifiers: [.command])
                        .disabled(working || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(12)
            }
            Divider()
            HStack {
                if let status { Text(status).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button(text.isEmpty ? "Explain" : "Explain Again") { explain() }
                    .disabled(working)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(transcript, forType: .string)
                    status = "Copied"
                }
                .disabled(text.isEmpty)
            }
            .padding(12)
        }
        .ownWindowTitle("Explain \(reference.repo)#\(reference.number)", subtitle: reference.title)
        .onAppear { if text.isEmpty { explain() } }
    }

    private func bubble(_ turn: Turn) -> some View {
        HStack(alignment: .top) {
            if !turn.fromClaude { Spacer(minLength: 40) }
            Group {
                if turn.fromClaude && turn.text.isEmpty {
                    ProgressView().controlSize(.small)
                } else if turn.fromClaude {
                    MarkdownText(source: turn.text, reading: 13)
                } else {
                    Text(turn.text).textSelection(.enabled)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(turn.fromClaude ? Color.secondary.opacity(0.12) : Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
            if turn.fromClaude { Spacer(minLength: 40) }
        }
    }

    private var transcript: String {
        ([text] + turns.map { $0.fromClaude ? $0.text : "**Q:** \($0.text)" }).joined(separator: "\n\n")
    }

    /// A review's walkthrough as a prompt fragment, or empty when there
    /// isn't one open for this PR.
    private var walkthroughNote: String {
        guard !walkthrough.isEmpty else { return "" }
        let areas = walkthrough.map { area in
            "- \(area.title)" + (area.summary.map { ": \($0)" } ?? "") + " (\(area.files.joined(separator: ", ")))"
        }.joined(separator: "\n")
        return """

            A review has already split this PR into these areas, in reading order:
            \(areas)

            Build on that structure rather than working it out again, but explain the code in your own words, not the review's.

            """
    }

    private func explain() {
        text = ""
        turns = []
        conversation = UUID()
        working = true
        status = nil
        let id = conversation.uuidString.lowercased()
        let prompt = """
            Explain pull request \(reference.repo)#\(reference.number), "\(reference.title)" (\(reference.url.absoluteString)), for someone who hasn't read it: explain the code, not just the PR description.

            Read the actual changes with `gh pr diff \(reference.number) --repo \(reference.repo)` first, then `gh pr view \(reference.number) --repo \(reference.repo) --comments` for the stated intent and discussion. Base the explanation on what the diff does, not a reworded version of the title or description.

            Reply with the explanation only, no preamble, in Markdown: a short paragraph on what the code does and why, then a few bullet points on the notable changes if there are several, naming the functions, types or files involved. Where a short snippet would make a change clearer than naming it, include one as a fenced code block (with a language and, where it helps, the file path above it), taken from the actual diff rather than paraphrased. Don't review it or suggest changes.
            \(walkthroughNote)
            I may ask follow-up questions about this PR afterwards; answer those from the diff and discussion you've already read, in the same plain Markdown style, with no preamble.
            """
        Task {
            do {
                text = try await ClaudeRunner.ask(
                    prompt, org: reference.org, folder: "gannin-explain-\(id)", tools: ["Bash"], session: (id, false)
                ) { chunk in
                    text += chunk
                }
            } catch {
                status = error.localizedDescription
            }
            working = false
        }
    }

    private func askFollowUp() {
        let question = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !working else { return }
        message = ""
        status = nil
        turns.append(Turn(fromClaude: false, text: question))
        let replyID = UUID()
        turns.append(Turn(id: replyID, fromClaude: true, text: ""))
        working = true
        let id = conversation.uuidString.lowercased()
        Task {
            do {
                let reply = try await ClaudeRunner.ask(
                    question, org: reference.org, folder: "gannin-explain-\(id)", tools: ["Bash"], session: (id, true)
                ) { chunk in
                    if let index = turns.firstIndex(where: { $0.id == replyID }) { turns[index].text += chunk }
                }
                if let index = turns.firstIndex(where: { $0.id == replyID }) { turns[index].text = reply }
            } catch {
                if let index = turns.firstIndex(where: { $0.id == replyID }) { turns[index].text = error.localizedDescription }
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
    @State private var checkingForChanges = false
    /// What the last Check for Changes found, until the next one.
    @State private var checkResult: String?
    @State private var headerWidth: CGFloat = 0
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
            let fetched = try await RequestLimiter.interactive {
                try await api.reviewedPullRequest(repo: reference.repo, number: reference.number)
            }
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

    /// What a check found: the PR's `state` from `checkWatchedReviews` (nil
    /// when it couldn't look) and what the watch has noted since the review.
    /// Without a watch only the diff and status were refreshed, so it can't say.
    private func checkSummary(watching: Bool, state: String?) -> String {
        guard watching else { return "Refreshed (not watching)" }
        switch state {
        case nil: return "Couldn't check GitHub"
        case "MERGED": return "Merged"
        case "CLOSED": return "Closed"
        default: break
        }
        guard let watch = sessions.sessions[session.id]?.watch else { return "No changes" }
        var found: [String] = []
        if watch.hasNewCommits { found.append("new commits") }
        if watch.newComments > 0 { found.append("\(watch.newComments) new comment\(watch.newComments == 1 ? "" : "s")") }
        return found.isEmpty ? "No changes" : found.joined(separator: ", ")
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
        let titleBlock = VStack(alignment: .leading, spacing: 3) {
            Link(destination: reference.url) {
                Text(reference.title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .help("Open the pull request on GitHub")
            FlowRow(spacing: 8) {
                Link(destination: reference.url) {
                    Label(reference.repo + "#" + String(reference.number), systemImage: "arrow.up.right.square")
                }
                .fixedSize()
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
        let controls = FlowRow(spacing: 10, alignment: .center) {
            status(state: state, transcript: transcript, hasReview: review != nil)
                .frame(width: Self.statusWidth, alignment: .leading)
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
            ExplainPullRequestButton(reference: reference, walkthrough: review?.walkthrough ?? [])
                .buttonStyle(.bordered)
            Button("Check for Changes") {
                checkingForChanges = true
                Task {
                    defer { checkingForChanges = false }
                    let watching = sessions.sessions[session.id]?.watch?.isOn == true
                    let state = await sessions.checkWatchedReviews(only: session.id, reviewing: false)
                    let foundPost = await sessions.syncPostedReview(session.id)
                    await load()
                    await loadStatus()
                    // The sessions grid reads its checks from `pullRequestInfo`.
                    await sessions.refreshPullRequests(session.id)
                    checkResult = checkSummary(watching: watching, state: state) + (foundPost ? ", review found on GitHub" : "")
                }
            }
            .disabled(checkingForChanges || session.archivedAt != nil)
            .help("Fetch the PR again now, and note any new commits or comments, without asking claude to review it")
            if let checkResult {
                Text(checkResult).font(.callout).foregroundStyle(.secondary)
            }
            Button("Review Again") {
                reviewingAgain = true
                checkResult = nil
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
            } else if review != nil {
                Label("Not posted", systemImage: "circle.dashed")
                    .foregroundStyle(.secondary)
                    .help("This review hasn't been posted to GitHub. Check for Changes also looks for one you posted elsewhere")
            }
            // Kept in the row while the first review runs, so it appearing
            // doesn't reflow the buttons.
            Toggle("Watch for changes", isOn: Binding(
                get: { sessions.sessions[session.id]?.watch?.isOn ?? false },
                set: { sessions.setWatching(session.id, $0) }
            ))
            .checkboxToggle()
            .help("Review it again by itself when new commits are pushed or someone comments, until it's merged or closed")
            .opacity(review == nil ? 0 : 1)
            .disabled(review == nil)
            .accessibilityHidden(review == nil)
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
        return VStack(alignment: .leading, spacing: 10) {
            // Chosen from the window's width alone, never from what's loaded
            // (the diff's meta items, the Posted link), so nothing flips the
            // layout when they appear.
            if headerWidth >= Self.sideBySideWidth {
                HStack(alignment: .top, spacing: 16) {
                    titleBlock.frame(width: Self.titleWidth, alignment: .leading)
                    controls
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    titleBlock
                    controls
                }
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { headerWidth = $0 }
        .padding(14)
        .background(.bar)
    }

    /// Every status takes this width, so the buttons beside it don't move or
    /// re-wrap as it changes; the working label is the widest and truncates.
    private static let statusWidth: CGFloat = 280

    private static let titleWidth: CGFloat = 360

    /// The header width from which the controls sit beside the title.
    private static let sideBySideWidth: CGFloat = 1100

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
                    .frame(maxWidth: .infinity, alignment: .leading)
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

    /// Sends a question to the review's claude and shows the conversation;
    /// false when it couldn't be sent.
    private func askReviewer(_ text: String) -> Bool {
        guard sessions.submit(text, to: session.id) else { return false }
        conversation = true
        return true
    }

    /// What a diff line's Ask Claude sends with; nil while claude isn't running.
    private var diffAsk: ((String) -> Bool)? {
        guard sessions.isRunning(session.id) else { return nil }
        return { askReviewer($0) }
    }

    @ViewBuilder
    private func diffColumn(review: SessionTranscript.ReviewResult?) -> some View {
        let findings = visible(review?.findings ?? [])
        if let pullRequest {
            if selectedFile == Self.overviewTag {
                ReviewOverview(
                    session: session, reference: reference, pullRequest: pullRequest, review: review,
                    readiness: readiness(review), status: status, canAsk: sessions.isRunning(session.id),
                    open: open, ask: askReviewer
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
                    existingComments: pullRequest.existingComments.filter { $0.path == file.path },
                    fileURL: URL(string: "https://github.com/\(reference.repo)/blob/\(pullRequest.headSHA)/\(file.path)"),
                    ask: diffAsk
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
    /// The file at the PR's head commit, for a binary or too-large diff
    /// GitHub sent no patch for.
    let fileURL: URL?
    /// Sends a question to the review's claude; nil when it isn't running.
    let ask: ((String) -> Bool)?
    @State private var hovered: DiffLine.ID?
    @State private var commenting: DiffLine.ID?
    @State private var showsFileLearnings = true
    @Environment(\.colorScheme) private var colorScheme
    /// Syntax colours with the lines they were made from; nil for a file
    /// that isn't highlighted, which shows plain. Kept while new ones are
    /// made, and used only while the lines are unchanged.
    @State private var highlights: Highlights?

    /// What the highlights were made from, so a new file or appearance
    /// makes them again.
    private struct Highlights {
        let lines: [DiffLine]
        let colours: [DiffLine.ID: AttributedString]
    }

    private struct HighlightKey: Equatable {
        let lines: [DiffLine]
        let dark: Bool
    }

    var body: some View {
        let drafts = sessions.reviewDrafts[session.id] ?? ReviewDraft()
        let colours = highlights.flatMap { $0.lines == file.lines ? $0.colours : nil }
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
                        let isPureRename = file.status == "renamed" && file.additions == 0 && file.deletions == 0
                        VStack(alignment: .leading, spacing: 8) {
                            Text(isPureRename
                                 ? "Renamed, with no changes to its contents."
                                 : "No diff to show: too big for GitHub to send, even as the whole pull request's diff.")
                                .foregroundStyle(.secondary)
                            if !isPureRename, let fileURL {
                                Link("Open on GitHub", destination: fileURL)
                            }
                        }
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
                        DiffRow(sessionID: session.id, filePath: file.path, line: line, highlight: colours?[line.id], isLearned: marked.contains(line.id), hovered: $hovered, commenting: $commenting, lines: file.lines, ask: ask)
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
        .task(id: HighlightKey(lines: file.lines, dark: colorScheme == .dark)) {
            await computeHighlights()
        }
    }

    private func computeHighlights() async {
        let key = HighlightKey(lines: file.lines, dark: colorScheme == .dark)
        let result = await DiffHighlighter.shared.colours(for: key.lines, path: file.path, dark: key.dark)
        guard !Task.isCancelled else { return }
        highlights = result.map { Highlights(lines: key.lines, colours: $0) }
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
    /// The line's code coloured by its language, without its marker; nil
    /// draws the plain line.
    var highlight: AttributedString?
    /// A learning's lines take it in: marked down the edge.
    var isLearned = false
    @Binding var hovered: DiffLine.ID?
    @Binding var commenting: DiffLine.ID?
    /// The file's lines, for the context sent with a question.
    let lines: [DiffLine]
    /// Sends a question to the review's claude; nil when it isn't running.
    let ask: ((String) -> Bool)?

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
            if let highlight {
                // The marker stays in the gutter, tinted harder than the row.
                Text(String(line.text.prefix(1)))
                    .foregroundStyle(DiffStyle.markerColor(line.kind))
                    .frame(width: 14)
                    .background(DiffStyle.gutterTint(line.kind))
                Text(highlight.characters.isEmpty ? AttributedString(" ") : highlight)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            } else {
                Text(line.text.isEmpty ? " " : line.text)
                    .foregroundStyle(line.kind == .hunk ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .font(Font(EditorFontStore.shared.font))
        .padding(.trailing, 6)
        .background(DiffStyle.background(line.kind, highlighted: highlight != nil))
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
                ReviewCommentEditor(location: "\(filePath):\(anchor.line)", add: { body in
                    sessions.reviewDrafts[sessionID, default: ReviewDraft()].comments.append(
                        .init(path: filePath, line: anchor.line, isOld: anchor.isOld, body: body)
                    )
                    commenting = nil
                }, ask: ask == nil ? nil : { question in
                    askAbout(line, anchor: anchor, question)
                }, cancel: {
                    commenting = nil
                })
            }
        }
    }

    /// Sends the question with its context, closing the popover once sent.
    private func askAbout(_ line: DiffLine, anchor: (line: Int, isOld: Bool), _ question: String) -> Bool {
        guard let ask else { return false }
        let sent = ask(DiffQuestion.message(question, path: filePath, anchor: anchor, line: line, in: lines))
        if sent { commenting = nil }
        return sent
    }
}

/// A question about a diff line, with the lines around it, for the review's
/// claude.
nonisolated enum DiffQuestion {
    static let radius = 5

    static func message(_ question: String, path: String, anchor: (line: Int, isOld: Bool), line: DiffLine, in lines: [DiffLine]) -> String {
        let side = anchor.isOld ? "line \(anchor.line) of the old file" : "line \(anchor.line)"
        guard let index = lines.firstIndex(where: { $0.id == line.id }) else {
            return "A question about \(path), \(side):\n\n\(question)"
        }
        let nearby = lines.indices.filter { abs($0 - index) <= radius }.map { lines[$0] }
        let shown = nearby.map { ($0.id == line.id ? "> " : "  ") + $0.text }.joined(separator: "\n")
        // Longer than any run of backticks in the lines, so one of them can't end the block early.
        var longest = 0
        var run = 0
        for character in shown {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return "A question about \(path), \(side), marked > in this part of the diff:\n\n\(fence)diff\n\(shown)\n\(fence)\n\n\(question)"
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
                        .font(Font(EditorFontStore.shared.font))
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
    /// nil when the review's claude can't be asked.
    let ask: ((String) -> Bool)?
    let cancel: () -> Void
    @State private var text = ""
    @State private var askFailed = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(location).font(.caption.monospaced()).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .frame(width: 340, height: 100)
                .focused($focused)
            HStack {
                if askFailed {
                    Text("Couldn't reach Claude").font(.caption).foregroundStyle(ChartPalette.critical)
                } else {
                    Text("Add posts with the review").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Ask Claude", action: askClaude)
                    .keyboardShortcut(.return, modifiers: [.command, .option])
                    .disabled(ask == nil || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help(ask == nil ? "The review's Claude isn't running" : "Send this to the reviewer with the lines around it")
                Button("Add") { add(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .onAppear { focused = true }
        .onChange(of: text) { askFailed = false }
    }

    private func askClaude() {
        guard let ask else { return }
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        askFailed = !ask(question)
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
    @Environment(OrgStore.self) private var orgs
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
    /// The PR's review comments and reviews as of pressing Post, fetched
    /// once before the review goes, since the sheet's own copy dates from
    /// when it opened.
    @State private var latestComments: [ReviewedPullRequest.ExistingComment]?
    @State private var latestReviews: [PostedReview]?
    /// Whether Post has already checked for new comments, or tried to, so
    /// pressing it again after a failed check posts without one.
    @State private var checkedComments = false
    @State private var notice: String?
    /// The body as built from the findings, to tell whether the user has
    /// edited `bodyText` since.
    @State private var builtBody = ""

    private var reference: PullRequestReference { session.reviewOf! }

    /// The PR with the latest comments and reviews in place of the ones it
    /// was opened with. Only those change: the review is posted against the
    /// commit it saw.
    private var current: ReviewedPullRequest {
        var pull = pullRequest
        pull.viewer = auth.viewer?.login
        if let latestComments, let latestReviews {
            pull.existingComments = latestComments
            pull.earlierReviews = latestReviews
        }
        return pull
    }

    /// GitHub won't take an approval or a change request on your own PR.
    private var isOwn: Bool {
        guard let me = auth.viewer?.login, let author = pullRequest.author else { return false }
        return me.caseInsensitiveCompare(author) == .orderedSame
    }

    var body: some View {
        let (inline, general, omitted) = comments()
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
            if !omitted.isEmpty {
                Section {
                    ForEach(Array(omitted.enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(item.path)\(item.line.map { ":\($0)" } ?? "")")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            Text(item.comment)
                                .font(.callout)
                                .lineLimit(3)
                            Text("\(item.author): \(item.said)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                } header: {
                    Text("\(omitted.count) finding\(omitted.count == 1 ? "" : "s") left out")
                } footer: {
                    Text("A comment near \(omitted.count == 1 ? "its line" : "their lines"), or an earlier review, already says much the same, so \(omitted.count == 1 ? "it isn't" : "they aren't") posted again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
            if let notice {
                Text(notice).foregroundStyle(.orange).font(.callout)
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
                Button(sending ? "Posting" : isPosted ? "Resolve Threads" : "Post to GitHub") { post() }
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
            builtBody = bodyText
        }
    }

    /// The inline comments GitHub will take, the findings it won't, and the
    /// findings left out because their line already has the same comment.
    private func comments() -> ([[String: Any]], [SessionTranscript.Finding], [ReviewedPullRequest.Omitted]) {
        current.comments(for: review, draft: sessions.reviewDrafts[session.id] ?? ReviewDraft())
    }

    private func loadThreads() async {
        guard let api = auth.api, let ids = review?.resolved, !ids.isEmpty else { return }
        threads = (try? await api.resolvableThreads(ids, pullRequest: reference.id)) ?? []
        resolving = Set(threads.map(\.id))
    }

    /// GitHub drops you from the PR's requested reviewers once you review it.
    /// The workload's copy says so now, and the review requests are fetched
    /// again, so the Inbox doesn't keep the PR as waiting on you until the
    /// next refresh.
    private func markReviewed(event: String) {
        if let me = auth.viewer?.login {
            let state = ["APPROVE": "APPROVED", "REQUEST_CHANGES": "CHANGES_REQUESTED"][event] ?? "COMMENTED"
            orgs.updatePullRequest(reference.id, org: reference.org) { pr in
                pr.requestedReviewers.removeAll { $0.login == me }
                pr.reviewRequestedAt[me] = nil
                pr.reviewStates = (pr.reviewStates ?? [:]).merging([me: state]) { _, new in new }
                pr.reviewedAt = (pr.reviewedAt ?? [:]).merging([me: .now]) { _, new in new }
            }
        }
        Task { await EngineerWatch.shared.check() }
    }

    private func post() {
        guard let api = auth.api else { return }
        sending = true
        error = nil
        notice = nil
        let body = bodyText
        let event = event
        let toResolve = threads.filter { resolving.contains($0.id) }
        Task {
            if !isPosted {
                if !checkedComments {
                    // Comments left since the sheet opened. Findings they
                    // duplicate drop out, and the user sees that before it goes.
                    let shown = Set(comments().2.map { "\($0.path):\($0.line ?? 0):\($0.comment)" })
                    checkedComments = true
                    do {
                        let comments = try await api.existingComments(repo: reference.repo, number: reference.number)
                        latestReviews = try await api.reviews(repo: reference.repo, number: reference.number)
                        latestComments = comments
                    } catch {
                        self.error = "Couldn't check the pull request for comments and reviews added since this review was drafted: \(error.localizedDescription). Post again to send it without that check."
                        sending = false
                        return
                    }
                    if shown != Set(comments().2.map { "\($0.path):\($0.line ?? 0):\($0.comment)" }) {
                        notice = "The findings left out changed: someone has commented or reviewed since this review was drafted. Check the list, then post again. To send one that's wrongly left out, add it as a comment of your own."
                        // The body carries the findings that go in it, so it
                        // changes with them, unless the user has edited it.
                        let rebuilt = ReviewedPullRequest.body(summary: review?.summary ?? "", general: comments().1)
                        if bodyText == builtBody {
                            bodyText = rebuilt
                        } else if rebuilt != builtBody {
                            notice! += " You've edited the review's text, so it wasn't updated: take out any finding now listed as left out."
                        }
                        builtBody = rebuilt
                        sending = false
                        return
                    }
                }
                // A failed lookup doesn't block posting, as with the comment check.
                if let mine = try? await api.myReviews(repo: reference.repo, number: reference.number),
                   let same = PostedReview.repeated(in: mine, event: event, commit: pullRequest.headSHA, body: body) {
                    sessions.reviewDrafts[session.id, default: ReviewDraft()].posted = same.url ?? reference.url
                    sessions.reviewDrafts[session.id, default: ReviewDraft()].postedAt = same.submittedAt
                    sessions.reviewDrafts[session.id, default: ReviewDraft()].postedEvent = event
                    isPosted = true
                    sending = false
                    notice = "You've already posted this review to GitHub, so it wasn't sent again."
                    return
                }
                let inline = comments().0
                do {
                    let url = try await api.postReview(repo: reference.repo, number: reference.number, commit: pullRequest.headSHA, event: event, body: body, comments: inline)
                    sessions.reviewDrafts[session.id, default: ReviewDraft()].posted = url ?? reference.url
                    sessions.reviewDrafts[session.id, default: ReviewDraft()].postedAt = .now
                    sessions.reviewDrafts[session.id, default: ReviewDraft()].postedEvent = event
                    isPosted = true
                    markReviewed(event: event)
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
