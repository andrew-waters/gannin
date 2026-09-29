import SwiftUI

/// Lightweight markdown renderer for issue and PR bodies.
///
/// Splits the source into block-level chunks (headings, list items, code
/// fences, tables, paragraphs) and renders each as its own row. Inline formatting
/// (bold, italic, code spans, links) is handled by `AttributedString(markdown:)`.
struct MarkdownText: View {
    let source: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    // MARK: Parsing

    private enum Block {
        case heading(level: Int, text: String)
        case bullet(text: String, checked: Bool?)
        case ordered(number: String, text: String)
        case code(text: String)
        /// The header row first.
        case table(rows: [[String]])
        case paragraph(text: String)
    }

    private var blocks: [Block] {
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
            let joined = paragraph.joined(separator: "\n")
            if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(.paragraph(text: joined))
            }
            paragraph.removeAll()
        }

        for line in Self.strippingHTMLComments(source).components(separatedBy: .newlines) {
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
            if trimmed.hasPrefix("```") {
                flushParagraph()
                inCode = true
            } else if trimmed.isEmpty {
                flushParagraph()
            } else if let (level, text) = heading(trimmed) {
                flushParagraph()
                result.append(.heading(level: level, text: text))
            } else if let (text, checked) = bullet(trimmed) {
                flushParagraph()
                result.append(.bullet(text: text, checked: checked))
            } else if let (number, text) = ordered(trimmed) {
                flushParagraph()
                result.append(.ordered(number: number, text: text))
            } else {
                paragraph.append(line)
            }
        }
        if inCode {
            result.append(.code(text: code.joined(separator: "\n")))
        }
        flushTable()
        flushParagraph()
        return result
    }

    /// PR templates are full of `<!-- guidance -->` blocks nobody wants to read.
    private static func strippingHTMLComments(_ text: String) -> String {
        text.replacing(/<!--[\s\S]*?-->/, with: "")
    }

    private func tableCells(_ line: String) -> [String] {
        var inner = line.dropFirst()
        if inner.hasSuffix("|") { inner = inner.dropLast() }
        return inner.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private func heading(_ line: String) -> (Int, String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        return (hashes, String(rest.dropFirst()))
    }

    private func bullet(_ line: String) -> (String, Bool?)? {
        guard let marker = ["- ", "* ", "+ "].first(where: { line.hasPrefix($0) }) else { return nil }
        let text = line.dropFirst(marker.count)
        if text.hasPrefix("[ ] ") { return (String(text.dropFirst(4)), false) }
        if text.lowercased().hasPrefix("[x] ") { return (String(text.dropFirst(4)), true) }
        return (String(text), nil)
    }

    private func ordered(_ line: String) -> (String, String)? {
        guard let dot = line.firstIndex(of: ".") else { return nil }
        let head = line[..<dot]
        guard !head.isEmpty, head.allSatisfy(\.isNumber) else { return nil }
        let after = line.index(after: dot)
        guard after < line.endIndex, line[after] == " " else { return nil }
        return (String(head), String(line[line.index(after: after)...]))
    }

    // MARK: Rendering

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            inline(text)
                .font(level == 1 ? .title3 : level == 2 ? .headline : .subheadline)
                .fontWeight(.semibold)
                .padding(.top, 4)
        case .bullet(let text, let checked):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let checked {
                    Image(systemName: checked ? "checkmark.square.fill" : "square")
                        .foregroundStyle(checked ? Color.accentColor : .secondary)
                } else {
                    Text("•").foregroundStyle(.secondary)
                }
                inline(text).frame(maxWidth: .infinity, alignment: .leading)
            }
        case .ordered(let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(number).").foregroundStyle(.secondary).monospacedDigit()
                inline(text).frame(maxWidth: .infinity, alignment: .leading)
            }
        case .code(let text):
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        case .table(let rows):
            let columns = rows.map(\.count).max() ?? 0
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(0..<columns, id: \.self) { column in
                            inline(column < row.count ? row[column] : "")
                                .fontWeight(index == 0 ? .semibold : nil)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if index == 0 { Divider() }
                }
            }
            .padding(.vertical, 4)
        case .paragraph(let text):
            inline(text).frame(maxWidth: .infinity, alignment: .leading)
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
