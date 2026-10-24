import Foundation

/// One of the team's specialists, `specialists/<name>.md` in the harness: an
/// agent a workflow step names (andrew-waters/gannin#466). The body is its
/// soul, who it is and what it looks for, told to the agent before
/// anything else; the front matter gives its defaults, which a step can
/// override: `provider` (`claude-code`, or a one-shot CLI such as `junie`),
/// `model` and `focus`. One with prose only still loads.
nonisolated struct HarnessSpecialist: Identifiable, Hashable, Sendable {
    let path: String
    /// The front matter's `name`, else the file's name less `.md`: what a
    /// workflow step names it by.
    let name: String
    let title: String
    let summary: String?
    let provider: String?
    let model: String?
    let focus: String?
    let soul: String
    /// Front matter fields Gannin doesn't edit, kept as they were.
    let otherFields: [String: [String]]

    var id: String { path }

    static let folder = "specialists"

    static let knownFields: Set<String> = ["type", "summary", "description", "name", "provider", "model", "focus"]

    init?(document: HarnessDocument) {
        guard document.kind == .specialists else { return nil }
        let front = document.frontMatter ?? [:]
        func field(_ key: String) -> String? {
            front[key]?.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        }
        path = document.path
        name = field("name") ?? Self.stem(document.fileName)
        title = document.title
        summary = document.summary
        provider = field("provider")
        model = field("model")
        focus = field("focus")
        soul = document.bodyWithoutTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        otherFields = front.filter { !Self.knownFields.contains($0.key) }
    }

    init(path: String, name: String, title: String, summary: String?, provider: String?, model: String?, focus: String?, soul: String, otherFields: [String: [String]] = [:]) {
        self.path = path
        self.name = name
        self.title = title
        self.summary = summary
        self.provider = provider
        self.model = model
        self.focus = focus
        self.soul = soul
        self.otherFields = otherFields
    }

    /// The file as committed: front matter, the title, then the soul.
    var fileText: String {
        func line(_ text: String) -> String { text.split(whereSeparator: \.isNewline).joined(separator: " ") }
        var lines = ["---", "type: specialist", "name: \(name)"]
        if let summary, !summary.isEmpty { lines += ["summary: >", "  " + line(summary)] }
        if let provider { lines.append("provider: \(provider)") }
        if let model { lines.append("model: \(model)") }
        if let focus { lines += ["focus: >", "  " + line(focus)] }
        for (key, values) in otherFields.sorted(by: { $0.key < $1.key }) {
            lines.append(values.count == 1 ? "\(key): \(values[0])" : "\(key): [\(values.joined(separator: ", "))]")
        }
        lines += ["---", "", "# \(title)", "", soul.trimmingCharacters(in: .whitespacesAndNewlines), ""]
        return lines.joined(separator: "\n")
    }

    /// What the agent is told first: who it is, then the step's focus (or
    /// its own).
    func instructions(focus stepFocus: String?) -> String {
        var parts = ["You are \(title), one of the team's specialists. This is who you are and what you look for:\n\n\(soul)"]
        if let focus = Self.focus(step: stepFocus, specialist: focus) { parts.append("Your focus for this step: \(focus)") }
        return parts.joined(separator: "\n\n")
    }

    /// The step's focus, else the specialist's.
    static func focus(step: String?, specialist: String?) -> String? {
        step?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? specialist
    }

    /// `security-reviewer` from `Security reviewer`.
    static func fileName(for title: String) -> String {
        let name = HarnessPrompt.fileName(for: title)
        return name == "prompt" ? "specialist" : name
    }

    private static func stem(_ file: String) -> String {
        file.hasSuffix(".md") ? String(file.dropLast(3)) : file
    }
}

extension HarnessIndex {
    /// The harness's specialists by lower-cased name.
    nonisolated var specialists: [String: HarnessSpecialist] {
        Dictionary(documents(.specialists).compactMap(HarnessSpecialist.init(document:)).map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
    }
}

private extension String {
    nonisolated var nonEmpty: String? { isEmpty ? nil : self }
}
