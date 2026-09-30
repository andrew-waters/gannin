import Foundation

/// The org's harness: a repo of plans, requirements, findings and skills
/// kept beside the code (Ctrl Hub's `ctrl-hub/harness`), read from GitHub so
/// everyone in the org sees the same documents.
struct HarnessConfig: Codable, Hashable {
    /// `owner/name`.
    var repo: String
    /// The branch the harness is read from; nil for the repo's default.
    var branch: String?
}

/// What a document in the harness is, from where it sits.
nonisolated enum HarnessKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case plans = "Plans"
    case requirements = "Requirements"
    case findings = "Findings"
    case skills = "Skills"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .plans: "list.bullet.clipboard"
        case .requirements: "doc.text"
        case .findings: "magnifyingglass"
        case .skills: "wand.and.stars"
        }
    }

    /// A front matter `type`: `plan`, `requirement`, `finding`, `skill`.
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
        }
    }

    /// The harness's layout: `plans/` for plans (and, until they're moved,
    /// `requirements/<module>/plans/`), the rest of `requirements/` for
    /// requirements, `findings/` and `skills/`. READMEs and templates
    /// describe the layout rather than being part of it.
    init?(path: String) {
        let parts = path.split(separator: "/")
        guard path.hasSuffix(".md"), let top = parts.first, let file = parts.last,
              file != "README.md", !file.hasPrefix("_") else { return nil }
        switch top {
        case "plans": self = .plans
        case "requirements": self = parts.contains("plans") ? .plans : .requirements
        case "findings": self = .findings
        case "skills": self = .skills
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
    /// `requirements/<module>/`.
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
    static let parserVersion = 3

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

    /// `.gannin/views.json`, `.gannin/people/ian.json`: what the index keeps
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
    let documents: [HarnessDocument]
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
        URL(string: "https://github.com/\(repo)/blob/\(branch)/\(document.path)")
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
        module = parts.first == "requirements" && parts.count > 2 ? parts[1] : nil
        date = parts.reversed().lazy.compactMap(Self.leadingDate).first

        let lines = text.components(separatedBy: .newlines)
        let front = HarnessFrontMatter.parse(lines)
        hasFrontMatter = front != nil
        // Its front matter says what it is, wherever it sits.
        self.kind = front?["type"]?.text.flatMap(HarnessKind.init(type:)) ?? kind
        summary = front?["summary"]?.text ?? front?["description"]?.text
        domains = front?["domains"]?.list
        touches = front?["touches"]?.list
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

    private static func unquoted(_ text: String) -> String {
        let text = text.trimmingCharacters(in: .whitespaces)
        if text.count >= 2, let first = text.first, first == text.last, first == "\"" || first == "'" {
            return String(text.dropFirst().dropLast())
        }
        return text
    }
}
