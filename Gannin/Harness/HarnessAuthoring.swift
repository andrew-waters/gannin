import Foundation

/// What Claude is asked when it drafts a new harness document: the org's
/// own guidance for the kind (Settings › Harness, `OrgConfig.authoring`) or
/// Gannin's default, then what Gannin always adds: what's wanted, what's
/// written so far, the harness's guides as files, the existing documents
/// of that kind, and the JSON reply it reads. For plans it's the planning
/// session's first prompt instead.
enum HarnessAuthoring {
    /// `{{org}}`, `{{harness}}` and `{{today}}` in any kind's guidance.
    static func guidance(for kind: HarnessKind, config: OrgConfig, org: String) -> String {
        let text = config.authoring?[kind.singular].flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? defaultGuidance(kind)
        return fill(text, ["org": org, "harness": config.harness?.repo ?? "the harness", "today": today])
    }

    static func isCustom(_ kind: HarnessKind, config: OrgConfig) -> Bool {
        config.authoring?[kind.singular] != nil
    }

    static var today: String { Date.now.formatted(.iso8601.year().month().day()) }

    static func fill(_ text: String, _ values: [String: String]) -> String {
        values.reduce(text) { text, pair in text.replacingOccurrences(of: "{{\(pair.key)}}", with: pair.value) }
    }

    /// The placeholders the kind's guidance can use, for Settings.
    static func placeholders(_ kind: HarnessKind) -> [String] {
        kind == .plans
            ? ["{{org}}", "{{harness}}", "{{today}}", "{{topic}}", "{{plan}}", "{{docs}}", "{{assets}}", "{{starting_point}}"]
            : ["{{org}}", "{{harness}}", "{{today}}"]
    }

    static func defaultGuidance(_ kind: HarnessKind) -> String {
        switch kind {
        case .skills:
            """
            You're writing a Claude Code skill for {{org}}'s harness, {{harness}}: a reusable workflow an agent follows step by step.

            Give it a short kebab-case name and a one-line description that says what it does and when to use it, so an agent can tell from the description alone. Write the body as the harness's skills template does: Context (when and why to use it, and any arguments), Steps (concrete and in order, with the commands to run), and Rules (constraints and quality gates).

            Be specific to how this team works, as the harness's CLAUDE.md and STANDARDS.md describe. Don't invent tools, services or repos they don't mention; where you need something you don't know, leave a clearly marked TODO. Don't duplicate an existing skill: say how this one differs if they're close.
            """
        case .prompts:
            """
            You're writing a prompt for {{org}}'s Claude Code sessions, kept in the harness, {{harness}}. Gannin adds it to a session's first prompt when work on an issue, a PR review or a planning session starts, or sends it to a session already running.

            Write it as direct instructions to the agent: what to focus on, what to check, and what to deliver, in a few short paragraphs or a list. Gannin's own prompt already covers the issue, the worktrees and, for reviews, the JSON the review ends with, so don't repeat those or ask for another format. Use {{issue}}, {{title}} or {{repo}} where naming the issue or PR helps. Say which uses it suits (work, review, planning, ask, session) and which of the harness's skills it should bring, by name.
            """
        case .requirements:
            """
            You're writing a requirement for {{org}}'s harness, {{harness}}: what a feature must do, not how it's built.

            Follow STANDARDS.md and the requirements template: the problem and who has it, what the feature must do as numbered, testable statements, what's out of scope, and open questions. Keep it to what was asked for; mark guesses as open questions rather than stating them. Its status is draft unless I say otherwise.
            """
        case .findings:
            """
            You're writing up a finding for {{org}}'s harness, {{harness}}: an investigation and what it found.

            Follow STANDARDS.md and the findings template: the symptom and its impact, how it was investigated, the cause, the evidence (logs, queries, code references), and what should be done, with a severity of low, medium, high or critical. Its status is open unless I say otherwise. Keep facts and guesses apart.
            """
        case .learnings:
            """
            You're writing up a learning for {{org}}'s harness, {{harness}}: a rule or a reason a person gave in review ("we do x because of y"), so later reviews, Claude's included, follow it rather than asking again or suggesting what it rules out.

            Give it a short title, the rule in one sentence as its summary, the repo (`owner/name`) and the narrowest scope it applies to: folders ending in `/`, files, or lines of a file as `path#L10-L24`. Keep the reason in the person's own terms; don't add reasons they didn't give. If the comment doesn't make a rule clear, ask me rather than guess. If an existing learning already says it, or contradicts it, tell me which.
            """
        case .research:
            // Committed from an Ask's Files, never drafted.
            ""
        case .plans:
            """
            Let's plan "{{topic}}" together, here in the team's harness. Read STANDARDS.md and plans/_template.md first. {{starting_point}}

            I may share documents (specs, notes, emails, exports). They'll be in {{docs}}, and I'll tell you each time, with which ones may be committed. Only those may go into the harness, in {{assets}}, linked from the plan. Never commit, copy into the harness, or quote at length a document I haven't marked for committing: it may hold sensitive details. Summarise what you need from it in your own words.

            Ask what you need to know, one question at a time. When we agree, Gannin writes the plan as {{plan}}, following the standard, from what you've kept. Commit only the assets marked for committing, and only when I say so.
            """
        }
    }

    /// The harness's guides for the kind, by path, sent as files.
    static func guidePaths(_ kind: HarnessKind) -> [String] {
        let folder = kind == .plans ? "plans" : kind.rawValue.lowercased()
        return ["CLAUDE.md", "STANDARDS.md", "\(folder)/README.md", "\(folder)/_template.md"]
    }

    /// The whole ask: the guidance, what's wanted and written so far, the
    /// guides (written beside it) and the existing ones, and the reply.
    static func request(kind: HarnessKind, guidance: String, ask: String, current: String?, guides: [String], existing: [HarnessDocument]) -> String {
        var parts = [guidance]
        parts.append("What I want:\n\n\(ask.trimmingCharacters(in: .whitespacesAndNewlines))")
        if let current, !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("What's written so far, to improve on rather than start over:\n\n\(current)")
        }
        if !guides.isEmpty {
            parts.append("The harness's guides are in this folder, at the same paths: \(guides.map { "`\($0)`" }.joined(separator: ", ")). Read them first.")
        }
        if !existing.isEmpty {
            let list = existing.prefix(80).map { "- \($0.title) (`\($0.path)`)\($0.summary.map { ": \($0)" } ?? "")" }
            parts.append("The \(kind.rawValue.lowercased()) already in the harness:\n\n\(list.joined(separator: "\n"))")
        }
        parts.append("Reply with only JSON, no preamble: \(replyShape(kind)), plus \"message\": what you say to me. `body` is Markdown without front matter\(kind == .skills ? ", starting with its heading" : " or the title heading"); Gannin writes the front matter from the other fields.")
        return parts.joined(separator: "\n\n")
    }

    private static func replyShape(_ kind: HarnessKind) -> String {
        switch kind {
        case .skills: #"{"name": "kebab-case", "description": "one line", "repos": ["name"] or [] for all, "body": "..."}"#
        case .prompts: #"{"title": "...", "summary": "one line", "uses": ["work" | "review" | "planning" | "ask" | "session"], "skills": ["skill-name"], "body": "..."}"#
        case .findings: #"{"title": "...", "summary": "a sentence or two", "status": "open", "severity": "low" | "medium" | "high" | "critical", "domains": ["..."], "issues": ["owner/repo#123"], "body": "..."}"#
        case .learnings: #"{"title": "...", "summary": "the rule, in a sentence", "repos": ["owner/name"], "paths": ["folder/", "file", "file#L10-L24"], "reason": "why, in Markdown"}"#
        default: #"{"title": "...", "summary": "a sentence or two", "status": "draft", "domains": ["..."], "issues": ["owner/repo#123"], "body": "..."}"#
        }
    }

    /// Claude's draft: whichever fields the kind has.
    struct Reply: Decodable {
        var name: String?
        var title: String?
        var description: String?
        var summary: String?
        var status: String?
        var severity: String?
        var repos: [String]?
        var uses: [String]?
        var skills: [String]?
        /// A learning's scopes and reason.
        var paths: [String]?
        var reason: String?
        var domains: [String]?
        var issues: [String]?
        var body: String?
        /// What Claude says to you: questions, or what it did.
        var message: String?

        /// Whether it drafted anything, rather than only asking.
        var hasDraft: Bool {
            [name, title, description, summary, status, severity, body, reason].contains { $0 != nil }
                || [repos, uses, skills, paths, domains, issues].contains { $0 != nil }
        }
    }
}

/// A requirement or finding as the editor writes it: front matter as
/// STANDARDS.md has it, the title, then the body.
struct HarnessDocumentDraft {
    var kind: HarnessKind
    var title = ""
    var status = ""
    var severity = ""
    var summary = ""
    var domains: [String] = []
    var issues: [String] = []
    var body = ""

    var fileText: String {
        func list(_ items: [String]) -> String { "[\(items.joined(separator: ", "))]" }
        var lines = ["---", "type: \(kind.singular)"]
        if !status.isEmpty { lines.append("status: \(status)") }
        if kind == .findings, !severity.isEmpty { lines.append("severity: \(severity)") }
        if !summary.isEmpty { lines += ["summary: >", "  " + summary.split(whereSeparator: \.isNewline).joined(separator: " ")] }
        if !domains.isEmpty { lines.append("domains: \(list(domains))") }
        if !issues.isEmpty { lines.append("issues: \(list(issues))") }
        lines += ["---", "", "# \(title)", "", body.trimmingCharacters(in: .whitespacesAndNewlines), ""]
        return lines.joined(separator: "\n")
    }

    /// The statuses a kind's documents take, as saved (slugs).
    static func statuses(_ kind: HarnessKind) -> [String] {
        switch kind {
        case .findings: ["open", "investigating", "fixing", "fixed", "wont-fix"]
        case .skills, .prompts: ["active", "draft", "archived"]
        case .learnings: ["active", "retired"]
        case .research: []
        case .plans, .requirements: ["draft", "in-progress", "done"]
        }
    }

    /// A status slug as shown: `in-progress` as "In progress".
    static func statusTitle(_ slug: String) -> String {
        if slug == "wont-fix" { return "Won't fix" }
        let words = slug.replacingOccurrences(of: "-", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    static let severities = ["low", "medium", "high", "critical"]

    /// A template's body, less its front matter and title heading, for a
    /// new document to start from.
    static func templateBody(_ text: String?) -> String? {
        guard var text else { return nil }
        if text.hasPrefix("---\n"), let end = text.range(of: "\n---\n", range: text.index(text.startIndex, offsetBy: 4)..<text.endIndex) {
            text = String(text[end.upperBound...])
        }
        var lines = text.components(separatedBy: "\n")
        if let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }), lines[first].hasPrefix("# ") {
            lines.remove(at: first)
        }
        let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }

    static func slug(_ text: String) -> String {
        let words = String(text.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : " " }).split(separator: " ")
        var slug = ""
        for word in words {
            let next = slug.isEmpty ? String(word) : "\(slug)-\(word)"
            if next.count > 50 { break }
            slug = next
        }
        return slug.isEmpty ? "untitled" : slug
    }
}

extension HarnessStore {
    /// The guides for a kind at the indexed commit, those that exist.
    func guides(for kind: HarnessKind, org: String, setup: HarnessConfig) async -> [String: String] {
        guard let commit = index(for: org, setup)?.commit,
              let texts = try? await files(setup: setup, at: commit, paths: HarnessAuthoring.guidePaths(kind)) else { return [:] }
        return texts.compactMapValues { $0 }
    }
}
