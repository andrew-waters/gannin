import Foundation

/// A learning: a rule or a reason a person gave in review ("we do x because
/// of y"), scoped to the code it's about, so later reviews follow it rather
/// than asking again. Kept in the harness as `learnings/<repo>/<date>-<slug>.md`
/// with front matter `repo`, `paths`, `commit`, `source` and `author`, the
/// rule as its `summary`, and `## Rule`, `## Reason` and `## Source` below.
nonisolated struct HarnessLearning: Identifiable, Hashable, Sendable {
    /// Where it applies: a folder (`Gannin/Sessions/`), a file, or lines of
    /// one (`Gannin/App/Updater.swift#L10-L24`). An empty path is the whole repo.
    struct Scope: Hashable, Sendable {
        let path: String
        let lines: ClosedRange<Int>?

        /// `path`, `path#L10`, `path#L10-L24` or `path:10-24`.
        init(_ text: String) {
            var text = text.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("/") { text.removeFirst() }
            var lines: ClosedRange<Int>?
            if let match = text.firstMatch(of: #/(?:#L|:)(\d+)(?:-L?(\d+))?$/#) {
                if let start = Int(match.1) {
                    let end = match.2.flatMap { Int($0) } ?? start
                    lines = min(start, end)...max(start, end)
                }
                text = String(text[..<match.range.lowerBound])
            }
            path = text
            self.lines = lines
        }

        init(path: String, lines: ClosedRange<Int>?) {
            self.path = path
            self.lines = lines
        }

        var isFolder: Bool { path.isEmpty || path.hasSuffix("/") }

        /// Whether a file (and, given, lines of it) falls within it. A file
        /// scope with lines covers the file whatever its lines when none are
        /// given, since code moves; the reviewer checks the lines.
        func covers(_ file: String, lines changed: ClosedRange<Int>? = nil) -> Bool {
            if path.isEmpty { return true }
            if path.hasSuffix("/") { return file.hasPrefix(path) }
            if file == path {
                guard let lines, let changed else { return true }
                return lines.overlaps(changed)
            }
            // A folder named without its slash.
            return file.hasPrefix(path + "/")
        }

        var text: String {
            guard let lines else { return path.isEmpty ? "the whole repo" : path }
            return lines.count == 1 ? "\(path)#L\(lines.lowerBound)" : "\(path)#L\(lines.lowerBound)-L\(lines.upperBound)"
        }
    }

    let document: HarnessDocument
    /// `owner/name`, or a name alone.
    let repo: String
    let scopes: [Scope]
    /// The commit line numbers were given at.
    let commit: String?
    /// The comment it came from.
    let source: URL?
    /// Who gave it.
    let author: String?

    var id: String { document.path }
    /// The rule, in a sentence: its summary, else its title.
    var rule: String { document.summary ?? document.title }
    /// Retired ones are kept for the history, not followed.
    var isActive: Bool { (document.status ?? "active").lowercased() != "retired" }

    init?(document: HarnessDocument) {
        guard document.kind == .learnings, let fields = document.frontMatter, let repo = fields["repo"]?.first, !repo.isEmpty else { return nil }
        self.document = document
        self.repo = repo
        let paths = fields["paths"] ?? fields["path"] ?? []
        scopes = paths.isEmpty ? [Scope(path: "", lines: nil)] : paths.map(Scope.init)
        commit = fields["commit"]?.first
        source = fields["source"]?.first.flatMap(URL.init(string:))
        author = fields["author"]?.first ?? document.owner
    }

    func applies(to target: String) -> Bool {
        let mine = repo.lowercased(), full = target.lowercased()
        return mine == full || mine == full.split(separator: "/").last.map(String.init)
    }

    func covers(_ file: String, lines: ClosedRange<Int>? = nil) -> Bool {
        scopes.contains { $0.covers(file, lines: lines) }
    }

    /// The text under `## Reason`, if it has one.
    var reason: String? {
        var lines: [String] = []
        var inReason = false
        for line in document.body.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                if inReason { break }
                inReason = line.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased() == "reason"
                continue
            }
            if inReason { lines.append(line) }
        }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Where it applies, in a line.
    var scopeText: String {
        let scopes = scopes.map(\.text).joined(separator: ", ")
        guard let commit, self.scopes.contains(where: { $0.lines != nil }) else { return scopes }
        return "\(scopes) (lines at \(commit.prefix(7)))"
    }
}

nonisolated extension HarnessIndex {
    /// The active learnings for a repo.
    func learnings(for repo: String) -> [HarnessLearning] {
        documents(.learnings).compactMap(HarnessLearning.init(document:)).filter { $0.isActive && $0.applies(to: repo) }
    }
}

nonisolated extension HarnessLearning {
    /// Most listed in a prompt or brief; the rest are in `learnings/`.
    static let promptLimit = 60

    /// The learnings as a list for claude: where each applies, the rule and
    /// its file in the harness.
    static func list(_ learnings: [HarnessLearning]) -> String {
        var lines = learnings.prefix(promptLimit).map { learning in
            "- \(learning.rule) Applies to \(learning.scopeText) in \(learning.repo). (`\(HarnessIndex.split(learning.document.path).path)`)"
        }
        if learnings.count > promptLimit {
            lines.append("- And \(learnings.count - promptLimit) more under `learnings/`.")
        }
        return lines.joined(separator: "\n")
    }

    /// What a reviewer is told about the learnings for the repos it reviews;
    /// nil when there are none.
    /// `listsApplied` for a PR review, whose JSON has `applied`.
    static func reviewInstructions(_ learnings: [HarnessLearning], listsApplied: Bool = true) -> String? {
        guard !learnings.isEmpty else { return nil }
        return """
            The team keeps learnings in the harness: rules and reasons people gave in earlier reviews, each scoped to a folder, a file or lines of a file (line numbers are as they were at the commit given, so the code may have moved). Here are those for this code; each file under `learnings/` has the reason in full.

            \(list(learnings))

            Work out which of these cover the files and lines the diff changes, read those in full, and follow them: don't raise as a finding what a learning says is deliberate, and don't suggest a change one rules out. When a finding rests on a learning, say which. If one looks stale (the code it's about has gone or changed past it), wrong for this change, or two contradict each other, say so in the summary rather than following it blindly.\(listsApplied ? " List every learning that shaped the review in `applied` (set out below)." : "")
            """
    }

    /// The `learnings` a PR review's JSON can end with: explanations people
    /// gave in the PR, for capturing.
    static let reviewJSONField = #""applied": [{"learning": "<its file, learnings/...>", "path": "<the file in the repo it bore on>", "line": <optional line in the new file>, "note": "<what it changed in this review: what you didn't raise, or did differently>", "concern": "<optional: why it may be stale or wrong here>"}], "learnings": [{"path": "<path in the repo, or a folder ending in />", "line": <optional first line>, "end_line": <optional last line>, "rule": "<the rule, in a sentence>", "reason": "<why, as the person said it>", "source": "<the comment's URL>", "author": "<their login>"}]"#

    static let reviewJSONInstructions = """
        In `applied`, list each of the team's learnings that shaped this review, where, and how; one you had doubts about goes in with a `concern`. Leave it out or give [] when none did. \
        In `learnings`, list explanations a person (not you, not a bot) gave in this PR's comments or review threads (the `gh api graphql` command below lists the threads) of why code is the way it is ("we do x because of y") that later reviews should know and that aren't already learnings in the harness. Scope each to the narrowest folder, file or lines it's about. Usually it's empty; leave it out or give [] then.
        """
}

/// A learning as the editor writes it.
struct HarnessLearningDraft: Hashable {
    init() {}

    /// An existing learning, to edit: everything it has, the quote from its
    /// Source section.
    init(learning: HarnessLearning) {
        let document = learning.document
        title = document.title
        repo = learning.repo
        paths = learning.scopes.filter { !$0.path.isEmpty }.map(\.text).joined(separator: "\n")
        commit = learning.commit ?? ""
        rule = learning.rule
        reason = learning.reason ?? ""
        source = learning.source?.absoluteString ?? ""
        author = learning.author ?? ""
        status = document.status ?? "active"
        issues = document.frontMatter?["issues"] ?? []
        var inSource = false
        var quoted: [String] = []
        for line in document.body.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                inSource = line.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased() == "source"
                continue
            }
            if inSource, line.hasPrefix(">") { quoted.append(String(line.dropFirst(line.hasPrefix("> ") ? 2 : 1))) }
        }
        quote = quoted.joined(separator: "\n")
    }

    var title = ""
    var repo = ""
    /// One scope a line.
    var paths = ""
    var commit = ""
    var rule = ""
    var reason = ""
    var source = ""
    /// The comment's words, quoted under Source.
    var quote = ""
    var author = ""
    var status = "active"
    var issues: [String] = []

    var scopeList: [String] {
        paths.split(whereSeparator: \.isNewline).flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// `learnings/<repo name>/<date>-<slug>.md`.
    var path: String {
        let name = repo.split(separator: "/").last.map(String.init) ?? ""
        let folder = HarnessDocumentDraft.slug(name)
        let slug = HarnessDocumentDraft.slug(title.isEmpty ? rule : title)
        return "learnings/\(folder == "untitled" ? "<repo>" : folder)/\(HarnessAuthoring.today)-\(slug).md"
    }

    var fileText: String {
        var text = "---\n---\n"
        text = HarnessFrontMatter.setting([
            ("type", .text("learning")),
            ("status", .text(status)),
            ("summary", .text(rule.split(whereSeparator: \.isNewline).joined(separator: " "))),
            ("repo", .text(repo)),
            ("paths", .list(scopeList)),
            ("commit", .text(commit)),
            ("source", .text(source)),
            ("author", .text(author)),
            ("issues", .list(issues)),
        ], in: text)
        var lines = [text.trimmingCharacters(in: .newlines), "", "# \(title.isEmpty ? rule : title)", "", "## Rule", "", rule.trimmingCharacters(in: .whitespacesAndNewlines), ""]
        let reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if !reason.isEmpty { lines += ["## Reason", "", reason, ""] }
        let quote = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        if !quote.isEmpty || !source.isEmpty {
            lines += ["## Source", ""]
            if !quote.isEmpty {
                let who = author.isEmpty || quote.hasPrefix("@") ? "" : "@\(author): "
                lines += quote.components(separatedBy: "\n").enumerated().map { "> \($0.offset == 0 ? who : "")\($0.element)" } + [""]
            }
            if !source.isEmpty { lines += [source, ""] }
        }
        return lines.joined(separator: "\n")
    }

    /// A draft from a comment: its words, who said it and where.
    static func from(comment body: String, author: String?, url: URL?, repo: String, path: String? = nil, line: Int? = nil, endLine: Int? = nil) -> Self {
        var draft = Self()
        draft.repo = repo
        draft.quote = body
        draft.author = author ?? ""
        draft.source = url?.absoluteString ?? ""
        if let path, !path.isEmpty {
            draft.paths = HarnessLearning.Scope(path: path, lines: line.map { $0...max($0, endLine ?? $0) }).text
        }
        return draft
    }

    /// `owner/name` from a GitHub URL for an issue, PR or comment on one.
    static func repo(of url: URL) -> String? {
        let parts = url.pathComponents.filter { $0 != "/" }
        return parts.count >= 2 ? "\(parts[0])/\(parts[1])" : nil
    }
}
