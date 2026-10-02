import Foundation

/// Where a prompt in the harness is offered: starting a session on an
/// issue, a review of a PR (or of a session's changes), a planning session,
/// or sent to a session already running, from the menu under its terminal.
nonisolated enum PromptUse: String, CaseIterable, Codable, Identifiable, Sendable {
    case work
    case review
    case planning
    case session

    var id: Self { self }

    var label: String {
        switch self {
        case .work: "Work on an issue"
        case .review: "Reviews"
        case .planning: "Planning"
        case .session: "In a session"
        }
    }
}

/// One of the team's prompts, `prompts/<name>.md` in the harness: front
/// matter saying where it's offered, whether it's picked by default (and
/// for which repos), and the skills it brings; the body is what claude is
/// told. `{{issue}}`, `{{title}}`, `{{url}}`, `{{repo}}`, `{{number}}` and
/// `{{branch}}` are filled in.
nonisolated struct HarnessPrompt: Identifiable, Hashable, Sendable {
    let path: String
    /// The file's name less `.md`.
    let name: String
    let title: String
    let summary: String?
    /// Where it's offered; every use when the front matter names none.
    let uses: [PromptUse]
    /// Ticked when a session for one of its uses starts.
    let isDefault: Bool
    /// The repos it's the default for (`api` or `owner/api`); any when
    /// empty. A default for the repo replaces the org's general ones.
    let repos: [String]
    /// The skills it brings, by name.
    let skills: [String]
    let body: String
    /// Front matter fields Gannin doesn't edit, kept as they were.
    let otherFields: [String: [String]]

    var id: String { path }

    static let folder = "prompts"

    static let knownFields: Set<String> = ["type", "summary", "description", "use", "default", "repos", "skills"]

    init?(document: HarnessDocument) {
        guard document.kind == .prompts else { return nil }
        let front = document.frontMatter ?? [:]
        path = document.path
        name = Self.stem(document.fileName)
        title = document.title
        summary = document.summary
        let uses = (front["use"] ?? []).compactMap { PromptUse(rawValue: $0.lowercased()) }
        self.uses = uses.isEmpty ? PromptUse.allCases : uses
        isDefault = ["true", "yes"].contains(front["default"]?.first?.lowercased() ?? "")
        repos = (front["repos"] ?? []).filter { $0.lowercased() != "all" }
        skills = front["skills"] ?? []
        body = document.bodyWithoutTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        otherFields = front.filter { !Self.knownFields.contains($0.key) }
    }

    init(path: String, title: String, summary: String?, uses: [PromptUse], isDefault: Bool, repos: [String], skills: [String], body: String, otherFields: [String: [String]] = [:]) {
        self.path = path
        name = Self.stem(path.split(separator: "/").last.map(String.init) ?? path)
        self.title = title
        self.summary = summary
        self.uses = uses
        self.isDefault = isDefault
        self.repos = repos
        self.skills = skills
        self.body = body
        self.otherFields = otherFields
    }

    func isOffered(for use: PromptUse) -> Bool { uses.contains(use) }

    /// Whether it names one of the repos, by `owner/name` or name alone.
    func isFor(any targets: [String]) -> Bool {
        repos.contains { repo in
            targets.contains { target in
                let lower = repo.lowercased(), full = target.lowercased()
                return lower == full || lower == full.split(separator: "/").last.map(String.init)
            }
        }
    }

    /// The body with the placeholders filled in.
    func filled(_ values: [String: String]) -> String {
        values.reduce(body) { text, pair in text.replacingOccurrences(of: "{{\(pair.key)}}", with: pair.value) }
    }

    /// The file as committed: front matter, the title, then the body.
    var fileText: String {
        func list(_ items: [String]) -> String { "[\(items.joined(separator: ", "))]" }
        var lines = ["---", "type: prompt"]
        if let summary, !summary.isEmpty { lines += ["summary: >", "  " + summary.split(whereSeparator: \.isNewline).joined(separator: " ")] }
        // Every use is the default, so it's left out then.
        if Set(uses) != Set(PromptUse.allCases) { lines.append("use: \(list(uses.map(\.rawValue)))") }
        if isDefault { lines.append("default: true") }
        if !repos.isEmpty { lines.append("repos: \(list(repos))") }
        if !skills.isEmpty { lines.append("skills: \(list(skills))") }
        for (key, values) in otherFields.sorted(by: { $0.key < $1.key }) {
            lines.append(values.count == 1 ? "\(key): \(values[0])" : "\(key): \(list(values))")
        }
        lines += ["---", "", "# \(title)", "", body.trimmingCharacters(in: .whitespacesAndNewlines), ""]
        return lines.joined(separator: "\n")
    }

    /// `security-review` from `Security review`.
    static func fileName(for title: String) -> String {
        let words = String(title.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : " " }).split(separator: " ")
        let name = words.joined(separator: "-")
        return name.isEmpty ? "prompt" : name
    }

    private static func stem(_ file: String) -> String {
        file.hasSuffix(".md") ? String(file.dropLast(3)) : file
    }
}

/// A skill in the harness, `skills/<name>.md` or `skills/<name>/SKILL.md`,
/// for a session to be told to use.
nonisolated struct HarnessSkill: Identifiable, Hashable, Sendable {
    let path: String
    let name: String
    let summary: String?

    var id: String { path }

    init?(document: HarnessDocument) {
        guard document.kind == .skills else { return nil }
        path = document.path
        let parts = document.path.split(separator: "/").map(String.init)
        let file = parts.last ?? document.path
        // A folder skill is named by its folder.
        let stem = file == "SKILL.md" && parts.count > 1 ? parts[parts.count - 2] : (file.hasSuffix(".md") ? String(file.dropLast(3)) : file)
        name = document.frontMatter?["name"]?.first ?? stem
        summary = document.summary
    }
}

/// What's picked when a session starts: prompts and skills by path, and a
/// note of your own for this one.
nonisolated struct PromptChoice: Hashable, Sendable {
    var prompts: Set<String> = []
    var skills: Set<String> = []
    var note = ""
}

/// The org's prompts and skills from its harness index.
nonisolated struct HarnessPromptLibrary: Sendable {
    let prompts: [HarnessPrompt]
    let skills: [HarnessSkill]

    init(index: HarnessIndex?) {
        prompts = (index?.documents(.prompts) ?? []).compactMap(HarnessPrompt.init(document:))
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        skills = (index?.documents(.skills) ?? []).compactMap(HarnessSkill.init(document:))
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var isEmpty: Bool { prompts.isEmpty && skills.isEmpty }

    func offered(for use: PromptUse) -> [HarnessPrompt] { prompts.filter { $0.isOffered(for: use) } }

    /// Whether starting a session for `use` has anything to pick.
    func hasChoices(for use: PromptUse) -> Bool { !offered(for: use).isEmpty || !skills.isEmpty }

    func skill(named name: String) -> HarnessSkill? {
        skills.first { $0.name.lowercased() == name.lowercased() } ?? skills.first { $0.path == name }
    }

    /// What's ticked at first: the defaults for the repos when there are
    /// any, else the org's general defaults, with the skills they bring.
    func defaults(for use: PromptUse, repos: [String]) -> PromptChoice {
        let offered = offered(for: use).filter(\.isDefault)
        let forRepos = offered.filter { $0.isFor(any: repos) }
        let picked = forRepos.isEmpty ? offered.filter(\.repos.isEmpty) : forRepos
        return PromptChoice(
            prompts: Set(picked.map(\.path)),
            skills: Set(picked.flatMap(\.skills).compactMap { skill(named: $0)?.path })
        )
    }

    /// What claude is told besides Gannin's own prompt: each prompt picked,
    /// the skills to use, and the note. Nil when nothing's picked.
    func instructions(for choice: PromptChoice, values: [String: String]) -> String? {
        var parts: [String] = []
        for prompt in prompts where choice.prompts.contains(prompt.path) {
            parts.append("From the team's prompt \"\(prompt.title)\" (`\(prompt.path)` in the harness):\n\n\(prompt.filled(values))")
        }
        let picked = skills.filter { choice.skills.contains($0.path) }
        if !picked.isEmpty {
            parts.append((["Use these skills from the harness: read each one before you start, and follow it where it applies."]
                + picked.map { "- `\($0.path)` (\($0.name))\($0.summary.map { ": \($0)" } ?? "")" }).joined(separator: "\n"))
        }
        let note = choice.note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty { parts.append(note) }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// A prompt sent to a running session: its text and its skills.
    func message(for prompt: HarnessPrompt, values: [String: String]) -> String {
        instructions(for: PromptChoice(prompts: [prompt.path], skills: Set(prompt.skills.compactMap { skill(named: $0)?.path })), values: values)
            ?? prompt.filled(values)
    }

    /// The placeholders' values for an issue or PR.
    static func values(reference: String, title: String, url: URL?, repo: String, number: Int, branch: String?) -> [String: String] {
        var values = ["issue": reference, "pr": reference, "title": title, "repo": repo, "number": "\(number)"]
        if let url { values["url"] = url.absoluteString }
        if let branch { values["branch"] = branch }
        return values
    }
}
