import SwiftUI

/// A line of a file's diff, coloured by what it is, with its numbers in the
/// file before and after.
nonisolated struct DiffLine: Identifiable, Hashable, Sendable {
    nonisolated enum Kind: Sendable { case added, removed, hunk, context, note }
    let id: Int
    let kind: Kind
    let text: String
    var oldLine: Int? = nil
    var newLine: Int? = nil

    /// The line a comment on it points at: the new file's, else the old's
    /// for a removed line.
    var anchor: (line: Int, isOld: Bool)? {
        if let newLine { return (newLine, false) }
        if let oldLine { return (oldLine, true) }
        return nil
    }
}

/// Reading git's unified diffs, and patches of one hunk for `git apply`.
nonisolated enum GitDiff {
    /// Shown lines stop here, so a huge file doesn't stall the view.
    static let lineLimit = 4000

    /// The diff's lines, numbered, and its header (for a patch of a hunk).
    static func lines(of output: String) -> ([DiffLine], [String]) {
        var lines: [DiffLine] = []
        var header: [String] = []
        var inHeader = true
        var old = 0, new = 0
        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("@@") {
                inHeader = false
                // `@@ -12,7 +12,9 @@`: where each side's lines start.
                let ranges = line.split(separator: " ").dropFirst().prefix(2)
                for range in ranges {
                    let start = Int(range.dropFirst().split(separator: ",").first ?? "") ?? 0
                    if range.hasPrefix("-") { old = start } else if range.hasPrefix("+") { new = start }
                }
            }
            let kind: DiffLine.Kind
            if inHeader {
                // The file's header says nothing the list doesn't, except
                // for a binary file.
                guard line.hasPrefix("Binary files") else {
                    if !line.isEmpty { header.append(line) }
                    continue
                }
                kind = .note
            } else if line.hasPrefix("@@") {
                kind = .hunk
            } else if line.hasPrefix("+") {
                kind = .added
            } else if line.hasPrefix("-") {
                kind = .removed
            } else if line.hasPrefix("\\") {
                kind = .note
            } else {
                kind = .context
            }
            if lines.count == lineLimit {
                lines.append(DiffLine(id: lines.count, kind: .note, text: "Only the first \(lineLimit) lines are shown."))
                break
            }
            var numbered = DiffLine(id: lines.count, kind: kind, text: line)
            switch kind {
            case .added:
                numbered.newLine = new
                new += 1
            case .removed:
                numbered.oldLine = old
                old += 1
            case .context:
                numbered.oldLine = old
                numbered.newLine = new
                old += 1
                new += 1
            default:
                break
            }
            lines.append(numbered)
        }
        if lines.last?.kind == .context, lines.last?.text.isEmpty == true { lines.removeLast() }
        return (lines, header)
    }

    /// The file's header and the hunk starting at `hunk`, as a patch for
    /// `git apply`; nil when that isn't a hunk's header line.
    static func patch(hunk: DiffLine.ID, in lines: [DiffLine], header: [String]) -> String? {
        guard !header.isEmpty, let start = lines.firstIndex(where: { $0.id == hunk }), lines[start].kind == .hunk else { return nil }
        var patch = header + [lines[start].text]
        for line in lines[(start + 1)...] {
            if line.kind == .hunk { break }
            // The cut-off note isn't git's.
            if line.kind == .note, !line.text.hasPrefix("\\") { return nil }
            patch.append(line.text)
        }
        return patch.joined(separator: "\n") + "\n"
    }

    /// Whether the shown diff stops short of the file's end, so a hunk
    /// near it can't be made into a patch.
    static func isCut(_ lines: [DiffLine]) -> Bool {
        lines.last.map { $0.kind == .note && !$0.text.hasPrefix("\\") && !$0.text.hasPrefix("Binary") } ?? false
    }
}

/// How diff lines are drawn, the same in a session's pane and a repo's page.
enum DiffStyle {
    static func foreground(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .hunk, .note: .secondary
        default: .primary
        }
    }

    static func background(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: ChartPalette.good.opacity(0.14)
        case .removed: ChartPalette.critical.opacity(0.14)
        case .hunk: Color.secondary.opacity(0.1)
        case .context, .note: .clear
        }
    }
}
