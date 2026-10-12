import Foundation
import Highlighter
import SwiftUI

/// Syntax colours for the code in a diff, line by line.
actor DiffHighlighter {
    /// Beyond these a file is left plain, so highlighting can't stall the review.
    static let maxCharacters = 200_000
    static let maxLineLength = 2_000

    static let shared = DiffHighlighter()

    private var highlighter: Highlighter?
    private var theme: String?

    /// One line's colours, without its `+`, `-` or space marker, for each
    /// highlightable line; nil when the file is too big or the language fails.
    ///
    /// Each hunk goes in as two blocks, the new side (context and added lines)
    /// and the old side (context and removed lines), each as the code it'd be
    /// in that file. A hunk that starts inside a comment or string can colour
    /// its first lines wrongly.
    func highlight(_ lines: [DiffLine], language: String, dark: Bool) -> [DiffLine.ID: AttributedString]? {
        guard Self.fitsCap(lines) else { return nil }
        guard let highlighter = highlighter(dark: dark) else { return nil }
        var result: [DiffLine.ID: AttributedString] = [:]
        for hunk in Self.hunks(lines) {
            for side in [hunk.new, hunk.old] {
                guard let coloured = Self.colour(side, with: highlighter, language: language) else { return nil }
                result.merge(coloured) { new, _ in new }
            }
        }
        return result
    }

    private func highlighter(dark: Bool) -> Highlighter? {
        let name = dark ? "github-dark" : "github"
        if highlighter == nil { highlighter = Highlighter() }
        if theme != name {
            guard highlighter?.setTheme(name) == true else { return nil }
            theme = name
        }
        return highlighter
    }

    nonisolated static func fitsCap(_ lines: [DiffLine]) -> Bool {
        var total = 0
        for line in lines {
            if line.text.utf16.count > maxLineLength { return false }
            total += line.text.utf16.count
        }
        return total <= maxCharacters
    }

    /// A line's code as it is in one side's file: its text without the marker.
    nonisolated struct Code: Equatable {
        let id: DiffLine.ID
        let text: String
    }

    /// The two sides of one hunk.
    nonisolated struct Hunk: Equatable {
        var new: [Code] = []
        var old: [Code] = []
    }

    nonisolated static func hunks(_ lines: [DiffLine]) -> [Hunk] {
        var hunks: [Hunk] = []
        var current: Hunk?
        for line in lines {
            switch line.kind {
            case .hunk:
                if let current { hunks.append(current) }
                current = Hunk()
            case .note:
                continue
            case .context, .added, .removed:
                let code = Code(id: line.id, text: String(line.text.dropFirst()))
                var hunk = current ?? Hunk()
                if line.kind != .removed { hunk.new.append(code) }
                if line.kind != .added { hunk.old.append(code) }
                current = hunk
            }
        }
        if let current { hunks.append(current) }
        return hunks
    }

    /// Colours one side's lines, keeping only the foreground colour of each
    /// run so the diff's own font and background stay.
    private static func colour(_ code: [Code], with highlighter: Highlighter, language: String) -> [DiffLine.ID: AttributedString]? {
        guard !code.isEmpty else { return [:] }
        let block = code.map(\.text).joined(separator: "\n")
        guard let highlighted = highlighter.highlight(block, as: language, doFastRender: true),
              highlighted.string == block
        else { return nil }
        var result: [DiffLine.ID: AttributedString] = [:]
        var start = 0
        for line in code {
            let length = (line.text as NSString).length
            let slice = highlighted.attributedSubstring(from: NSRange(location: start, length: length))
            var text = AttributedString()
            slice.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: slice.length)) { value, range, _ in
                var run = AttributedString(slice.attributedSubstring(from: range).string)
                if let color = value as? NSColor { run.foregroundColor = Color(nsColor: color) }
                text.append(run)
            }
            result[line.id] = text
            start += length + 1
        }
        return result
    }
}
