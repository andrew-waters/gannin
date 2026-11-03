import Foundation

/// Splits the lines of a Vue single-file component into runs, each in the
/// highlight.js language its section is written in.
nonisolated enum VueSections {
    /// The languages a run can be in, all of which the bundled highlighter has.
    static let languages: Set<String> = ["xml", "javascript", "typescript", "css", "scss", "less"]

    struct Run: Equatable {
        let language: String
        var code: [DiffHighlighter.Code]
    }

    private enum Section {
        case script(String)
        case style(String)

        var language: String {
            switch self {
            case .script(let language), .style(let language): language
            }
        }

        var closing: String {
            switch self {
            case .script: "</script"
            case .style: "</style"
            }
        }
    }

    /// The runs of one side of a hunk. Tag lines are markup. A hunk shows only a
    /// few lines of context, so one can start inside a section whose opening
    /// tag it doesn't have: lines before a first closing tag are taken to be
    /// that section, in its commonest language. A side with no section tag at
    /// all, the usual case for an edit in the middle of a block, is guessed
    /// from its content as a whole (`guess`).
    static func runs(_ code: [DiffHighlighter.Code]) -> [Run] {
        var languages = [String](repeating: "xml", count: code.count)
        var section: Section?
        var seenTag = false
        for (index, line) in code.enumerated() {
            let text = line.text.trimmingCharacters(in: .whitespaces)
            if let open = section {
                if text.contains(open.closing) {
                    section = nil
                } else {
                    languages[index] = open.language
                }
                seenTag = true
            } else if let opened = opening(text) {
                section = opened
                seenTag = true
            } else if !seenTag, let orphan = closing(text) {
                backfill(&languages, before: index, with: orphan.language)
                seenTag = true
            }
        }
        if !seenTag { languages = [String](repeating: guess(code), count: code.count) }
        var runs: [Run] = []
        for (index, line) in code.enumerated() {
            if runs.last?.language == languages[index] {
                runs[runs.count - 1].code.append(line)
            } else {
                runs.append(Run(language: languages[index], code: [line]))
            }
        }
        return runs
    }

    private static let scriptWords: Set<String> = [
        "const", "let", "var", "import", "export", "function", "return", "if", "else", "for", "while",
        "class", "await", "async", "new", "this", "switch", "case",
    ]

    /// The language for lines that carry no section tag: markup when any line
    /// looks like it, else script when any line has a JavaScript marker, else
    /// style when any line is a `property: value;` or a selector. Anything
    /// else stays markup. Script wins over style so that code with an object
    /// literal isn't taken for a declaration.
    static func guess(_ code: [DiffHighlighter.Code]) -> String {
        let lines = code.map { $0.text.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let markup = lines.contains {
            $0.hasPrefix("<") || $0.contains("</") || $0.contains("/>") || $0.contains("=\"") || $0.contains("='")
        }
        if markup { return "xml" }
        let script = lines.contains { line in
            line.contains("=>") || line.contains(" = ")
                || line.split(whereSeparator: { !$0.isLetter }).contains { scriptWords.contains(String($0)) }
        }
        if script { return "javascript" }
        let style = lines.contains {
            $0.wholeMatch(of: /-{0,2}[a-zA-Z][-\w]*\s*:\s*[^={}]+;/) != nil
                || $0.wholeMatch(of: /[.#&@:\[\]\w>~+*, -]+\{/) != nil
        }
        return style ? "css" : "xml"
    }

    private static func backfill(_ languages: inout [String], before index: Int, with language: String) {
        for earlier in 0..<index { languages[earlier] = language }
    }

    /// The section a line opens, when its tag is complete on the line and the
    /// section carries on past it. A language highlight.js can't colour is
    /// still a section, left as plain markup, so its closing tag isn't taken
    /// for the end of a section the hunk started inside.
    private static func opening(_ text: String) -> Section? {
        guard text.contains(">") else { return nil }
        if text.hasPrefix("<script"), !text.contains("</script") {
            switch lang(in: text) {
            case "ts", "tsx", "typescript": return .script("typescript")
            case nil, "js", "jsx", "javascript": return .script("javascript")
            default: return .script("xml")
            }
        }
        if text.hasPrefix("<style"), !text.contains("</style") {
            switch lang(in: text) {
            case "scss", "sass": return .style("scss")
            case "less": return .style("less")
            case nil, "css", "postcss": return .style("css")
            default: return .style("xml")
            }
        }
        return nil
    }

    private static func closing(_ text: String) -> Section? {
        if text.hasPrefix("</script") { return .script("javascript") }
        if text.hasPrefix("</style") { return .style("css") }
        return nil
    }

    private static func lang(in tag: String) -> String? {
        guard let range = tag.range(of: "lang=") else { return nil }
        let rest = tag[range.upperBound...]
        guard let quote = rest.first, quote == "\"" || quote == "'" else { return nil }
        let value = rest.dropFirst()
        guard let end = value.firstIndex(of: quote) else { return nil }
        return String(value[..<end]).lowercased()
    }
}
