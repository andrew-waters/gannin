#if os(macOS)
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
    func startReview(of pr: PullRequestReference, harness setup: HarnessConfig, harnessPath: String) -> CodeSession {
        if let existing = review(of: pr.id) {
            reveal(existing.id)
            return existing
        }
        let branch = "review-\(pr.repo.split(separator: "/").last ?? "")-\(pr.number)"
        let session = CodeSession(
            id: UUID(), issue: IssueReference(org: pr.org, id: pr.id, number: pr.number, title: pr.title, repo: pr.repo, url: pr.url),
            repo: setup.repo, branch: branch, createdAt: .now, pullRequests: [pr.url],
            connect: Self.connectCommand, harnessRepo: setup.repo, harnessPath: harnessPath,
            role: "Review", prompt: Self.pullRequestReviewPrompt(pr, branch: branch), isReviewer: true, reviewOf: pr
        )
        let directory = Self.directory(for: session.id)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let brief = "# Review of \(pr.repo)#\(pr.number): \(pr.title)\n\n\(pr.url.absoluteString)\n"
        try? Data(brief.utf8).write(to: directory.appending(path: "brief.md"))
        add(session)
        reveal(session.id)
        return session
    }

    static func pullRequestReviewPrompt(_ pr: PullRequestReference, branch: String) -> String {
        let name = pr.repo.split(separator: "/").last.map(String.init) ?? pr.repo
        return """
            Review pull request \(pr.repo)#\(pr.number), "\(pr.title)" (\(pr.url.absoluteString)). This is a review: don't edit any files.

            Read it with `gh pr view \(pr.number) --repo \(pr.repo) --comments` and `gh pr diff \(pr.number) --repo \(pr.repo)`. For more than the diff, the repo's shared clone is `projects/\(name)` (if it isn't there, `gh repo clone \(pr.repo) projects/\(name)`); check the PR out to read around it or run its tests with `git -C projects/\(name) fetch origin pull/\(pr.number)/head && git -C projects/\(name) worktree add --detach "$PWD/.worktrees/\(branch)/\(name)" FETCH_HEAD`. Read the repo's CLAUDE.md, and the harness's STANDARDS.md, for how the team works.

            Look for bugs, missed cases, security problems, and code that doesn't fit the repo or the issue it's for. Comment only on lines the diff changes or shows. Say what's good in the summary, not as findings.

            End your reply with one fenced ```json block, findings most important first:
            {"summary": "<a few sentences for the PR's author>", "verdict": "approve" | "comment" | "request_changes", "findings": [{"path": "<path in the repo>", "line": <line in the new file>, "severity": "blocker" | "major" | "minor" | "nit", "comment": "<what's wrong and what to do>", "suggestion": "<optional: the replacement for that one line>"}]}

            If I ask you to look again, end the same way.
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

        /// Whether a comment can sit on the line: GitHub only takes lines
        /// the diff shows.
        func hasLine(_ line: Int, isOld: Bool) -> Bool {
            lines.contains { isOld ? $0.oldLine == line && $0.kind == .removed : $0.newLine == line }
        }
    }

    let title: String
    let body: String
    let author: String?
    let headSHA: String
    let additions: Int
    let deletions: Int
    let state: String
    let files: [File]
}

extension GitHubAPI {
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
                .init(path: file.filename, status: file.status, additions: file.additions, deletions: file.deletions, lines: SessionChanges.lines(of: file.patch ?? "").0)
            }
            if batch.count < 100 { break }
        }
        return ReviewedPullRequest(
            title: pull.title, body: pull.body ?? "", author: pull.user?.login, headSHA: pull.head.sha,
            additions: pull.additions, deletions: pull.deletions,
            state: pull.merged == true ? "merged" : pull.state, files: files
        )
    }

    /// Posts a review with inline comments. A write: not retried.
    func postReview(repo: String, number: Int, commit: String, event: String, body: String, comments: [[String: Any]]) async throws -> URL? {
        struct Posted: Decodable { let htmlUrl: URL? }
        let posted: Posted = try await restWrite("POST", "repos/\(repo)/pulls/\(number)/reviews", body: [
            "commit_id": commit, "event": event, "body": body, "comments": comments,
        ])
        return posted.htmlUrl
    }
}

// MARK: - Starting from a PR

/// Review with Claude on a PR: starts (or opens) its review in the
/// sessions window. Reviews run in the org's harness, as sessions do.
struct ReviewWithClaudeButton: View {
    @Environment(SessionStore.self) private var sessions
    @Environment(OrgConfigStore.self) private var configs
    @Environment(\.openWindow) private var openWindow
    let reference: PullRequestReference

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
            Button {
                guard let setup = configs.config(for: reference.org).harness,
                      let path = SessionStore.harnessPath(org: reference.org, repo: setup.repo) else { return }
                let session = sessions.startReview(of: reference, harness: setup, harnessPath: path)
                sessions.show(session.id, with: openWindow)
            } label: {
                Label("Review with Claude", systemImage: "eye")
            }
            .disabled(blocked != nil)
            .help(blocked ?? "Have Claude review this PR, then go through its findings and post the review to GitHub")
        }
    }

    private var unavailable: String? {
        guard configs.config(for: reference.org).harness != nil else {
            return "Reviews run in the org's harness. Pick or create it in the org's Settings, under Harness."
        }
        if SessionStore.connectCommand != nil, SessionStore.remoteHarnessPath(org: reference.org) == nil {
            return "Sessions run on your server. Set where the harness is checked out there in the org's Settings, under Harness."
        }
        return nil
    }
}

// MARK: - The review tab

/// A review's tab: the PR's files and diff with claude's findings on their
/// lines, its summary and verdict, and beneath, the conversation for
/// asking it more. Findings are kept, edited or dismissed, comments of your
/// own added on any line, and Post Review sends what's kept to GitHub as
/// one review.
struct PullRequestReviewView: View {
    @Environment(SessionStore.self) private var sessions
    @Environment(AuthStore.self) private var auth
    let session: CodeSession
    @State private var pullRequest: ReviewedPullRequest?
    @State private var error: String?
    @State private var selectedFile: String?
    /// Nil until toggled: shown while claude runs or hasn't reviewed yet,
    /// so a review read from the history doesn't start claude.
    @State private var conversation: Bool?
    @State private var confirmingFinish = false
    @State private var posting = false

    private var reference: PullRequestReference { session.reviewOf! }

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
            if selectedFile == nil { selectedFile = fetched.files.first?.path }
        } catch {
            self.error = error.localizedDescription
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
                    sessions.submit("The PR may have changed. Fetch it again, review it afresh, and end the same way with the JSON block.", to: session.id)
                    Task { await load() }
                }
                .disabled(!sessions.isRunning(session.id) || state == .working)
                .help("Ask claude to review the PR again, as it is now")
                if let posted = draft.posted {
                    Link(destination: posted) {
                        let label = draft.postedLabel ?? ("Posted", "checkmark.circle.fill", ChartPalette.good)
                        Label(draft.postedAt.map { "\(label.text) \($0.formatted(.relative(presentation: .named)))" } ?? label.text, systemImage: label.symbol)
                            .foregroundStyle(label.color)
                    }
                    .help("Open the review on GitHub")
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
            if let review {
                HStack(alignment: .top, spacing: 10) {
                    verdictPill(review.verdict)
                    MarkdownText(source: review.summary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
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
        let findings = review?.findings ?? []
        let drafts = sessions.reviewDrafts[session.id] ?? ReviewDraft()
        return List(selection: $selectedFile) {
            if let pullRequest {
                let general = findings.filter { finding in !pullRequest.files.contains { $0.path == finding.path } }
                if !general.isEmpty {
                    Label("\(general.count) not on a changed file", systemImage: "text.bubble")
                        .foregroundStyle(.secondary)
                        .tag("\u{0}general")
                }
                ForEach(pullRequest.files) { file in
                    let here = findings.filter { $0.path == file.path && drafts.decisions[$0.key] != .dismissed }
                    let mine = drafts.comments.filter { $0.path == file.path }.count
                    HStack(spacing: 6) {
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
                        if mine > 0 {
                            Image(systemName: "text.bubble.fill").foregroundStyle(Color.accentColor).font(.caption)
                        }
                    }
                    .tag(file.path)
                    .help(file.path)
                }
            } else {
                ProgressView()
            }
        }
    }

    // MARK: Diff

    @ViewBuilder
    private func diffColumn(review: SessionTranscript.ReviewResult?) -> some View {
        let findings = review?.findings ?? []
        if let pullRequest {
            if selectedFile == "\u{0}general" {
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
            } else if let file = pullRequest.files.first(where: { $0.path == selectedFile }) {
                ReviewDiff(session: session, file: file, findings: findings.filter { $0.path == file.path })
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

/// One file's diff with the findings and your comments on their lines.
private struct ReviewDiff: View {
    @Environment(SessionStore.self) private var sessions
    let session: CodeSession
    let file: ReviewedPullRequest.File
    let findings: [SessionTranscript.Finding]
    @State private var hovered: DiffLine.ID?
    @State private var commenting: DiffLine.ID?

    var body: some View {
        let drafts = sessions.reviewDrafts[session.id] ?? ReviewDraft()
        // Findings on lines the diff doesn't show, at the top.
        let placed = Set(file.lines.compactMap(\.newLine))
        let unplaced = findings.filter { $0.line.map { !placed.contains($0) } ?? true }
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
                    ForEach(unplaced, id: \.key) { finding in
                        FindingCard(session: session, finding: finding, showsLocation: true)
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
                        row(line)
                        if let newLine = line.newLine {
                            ForEach(findings.filter { $0.line == newLine }, id: \.key) { finding in
                                FindingCard(session: session, finding: finding, showsLocation: false)
                                    .padding(.leading, 40)
                                    .padding(.trailing, 8)
                                    .padding(.vertical, 4)
                            }
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

    private func matches(_ comment: ReviewDraft.Comment, _ line: DiffLine) -> Bool {
        guard let anchor = line.anchor else { return false }
        return anchor.line == comment.line && anchor.isOld == comment.isOld
    }

    private func row(_ line: DiffLine) -> some View {
        let anchor = line.anchor
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
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
        .background(background(line.kind))
        .onHover { inside in
            if inside { hovered = line.id } else if hovered == line.id { hovered = nil }
        }
        .popover(isPresented: Binding(get: { commenting == line.id }, set: { if !$0 { commenting = nil } }), arrowEdge: .leading) {
            if let anchor {
                ReviewCommentEditor(location: "\(file.path):\(anchor.line)") { body in
                    sessions.reviewDrafts[session.id, default: ReviewDraft()].comments.append(
                        .init(path: file.path, line: anchor.line, isOld: anchor.isOld, body: body)
                    )
                    commenting = nil
                } cancel: {
                    commenting = nil
                }
            }
        }
    }

    private func background(_ kind: DiffLine.Kind) -> Color {
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
    @State private var editing: String?

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
                } else if editing == nil {
                    Button("Edit") { editing = text(decision) }.buttonStyle(.borderless)
                    Button("Dismiss") { set(.dismissed) }.buttonStyle(.borderless)
                }
            }
            .font(.callout)
            if let editing {
                TextEditor(text: Binding(get: { editing }, set: { self.editing = $0 }))
                    .font(.callout)
                    .frame(minHeight: 70)
                HStack {
                    Spacer()
                    Button("Cancel") { self.editing = nil }
                    Button("Save") {
                        set(editing == finding.comment ? nil : .edited(editing))
                        self.editing = nil
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
/// and the inline comments: findings kept or edited, and yours. Nothing's
/// sent until Post.
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

    private var reference: PullRequestReference { session.reviewOf! }

    var body: some View {
        let (inline, general) = comments()
        Form {
            Section {
                Picker("Review", selection: $event) {
                    Text("Comment").tag("COMMENT")
                    Text("Approve").tag("APPROVE")
                    Text("Request Changes").tag("REQUEST_CHANGES")
                }
                .pickerStyle(.segmented)
            } header: {
                Text(verbatim: "\(reference.repo)#\(reference.number)")
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
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
        }
        .formStyle(.grouped)
        .frame(width: 620, height: 600)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(sending ? "Posting" : "Post to GitHub") { post(inline) }
                    .disabled(sending || (bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && inline.isEmpty && event != "APPROVE"))
            }
        }
        .onAppear {
            event = switch review?.verdict {
            case "approve": "APPROVE"
            case "request_changes": "REQUEST_CHANGES"
            default: "COMMENT"
            }
            var text = review?.summary ?? ""
            if !general.isEmpty {
                text += "\n\n" + general.map { finding in
                    "- `\(finding.path)\(finding.line.map { ":\($0)" } ?? "")`: \(finding.comment)"
                }.joined(separator: "\n")
            }
            bodyText = text
        }
    }

    /// The inline comments GitHub will take, and the findings it won't.
    private func comments() -> ([[String: Any]], [SessionTranscript.Finding]) {
        let draft = sessions.reviewDrafts[session.id] ?? ReviewDraft()
        var inline: [[String: Any]] = []
        var general: [SessionTranscript.Finding] = []
        for finding in review?.findings ?? [] {
            let decision = draft.decisions[finding.key]
            if decision == .dismissed { continue }
            var text = finding.comment
            if case .edited(let edited) = decision { text = edited }
            guard let line = finding.line, let file = pullRequest.files.first(where: { $0.path == finding.path }), file.hasLine(line, isOld: false) else {
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

    private func post(_ inline: [[String: Any]]) {
        guard let api = auth.api else { return }
        sending = true
        error = nil
        let body = bodyText
        let event = event
        Task {
            do {
                let url = try await api.postReview(repo: reference.repo, number: reference.number, commit: pullRequest.headSHA, event: event, body: body, comments: inline)
                sessions.reviewDrafts[session.id, default: ReviewDraft()].posted = url ?? reference.url
                sessions.reviewDrafts[session.id, default: ReviewDraft()].postedAt = .now
                sessions.reviewDrafts[session.id, default: ReviewDraft()].postedEvent = event
                dismiss()
            } catch {
                self.error = "GitHub didn't take it: \(error.localizedDescription)"
            }
            sending = false
        }
    }
}
#endif

#if os(macOS)
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
#endif
