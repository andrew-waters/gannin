import Foundation

/// The org's harness: a repo of plans, requirements, findings and skills
/// kept beside the code, read from GitHub so
/// everyone in the org sees the same documents.
struct HarnessConfig: Codable, Hashable {
    /// `owner/name`.
    var repo: String
    /// The branch the harness is read from; nil for the repo's default.
    var branch: String?
    /// For a harness beside the primary one: the code repos it's for
    /// (`owner/name` or a name alone). Work in them runs in it; anything
    /// no other harness claims runs in the primary.
    var repos: [String]? = nil

    var name: String { repo.split(separator: "/").last.map(String.init) ?? repo }

    func covers(_ target: String) -> Bool {
        (repos ?? []).contains { repo in
            let lower = repo.lowercased(), full = target.lowercased()
            return lower == full || lower == full.split(separator: "/").last.map(String.init)
        }
    }
}

nonisolated extension HarnessIndex {
    /// A document path in a combined index: plain for the primary
    /// harness's, `owner/name:path` for another's.
    static func split(_ path: String) -> (repo: String?, path: String) {
        guard let colon = path.firstIndex(of: ":"), path[..<colon].contains("/") else { return (nil, path) }
        return (String(path[..<colon]), String(path[path.index(after: colon)...]))
    }
}

nonisolated extension HarnessDocument {
    /// The same document under `owner/name:path`, for a combined index.
    func prefixed(_ repo: String) -> HarnessDocument {
        HarnessDocument(
            path: "\(repo):\(path)", sha: sha, kind: kind, title: title, text: text, module: module, date: date, status: status,
            summary: summary, domains: domains, touches: touches, hasFrontMatter: hasFrontMatter, requirement: requirement,
            branch: branch, owner: owner, dependsOn: dependsOn, frontMatter: frontMatter, tasks: tasks, tasksDone: tasksDone,
            references: references
        )
    }

    /// The harness it's from in a combined index; nil for the primary.
    var harnessRepo: String? { HarnessIndex.split(path).repo }
}

/// What a document in the harness is, from where it sits.
nonisolated enum HarnessKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case plans = "Plans"
    case requirements = "Requirements"
    case findings = "Findings"
    case skills = "Skills"
    /// The team's prompts for Claude Code sessions (`HarnessPrompt`).
    case prompts = "Prompts"
    /// Rules and reasons people gave in review, scoped to the code they're
    /// about (`HarnessLearning`), for later reviews to follow.
    case learnings = "Learnings"
    /// Files committed from Ask sessions, a folder per conversation
    /// (`research/<date>-<id>/`), its README the document.
    case research = "Research"
    /// Design and Refine sessions' records, a folder per session
    /// (`refines/<date>-<slug>/`) with its screenshots beside the README,
    /// which is the document.
    case refines = "Refines"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .plans: "list.bullet.clipboard"
        case .requirements: "doc.text"
        case .findings: "magnifyingglass"
        case .skills: "wand.and.stars"
        case .prompts: "text.bubble"
        case .learnings: "lightbulb"
        case .research: "archivebox"
        case .refines: "pencil.and.outline"
        }
    }

    /// A front matter `type`: `plan`, `requirement`, `finding`, `skill`,
    /// `prompt`, `learning`, `research`, `refine`.
    init?(type: String) {
        guard let kind = Self.allCases.first(where: { $0.singular == type.lowercased() }) else { return nil }
        self = kind
    }

    var singular: String {
        switch self {
        case .plans: "plan"
        case .requirements: "requirement"
        case .findings: "finding"
        case .skills: "skill"
        case .prompts: "prompt"
        case .learnings: "learning"
        case .research: "research"
        case .refines: "refine"
        }
    }

    /// Committed by a session rather than written on the Harness page:
    /// research from an Ask's Files, refines when their session is agreed.
    var isRecord: Bool { self == .research || self == .refines }

    /// The harness's layout: `plans/` for plans (and, until they're moved,
    /// `requirements/<module>/plans/`), the rest of `requirements/` for
    /// requirements, `findings/`, `skills/`, `prompts/` and `learnings/`. READMEs and templates
    /// describe the layout rather than being part of it, except in
    /// `research/` and `refines/`, where each folder's README is its document.
    init?(path: String) {
        let parts = path.split(separator: "/")
        guard path.hasSuffix(".md"), let top = parts.first, let file = parts.last else { return nil }
        if top == "research" || top == "refines" {
            guard parts.count == 3, file == "README.md" else { return nil }
            self = top == "research" ? .research : .refines
            return
        }
        guard file != "README.md", !file.hasPrefix("_") else { return nil }
        switch top {
        case "plans": self = .plans
        case "requirements": self = parts.contains("plans") ? .plans : .requirements
        case "findings": self = .findings
        case "skills": self = .skills
        case "prompts": self = .prompts
        case "learnings": self = .learnings
        default: return nil
        }
    }
}

/// An issue a document refers to. `repo` is nil for the `PRD-123` shorthand,
/// which means the harness's usual issue repo.
nonisolated struct HarnessReference: Codable, Hashable, Sendable {
    let repo: String?
    let number: Int
    /// The document is about this issue (it's in the file name, or the
    /// header table's GitHub row) rather than just mentioning it.
    let isSubject: Bool
}

nonisolated struct HarnessDocument: Codable, Hashable, Identifiable, Sendable {
    let path: String
    /// The blob's SHA, so an unchanged file isn't fetched again.
    let sha: String
    let kind: HarnessKind
    let title: String
    let text: String
    /// `requirements/<module>/`, or for a learning its repo's folder,
    /// `learnings/<repo>/`.
    let module: String?
    /// From a `YYYY-MM-DD-` file or folder name.
    let date: Date?
    /// The front matter's `status`, else the header table's Status row.
    let status: String?
    /// From the front matter (`STANDARDS.md` in the harness); nil for a
    /// document from before it, or one indexed before Gannin read them.
    let summary: String?
    let domains: [String]?
    /// The repos (or `owner/repo:path`) a plan or finding changes.
    let touches: [String]?
    /// It has front matter, as the harness's standard asks.
    let hasFrontMatter: Bool?
    /// A plan's `requirement` (a path), `branch`, `owner` and `depends-on`
    /// (paths or issues).
    let requirement: String?
    let branch: String?
    let owner: String?
    let dependsOn: [String]?
    /// Every front matter field, each as a list of values, for filtering by
    /// whatever fields the harness's documents use.
    let frontMatter: [String: [String]]?
    /// Checkboxes: plans tick theirs off as work lands.
    let tasks: Int
    let tasksDone: Int
    let references: [HarnessReference]

    var id: String { path }
    /// What it's grouped under: its main domain, else its module folder.
    var area: String? { domains?.first ?? module }
    var fileName: String { path.split(separator: "/").last.map(String.init) ?? path }
    var subjects: [HarnessReference] { references.filter(\.isSubject) }

    /// Bumped when reading documents changes, so a cached index is read
    /// again rather than kept.
    static let parserVersion = 9

    /// The status in a word or two, for a table: an older document's
    /// sentence cut at its first clause.
    var shortStatus: String? {
        guard let label = statusLabel else { return nil }
        let clause = label.split(whereSeparator: { ".,;:(".contains($0) }).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? label
        return clause.count <= 16 ? clause : String(clause.prefix(15)).trimmingCharacters(in: .whitespaces) + "..."
    }

    /// It follows the harness's STANDARDS.md: front matter with a summary.
    var followsStandard: Bool { hasFrontMatter == true && summary != nil }

    /// The status as a label: `in-progress` as "In progress", and older
    /// documents' spellings brought together ("Complete" as "Done"), a
    /// paragraph cut to its start.
    var statusLabel: String? {
        guard var text = status?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        text = text.replacingOccurrences(of: "**", with: "")
        switch text.lowercased() {
        case "complete", "completed", "done": return "Done"
        case "not started": return "Not started"
        case "wont-fix", "won't fix": return "Won't fix"
        default: break
        }
        if text == text.lowercased(), !text.contains(" ") {
            text = text.replacingOccurrences(of: "-", with: " ")
        }
        text = text.prefix(1).uppercased() + text.dropFirst()
        return text.count <= 32 ? text : String(text.prefix(30)).trimmingCharacters(in: .whitespaces) + "..."
    }

    /// The body less its first heading when that's the title, which the
    /// document's page already shows.
    var bodyWithoutTitle: String {
        var lines = body.components(separatedBy: "\n")
        guard let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              lines[first].trimmingCharacters(in: .whitespaces) == "# \(title)" else { return body }
        lines.remove(at: first)
        return lines.joined(separator: "\n")
    }

    /// The body with the issues it names (`owner/repo#123`, `#123`,
    /// `PRD-123`) as links Gannin opens itself (`gannin-issue:`), outside
    /// code and existing links. `issuesRepo` is what the bare forms mean.
    func linkedBody(issuesRepo: String?) -> String {
        var inFence = false
        return bodyWithoutTitle.components(separatedBy: "\n").map { line in
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inFence.toggle()
                return line
            }
            return inFence ? line : Self.linkingIssues(in: line, issuesRepo: issuesRepo)
        }
        .joined(separator: "\n")
    }

    private static let issuePattern = try! NSRegularExpression(
        pattern: #"`[^`]*`|\[[^\]]*\]\([^)]*\)|<?https?://[^\s)>]+>?|(?<![\w/#])(?:([A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+))?#(\d+)\b|\b[Pp][Rr][Dd]-(\d+)\b"#
    )

    private static func linkingIssues(in line: String, issuesRepo: String?) -> String {
        guard line.contains("#") || line.range(of: "prd-", options: .caseInsensitive) != nil else { return line }
        let text = line as NSString
        var result = ""
        var last = 0
        for match in issuePattern.matches(in: line, range: NSRange(location: 0, length: text.length)) {
            let number = [2, 3].lazy.map { match.range(at: $0) }.first { $0.location != NSNotFound }.map { text.substring(with: $0) }
            let repo = match.range(at: 1).location != NSNotFound ? text.substring(with: match.range(at: 1)) : issuesRepo
            // Code, links and URLs are left as they are.
            guard let number, let repo else { continue }
            result += text.substring(with: NSRange(location: last, length: match.range.location - last))
            result += "[\(text.substring(with: match.range))](gannin-issue://\(repo)/\(number))"
            last = match.range.location + match.range.length
        }
        return result + text.substring(from: last)
    }

    /// The text without its front matter, for reading.
    var body: String {
        guard text.hasPrefix("---\n"), let end = text.range(of: "\n---\n", range: text.index(text.startIndex, offsetBy: 4)..<text.endIndex) else { return text }
        return String(text[end.upperBound...])
    }
}

/// One of the team's data files under `.gannin/`, as JSON text.
nonisolated struct HarnessDataFile: Codable, Hashable, Sendable {
    let path: String
    let sha: String
    let text: String

    /// `.gannin/views.json`, `.gannin/people/alex.json`: what the index keeps
    /// beside the documents.
    static func isData(_ path: String) -> Bool {
        path.hasPrefix(".gannin/") && path.hasSuffix(".json")
    }
}

/// An org's harness as last fetched.
nonisolated struct HarnessIndex: Codable, Sendable {
    /// `HarnessDocument.parserVersion` when indexed; nil before it was kept.
    var parserVersion: Int?
    let repo: String
    /// The branch asked for; nil for the default. An index made for one
    /// branch isn't shown for another.
    let requestedBranch: String?
    /// The branch read (the default's name, when that was asked for) and
    /// the commit it was indexed at.
    let branch: String
    let commit: String
    var fetchedAt: Date
    var documents: [HarnessDocument]
    /// The team's data under `.gannin/`; nil in an index cached before it
    /// was read, which is fetched again.
    var dataFiles: [HarnessDataFile]?

    func documents(_ kind: HarnessKind) -> [HarnessDocument] { documents.filter { $0.kind == kind } }

    func document(at path: String) -> HarnessDocument? { documents.first { $0.path == path } }

    /// The repo most references name, which `PRD-123` means.
    var issuesRepo: String? {
        let counts = Dictionary(grouping: documents.flatMap(\.references).compactMap(\.repo), by: { $0 }).mapValues(\.count)
        return counts.max { $0.value < $1.value }?.key
    }

    func repo(of reference: HarnessReference) -> String? { reference.repo ?? issuesRepo }

    /// Documents about or mentioning the issue, those about it first.
    func matches(repo: String, number: Int) -> [HarnessMatch] {
        let issuesRepo = issuesRepo
        return documents.compactMap { document in
            let refs = document.references.filter { ($0.repo ?? issuesRepo) == repo && $0.number == number }
            guard !refs.isEmpty else { return nil }
            return HarnessMatch(document: document, isSubject: refs.contains(where: \.isSubject))
        }
        .sorted { ($0.isSubject ? 0 : 1, $0.document.path) < ($1.isSubject ? 0 : 1, $1.document.path) }
    }

    func url(for document: HarnessDocument) -> URL? {
        let (other, path) = Self.split(document.path)
        // Another harness's, in a combined index: its default branch.
        return URL(string: "https://github.com/\(other ?? repo)/blob/\(other == nil ? branch : "HEAD")/\(path)")
    }

    /// The primary index with every other harness's documents added under
    /// `owner/name:` paths, for the views that look across them all.
    func combined(with others: [HarnessIndex]) -> HarnessIndex {
        guard !others.isEmpty else { return self }
        var index = self
        index.documents = documents + others.flatMap { other in other.documents.map { $0.prefixed(other.repo) } }
        return index
    }
}

nonisolated struct HarnessMatch: Identifiable, Sendable {
    let document: HarnessDocument
    let isSubject: Bool

    var id: String { document.path }
}

// MARK: - Reading a document

nonisolated extension HarnessDocument {
    init(path: String, sha: String, kind: HarnessKind, text: String) {
        self.path = path
        self.sha = sha
        self.text = text
        let parts = path.split(separator: "/").map(String.init)
        module = (parts.first == "requirements" || parts.first == "learnings") && parts.count > 2 ? parts[1] : nil
        date = parts.reversed().lazy.compactMap(Self.leadingDate).first

        let lines = text.components(separatedBy: .newlines)
        let front = HarnessFrontMatter.parse(lines)
        hasFrontMatter = front != nil
        // Its front matter says what it is, wherever it sits.
        self.kind = front?["type"]?.text.flatMap(HarnessKind.init(type:)) ?? kind
        summary = front?["summary"]?.text ?? front?["description"]?.text
        domains = front?["domains"]?.list
        touches = front?["touches"]?.list
        requirement = front?["requirement"]?.text
        branch = front?["branch"]?.text
        owner = front?["owner"]?.text
        dependsOn = front?["depends-on"]?.list
        frontMatter = front?.mapValues(\.list)
        title = lines.lazy.map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("# ") }
            .map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
            ?? Self.title(fromFile: parts.last ?? path)

        var status: String?
        var tasks = 0
        var done = 0
        var references: [HarnessReference] = []
        var inFrontMatter = lines.first == "---"
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if inFrontMatter, index > 0, trimmed == "---" { inFrontMatter = false }
            let cells = Self.tableCells(trimmed)
            let label = cells.first?.lowercased()
            if status == nil, label == "status", cells.count > 1 { status = cells[1] }
            let key = trimmed.split(separator: ":").first.map { $0.lowercased() }
            let isSubjectLine = ["github", "issue", "issues", "ticket"].contains(label ?? "")
                || (inFrontMatter && ["github", "issue", "issues"].contains(key ?? ""))
            references += Self.references(in: line, isSubject: isSubjectLine)
            let box = trimmed.drop { $0 == "-" || $0 == "*" || $0 == " " }
            if trimmed.hasPrefix("- [") || trimmed.hasPrefix("* [") {
                if box.hasPrefix("[ ]") { tasks += 1 }
                if box.hasPrefix("[x]") || box.hasPrefix("[X]") { tasks += 1; done += 1 }
            }
        }
        references += Self.references(in: parts.last ?? "", isSubject: true)
        for issue in front?["issues"]?.list ?? [] {
            references += Self.references(in: issue, isSubject: true)
        }
        self.status = front?["status"]?.text ?? status
        self.tasks = tasks
        tasksDone = done
        // One per issue, marked as the subject if any mention is.
        var merged: [String: HarnessReference] = [:]
        for reference in references {
            let key = "\(reference.repo ?? "")#\(reference.number)"
            if let existing = merged[key], existing.isSubject || !reference.isSubject { continue }
            merged[key] = reference
        }
        self.references = merged.values.sorted { ($0.repo ?? "", $0.number) < ($1.repo ?? "", $1.number) }
    }

    /// `owner/name#123`, GitHub issue and PR links, and `PRD-123`.
    static func references(in line: String, isSubject: Bool) -> [HarnessReference] {
        // Most lines name no issue; the patterns only run on those that might.
        let mayLink = line.contains("#") || line.contains("/issues/") || line.contains("/pull/")
        let mayPRD = line.range(of: "prd-", options: .caseInsensitive) != nil
        guard mayLink || mayPRD else { return [] }
        var found: [HarnessReference] = []
        for match in line.matches(of: /(?:https:\/\/github\.com\/)?([A-Za-z0-9][A-Za-z0-9-]*\/[A-Za-z0-9._-]+?)(?:#|\/issues\/|\/pull\/)(\d+)/) {
            if let number = Int(match.2) { found.append(HarnessReference(repo: String(match.1), number: number, isSubject: isSubject)) }
        }
        guard mayPRD else { return found }
        for match in line.matches(of: /\b[Pp][Rr][Dd]-(\d+)\b/) {
            if let number = Int(match.1) { found.append(HarnessReference(repo: nil, number: number, isSubject: isSubject)) }
        }
        return found
    }

    /// A table row's cells, trimmed; empty for anything else.
    private static func tableCells(_ line: String) -> [String] {
        guard line.hasPrefix("|") else { return [] }
        return line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func leadingDate(_ name: String) -> Date? {
        guard name.count >= 10 else { return nil }
        return try? Date(String(name.prefix(10)), strategy: .iso8601.year().month().day())
    }

    /// `2026-07-15-dwt-receipt.md` as "Dwt receipt".
    private static func title(fromFile name: String) -> String {
        var stem = name.hasSuffix(".md") ? String(name.dropLast(3)) : name
        if leadingDate(stem) != nil { stem = String(stem.dropFirst(10)) }
        let words = stem.split(whereSeparator: { $0 == "-" || $0 == "_" }).joined(separator: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}

/// A document's YAML front matter, as far as the harness's templates use it:
/// `key: value`, `[inline, lists]`, `- item` lists, and `>` or `|` blocks.
nonisolated enum HarnessFrontMatter {
    enum Value: Sendable {
        case text(String)
        case list([String])

        var text: String? {
            switch self {
            case .text(let text): text.isEmpty ? nil : text
            case .list(let items): items.first
            }
        }

        var list: [String] {
            switch self {
            case .text(let text): text.isEmpty ? [] : [text]
            case .list(let items): items
            }
        }
    }

    /// Nil when the text doesn't open with `---` or never closes it.
    static func parse(_ lines: [String]) -> [String: Value]? {
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        var fields: [String: Value] = [:]
        var key: String?
        var block: [String]?
        func flush() {
            if let key, let block { fields[key] = .text(block.filter { !$0.isEmpty }.joined(separator: " ")) }
            block = nil
        }
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" {
                flush()
                return fields
            }
            if block != nil {
                if line.hasPrefix(" ") || line.hasPrefix("\t") || trimmed.isEmpty {
                    block?.append(trimmed)
                    continue
                }
                flush()
            }
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if trimmed.hasPrefix("- "), let key {
                fields[key] = .list((fields[key].map { if case .list(let items) = $0 { items } else { [] } } ?? []) + [unquoted(String(trimmed.dropFirst(2)))])
                continue
            }
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" ") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.contains(" ") else { continue }
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            key = name
            if [">", "|", ">-", "|-"].contains(value) {
                block = []
            } else if value.hasPrefix("["), value.hasSuffix("]") {
                fields[name] = .list(value.dropFirst().dropLast().split(separator: ",").map { unquoted(String($0)) }.filter { !$0.isEmpty })
            } else {
                fields[name] = value.isEmpty ? .list([]) : .text(unquoted(value))
            }
        }
        return nil
    }

    /// The text with these top-level fields set (nil removes one): each
    /// replaces the field's line and anything belonging to it (list items,
    /// indented lines), a new one goes at the end, and a document with no
    /// front matter gets some. Everything else is left as it was.
    static func setting(_ updates: [(key: String, value: Value?)], in text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        if lines.first?.trimmingCharacters(in: .whitespaces) != "---" {
            lines = ["---", "---"] + lines
        }
        guard var end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return text }
        for (key, value) in updates {
            var index = 1
            var found: Int?
            while index < end {
                if lines[index].hasPrefix("\(key):") {
                    found = index
                    break
                }
                index += 1
            }
            let rendered = value.flatMap { render(key, $0) }
            if let found {
                // The field and what belongs to it, up to the next field.
                var last = found + 1
                while last < end, lines[last].isEmpty || lines[last].hasPrefix(" ") || lines[last].hasPrefix("\t") || lines[last].hasPrefix("- ") {
                    last += 1
                }
                lines.replaceSubrange(found..<last, with: rendered.map { [$0] } ?? [])
                end += (rendered == nil ? 0 : 1) - (last - found)
            } else if let rendered {
                lines.insert(rendered, at: end)
                end += 1
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func render(_ key: String, _ value: Value) -> String? {
        switch value {
        case .text(let text):
            let text = text.trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : "\(key): \(quoted(text))"
        case .list(let items):
            let items = items.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return items.isEmpty ? nil : "\(key): [\(items.map(quoted).joined(separator: ", "))]"
        }
    }

    /// Quoted when YAML would read it as something else.
    private static func quoted(_ text: String) -> String {
        let special = text.contains(": ") || text.contains(" #") || text.contains(",") || text.contains("\"")
            || text.first.map { "[]{}&*!|>'%@`#-?".contains($0) } ?? false
        return special ? "\"\(text.replacingOccurrences(of: "\"", with: "\\\""))\"" : text
    }

    private static func unquoted(_ text: String) -> String {
        let text = text.trimmingCharacters(in: .whitespaces)
        if text.count >= 2, let first = text.first, first == text.last, first == "\"" || first == "'" {
            return String(text.dropFirst().dropLast())
        }
        return text
    }
}
