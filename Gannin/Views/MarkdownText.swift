import SwiftUI

/// Lightweight markdown renderer for issue and PR bodies, and for the
/// harness's documents.
///
/// Splits the source into block-level chunks (headings, list items, code
/// fences, tables, paragraphs) and renders each as its own row. Inline formatting
/// (bold, italic, code spans, links) is handled by `AttributedString(markdown:)`.
///
/// Given a `reading` size it lays a document out for reading at length, as
/// Safari's Reader and Apple's documentation do: a larger body with room
/// between lines and paragraphs, a heading scale with space above each,
/// hanging indents for nested lists, code that scrolls rather than wraps,
/// and `##` sections that fold (in `collapsed`, by block index) under a
/// chevron. Headings carry `anchor(_:)` ids for an outline to scroll to.
struct MarkdownText: View {
    let source: String
    /// A single line break is a space, as in a Markdown file wrapped at a
    /// width (the harness's documents), rather than a break, as GitHub
    /// shows issue and PR bodies. A line ending in two spaces or a
    /// backslash still breaks.
    var reflows = false
    /// The body size for reading a document; nil for the compact style.
    var reading: CGFloat? = nil
    /// Folded `##` sections, by their heading's block index.
    var collapsed: Binding<Set<Int>>? = nil

    var body: some View {
        let blocks = Self.blocks(source, reflows: reflows)
        Group {
            if let size = reading {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(visible(blocks), id: \.offset) { index, block in
                        documentView(block, index: index, size: size)
                            .padding(.top, index == 0 ? 0 : spacing(before: block, after: index > 0 ? blocks[index - 1] : nil, size: size))
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        view(for: block)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    /// The scroll id of the heading at block `index`.
    static func anchor(_ index: Int) -> String { "markdown-heading-\(index)" }

    /// Headings down to `###`, for an outline: block index, level and text.
    static func outline(_ source: String, reflows: Bool) -> [(index: Int, level: Int, text: String)] {
        blocks(source, reflows: reflows).enumerated().compactMap { index, block in
            if case .heading(let level, let text) = block, level <= 3 { return (index, level, plain(text)) }
            return nil
        }
    }

    /// The indexes of `##` (and `#`) headings, the sections that fold.
    static func foldable(_ source: String, reflows: Bool) -> [Int] {
        blocks(source, reflows: reflows).enumerated().compactMap { index, block in
            if case .heading(let level, _) = block, level <= 2 { return index }
            return nil
        }
    }

    /// The `##` section a block sits in, by its heading's index.
    static func section(containing index: Int, _ source: String, reflows: Bool) -> Int? {
        foldable(source, reflows: reflows).last { $0 <= index }
    }

    // MARK: Parsing

    private enum Block {
        case heading(level: Int, text: String)
        /// `indent` is the nesting depth, from 0.
        case bullet(text: String, checked: Bool?, indent: Int)
        case ordered(number: String, text: String, indent: Int)
        case code(text: String)
        /// The header row first.
        case table(rows: [[String]])
        case paragraph(text: String)
        /// `<details>` with its `<summary>`: what's inside, as Markdown, folds.
        case details(summary: String, body: String)
        /// `---`, `***` or `___` on a line of its own.
        case rule
    }

    private static func blocks(_ source: String, reflows: Bool) -> [Block] {
        var result: [Block] = []
        var paragraph: [String] = []
        var code: [String] = []
        var table: [[String]] = []
        var inCode = false

        func flushTable() {
            if !table.isEmpty { result.append(.table(rows: table)) }
            table.removeAll()
        }

        func flushParagraph() {
            let joined = join(paragraph, reflows: reflows)
            if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(.paragraph(text: joined))
            }
            paragraph.removeAll()
        }

        var details: (summary: String?, lines: [String], depth: Int)?

        for rawLine in strippingHTMLComments(source).components(separatedBy: .newlines) {
            let rawTrimmed = rawLine.trimmingCharacters(in: .whitespaces)
            // Inside a <details>: gather it whole, nested ones and all.
            if var open = details, !inCode {
                let opens = rawTrimmed.ranges(of: /(?i)<details\b/).count
                let closes = rawTrimmed.ranges(of: /(?i)<\/details>/).count
                open.depth += opens - closes
                var line = rawLine
                if open.summary == nil, let summary = Self.summary(in: line) {
                    open.summary = summary.text
                    line = summary.rest
                }
                if open.depth <= 0 {
                    line = line.replacing(/(?i)<\/details>/, with: "")
                    open.lines.append(line)
                    result.append(.details(summary: open.summary ?? "Details", body: open.lines.joined(separator: "\n")))
                    details = nil
                } else {
                    open.lines.append(line)
                    details = open
                }
                continue
            }
            if !inCode, rawTrimmed.range(of: "<details", options: .caseInsensitive) != nil, rawTrimmed.lowercased().hasPrefix("<details") {
                flushParagraph()
                flushTable()
                var rest = String(rawTrimmed.drop { $0 != ">" }.dropFirst())
                var summary: String?
                if let found = Self.summary(in: rest) {
                    summary = found.text
                    rest = found.rest
                }
                let closes = rest.range(of: "</details>", options: .caseInsensitive) != nil
                if closes {
                    result.append(.details(summary: summary ?? "Details", body: rest.replacing(/(?i)<\/details>/, with: "")))
                } else {
                    details = (summary, [rest], 1)
                }
                continue
            }
            let line = inCode ? rawLine : Self.markdown(fromHTML: rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if inCode {
                if trimmed.hasPrefix("```") {
                    result.append(.code(text: code.joined(separator: "\n")))
                    code.removeAll()
                    inCode = false
                } else {
                    code.append(line)
                }
                continue
            }
            if trimmed.hasPrefix("|") {
                flushParagraph()
                let cells = tableCells(trimmed)
                // The |---|:---:| row under the header only sets alignment.
                if !cells.allSatisfy({ $0.wholeMatch(of: /:?-+:?/) != nil }) { table.append(cells) }
                continue
            }
            flushTable()
            // Two spaces (or a tab) a level, as GitHub nests lists.
            let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) } / 2
            if trimmed.hasPrefix("```") {
                flushParagraph()
                inCode = true
            } else if trimmed.isEmpty {
                flushParagraph()
            } else if trimmed.count >= 3, ["-", "*", "_"].contains(where: { mark in trimmed.allSatisfy { String($0) == mark || $0 == " " } }),
                      trimmed.filter({ $0 != " " }).count >= 3 {
                flushParagraph()
                result.append(.rule)
            } else if let (level, text) = heading(trimmed) {
                flushParagraph()
                result.append(.heading(level: level, text: text))
            } else if let (text, checked) = bullet(trimmed) {
                flushParagraph()
                result.append(.bullet(text: text, checked: checked, indent: indent))
            } else if let (number, text) = ordered(trimmed) {
                flushParagraph()
                result.append(.ordered(number: number, text: text, indent: indent))
            } else if paragraph.isEmpty, line.first?.isWhitespace == true, let last = result.last {
                // An indented line under a list item carries it on.
                switch last {
                case .bullet(let text, let checked, let depth):
                    result[result.count - 1] = .bullet(text: join([text, trimmed], reflows: reflows), checked: checked, indent: depth)
                case .ordered(let number, let text, let depth):
                    result[result.count - 1] = .ordered(number: number, text: join([text, trimmed], reflows: reflows), indent: depth)
                default: paragraph.append(line)
                }
            } else {
                paragraph.append(line)
            }
        }
        if inCode {
            result.append(.code(text: code.joined(separator: "\n")))
        }
        if let open = details {
            result.append(.details(summary: open.summary ?? "Details", body: open.lines.joined(separator: "\n")))
        }
        flushTable()
        flushParagraph()
        return result
    }

    /// A `<summary>…</summary>` in the line: its text, and what's left.
    private static func summary(in line: String) -> (text: String, rest: String)? {
        guard let match = line.firstMatch(of: /(?i)<summary>(.*?)<\/summary>/) else { return nil }
        let text = markdown(fromHTML: String(match.1)).trimmingCharacters(in: .whitespaces)
        return (text, line.replacingCharacters(in: match.range, with: ""))
    }

    /// The HTML GitHub allows in Markdown, as Markdown: bold, italic, code,
    /// links, images (as links) and line breaks; tags with no Markdown of
    /// their own (`<sub>`, `<div>`, `<p>`) are dropped, keeping their text.
    /// Only HTML's tag names are touched, so `<unsigned base64>` and the
    /// like stay, and code spans are left alone.
    static func markdown(fromHTML line: String) -> String {
        guard line.contains("<") else { return line }
        var result = ""
        // Outside `code spans` only.
        for (index, part) in line.components(separatedBy: "`").enumerated() {
            if index > 0 { result += "`" }
            result += index.isMultiple(of: 2) ? convertingHTML(part) : part
        }
        return result
    }

    private static let droppedTags = "sub|sup|small|div|span|p|center|font|picture|source|section|article|ins|u|mark|kbd|ul|ol|li|table|thead|tbody|tr|td|th|blockquote|pre|h[1-6]|dl|dt|dd|abbr|cite|figure|figcaption"

    private static func convertingHTML(_ text: String) -> String {
        var text = text
        text = text.replacing(/(?i)<br\s*\/?>/, with: "\n")
        text = text.replacing(/(?i)<hr\s*\/?>/, with: "")
        text = text.replacing(/(?i)<\/?(strong|b)>/, with: "**")
        text = text.replacing(/(?i)<\/?(em|i)>/, with: "*")
        text = text.replacing(/(?i)<\/?(del|s|strike)>/, with: "~~")
        text = text.replacing(/(?i)<\/?code>/, with: "`")
        text = text.replacing(/(?i)<a\s[^>]*href="([^"]*)"[^>]*>(.*?)<\/a>/) { match in
            "[\(match.2)](\(match.1))"
        }
        text = text.replacing(/(?i)<img\s[^>]*>/) { match in
            let tag = String(match.0)
            let source = tag.firstMatch(of: /(?i)src="([^"]*)"/).map { String($0.1) }
            let alt = tag.firstMatch(of: /(?i)alt="([^"]*)"/).map { String($0.1) }
            guard let source else { return "" }
            return "[\(alt.flatMap { $0.isEmpty ? nil : $0 } ?? "image")](\(source))"
        }
        if let tags = try? Regex("(?i)</?(\(droppedTags)|a)(\\s[^>]*)?>") {
            text = text.replacing(tags, with: "")
        }
        return text
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }

    /// Lines of one paragraph or list item: spaces between them when the
    /// text reflows, except after a hard break.
    private static func join(_ lines: [String], reflows: Bool) -> String {
        guard reflows else { return lines.joined(separator: "\n") }
        var text = ""
        for (index, line) in lines.enumerated() {
            let breaks = line.hasSuffix("  ") || line.hasSuffix("\\")
            var part = line.trimmingCharacters(in: .whitespaces)
            if part.hasSuffix("\\") { part.removeLast() }
            text += part
            if index < lines.count - 1 { text += breaks ? "\n" : " " }
        }
        return text
    }

    /// PR templates are full of `<!-- guidance -->` blocks nobody wants to read.
    private static func strippingHTMLComments(_ text: String) -> String {
        text.replacing(/<!--[\s\S]*?-->/, with: "")
    }

    private static func tableCells(_ line: String) -> [String] {
        var inner = line.dropFirst()
        if inner.hasSuffix("|") { inner = inner.dropLast() }
        return inner.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func heading(_ line: String) -> (Int, String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        return (hashes, String(rest.dropFirst()))
    }

    private static func bullet(_ line: String) -> (String, Bool?)? {
        guard let marker = ["- ", "* ", "+ "].first(where: { line.hasPrefix($0) }) else { return nil }
        let text = line.dropFirst(marker.count)
        if text.hasPrefix("[ ] ") { return (String(text.dropFirst(4)), false) }
        if text.lowercased().hasPrefix("[x] ") { return (String(text.dropFirst(4)), true) }
        return (String(text), nil)
    }

    private static func ordered(_ line: String) -> (String, String)? {
        guard let dot = line.firstIndex(of: ".") else { return nil }
        let head = line[..<dot]
        guard !head.isEmpty, head.allSatisfy(\.isNumber) else { return nil }
        let after = line.index(after: dot)
        guard after < line.endIndex, line[after] == " " else { return nil }
        return (String(head), String(line[line.index(after: after)...]))
    }

    /// A heading's text without its Markdown, for the outline.
    private static func plain(_ text: String) -> String {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)).map { String($0.characters) } ?? text
    }

    // MARK: Compact

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            inline(text)
                .font(level == 1 ? .title3 : level == 2 ? .headline : .subheadline)
                .fontWeight(.semibold)
                .padding(.top, 4)
        case .bullet(let text, let checked, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let checked {
                    Image(systemName: checked ? "checkmark.square.fill" : "square")
                        .foregroundStyle(checked ? Color.accentColor : .secondary)
                } else {
                    Text("•").foregroundStyle(.secondary)
                }
                inline(text).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, CGFloat(indent) * 14)
        case .ordered(let number, let text, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(number).").foregroundStyle(.secondary).monospacedDigit()
                inline(text).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, CGFloat(indent) * 14)
        case .code(let text):
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        case .table(let rows):
            table(rows)
        case .paragraph(let text):
            inline(text).frame(maxWidth: .infinity, alignment: .leading)
        case .details(let summary, let body):
            DisclosureGroup {
                MarkdownText(source: body, reflows: reflows)
                    .padding(.top, 4)
            } label: {
                inline(summary).fontWeight(.medium)
            }
        case .rule:
            Divider().padding(.vertical, 4)
        }
    }

    private func table(_ rows: [[String]], size: CGFloat? = nil) -> some View {
        let columns = rows.map(\.count).max() ?? 0
        return Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                GridRow {
                    ForEach(0..<columns, id: \.self) { column in
                        inline(column < row.count ? row[column] : "")
                            .font(size.map { .system(size: $0 * 0.93) })
                            .fontWeight(index == 0 ? .semibold : nil)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if index == 0 { Divider() }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: Reading

    /// Blocks with their indexes, less those inside a folded section.
    private func visible(_ blocks: [Block]) -> [(offset: Int, element: Block)] {
        let folded = collapsed?.wrappedValue ?? []
        var hiding = false
        var result: [(offset: Int, element: Block)] = []
        for (index, block) in blocks.enumerated() {
            if case .heading(let level, _) = block, level <= 2 {
                hiding = folded.contains(index)
                result.append((index, block))
            } else if !hiding {
                result.append((index, block))
            }
        }
        return result
    }

    /// Room above a block: most above headings, least between list items.
    private func spacing(before block: Block, after previous: Block?, size: CGFloat) -> CGFloat {
        switch block {
        case .heading(let level, _):
            return level <= 2 ? size * 2 : size * 1.4
        case .bullet, .ordered:
            switch previous {
            case .bullet, .ordered: return size * 0.4
            default: return size * 0.7
            }
        case .code, .table, .details, .rule:
            return size * 0.9
        case .paragraph:
            if case .heading = previous { return size * 0.5 }
            return size * 0.8
        }
    }

    @ViewBuilder
    private func documentView(_ block: Block, index: Int, size: CGFloat) -> some View {
        let lineSpacing = size * 0.32
        switch block {
        case .heading(let level, let text):
            let font: Font = switch level {
            case 1: .system(size: size * 1.55, weight: .bold)
            case 2: .system(size: size * 1.3, weight: .bold)
            case 3: .system(size: size * 1.1, weight: .semibold)
            default: .system(size: size, weight: .semibold)
            }
            if level <= 2, let collapsed {
                let isFolded = collapsed.wrappedValue.contains(index)
                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        if isFolded { collapsed.wrappedValue.remove(index) } else { collapsed.wrappedValue.insert(index) }
                    }
                } label: {
                    inline(text)
                        .font(font)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        // In the gutter, so the heading lines up with the text.
                        .overlay(alignment: .leading) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: size * 0.7, weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .rotationEffect(.degrees(isFolded ? 0 : 90))
                                .offset(x: -size * 1.3)
                        }
                }
                .buttonStyle(.plain)
                .help(isFolded ? "Show this section" : "Fold this section")
                .id(Self.anchor(index))
            } else {
                inline(text)
                    .font(font)
                    .foregroundStyle(level >= 4 ? .secondary : .primary)
                    .id(Self.anchor(index))
            }
        case .bullet(let text, let checked, let indent):
            HStack(alignment: .firstTextBaseline, spacing: size * 0.55) {
                Group {
                    if let checked {
                        Image(systemName: checked ? "checkmark.square.fill" : "square")
                            .foregroundStyle(checked ? Color.accentColor : .secondary)
                    } else {
                        Text(["•", "◦", "▪"][min(indent, 2)]).foregroundStyle(.secondary)
                    }
                }
                .frame(width: size, alignment: .center)
                inline(text)
                    .lineSpacing(lineSpacing)
                    .foregroundStyle(checked == true ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: size))
            .padding(.leading, CGFloat(indent) * size * 1.5)
        case .ordered(let number, let text, let indent):
            HStack(alignment: .firstTextBaseline, spacing: size * 0.55) {
                Text("\(number).")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(minWidth: size * 1.3, alignment: .trailing)
                inline(text)
                    .lineSpacing(lineSpacing)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: size))
            .padding(.leading, CGFloat(indent) * size * 1.5)
        case .code(let text):
            ScrollView(.horizontal) {
                Text(text)
                    .font(.system(size: size * 0.86, design: .monospaced))
                    .lineSpacing(size * 0.2)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        case .table(let rows):
            table(rows, size: size)
        case .paragraph(let text):
            inline(text)
                .font(.system(size: size))
                .lineSpacing(lineSpacing)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .details(let summary, let body):
            DisclosureGroup {
                MarkdownText(source: body, reflows: reflows, reading: size)
                    .padding(.top, size * 0.5)
            } label: {
                inline(summary).font(.system(size: size, weight: .medium))
            }
        case .rule:
            Divider().padding(.vertical, size * 0.4)
        }
    }

    private func inline(_ source: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let attributed = try? AttributedString(markdown: source, options: options) {
            return Text(attributed)
        }
        return Text(source)
    }
}
