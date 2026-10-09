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

/// Two panes side by side, one (the leading, unless `fixing` says the
/// trailing) as wide as you drag it (kept under `key`), the other taking
/// the rest. Unlike `HSplitView`, its width never shifts when either pane's
/// content changes, as picking a commit or file does, and it opens at the
/// width given.
struct FixedSplit<Leading: View, Trailing: View>: View {
    @AppStorage private var width: Double
    private let range: ClosedRange<Double>
    private let fixing: HorizontalEdge
    private let leading: Leading
    private let trailing: Trailing
    @State private var dragStart: Double?

    init(key: String, width: Double, range: ClosedRange<Double>, fixing: HorizontalEdge = .leading,
         @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        _width = AppStorage(wrappedValue: width, key)
        self.range = range
        self.fixing = fixing
        self.leading = leading()
        self.trailing = trailing()
    }

    private var fixedWidth: Double { min(max(width, range.lowerBound), range.upperBound) }

    var body: some View {
        HStack(spacing: 0) {
            if fixing == .leading {
                leading
                    .frame(width: fixedWidth)
                    .frame(maxHeight: .infinity)
            } else {
                leading
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Color.separatorLine
                .frame(width: 1)
                .overlay {
                    Color.clear
                        .frame(width: 9)
                        .contentShape(Rectangle())
                        .onHover { inside in
                            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                        }
                        .gesture(
                            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                                .onChanged { drag in
                                    let start = dragStart ?? width
                                    dragStart = start
                                    // Dragging right widens a leading pane and
                                    // narrows a trailing one.
                                    let moved = fixing == .leading ? drag.translation.width : -drag.translation.width
                                    width = min(max(start + moved, range.lowerBound), range.upperBound)
                                }
                                .onEnded { _ in dragStart = nil }
                        )
                }
                .zIndex(1)
            if fixing == .trailing {
                trailing
                    .frame(width: fixedWidth)
                    .frame(maxHeight: .infinity)
            } else {
                trailing
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// A diff's lines, scrolling both ways, every row as wide as the widest
/// line (or the pane, if that's wider), so the added and removed colours
/// run evenly across. A lazy stack can't measure rows it hasn't drawn, so
/// the width comes from the longest line in the monospaced font.
struct DiffScroll<Row: View>: View {
    let lines: [DiffLine]
    @ViewBuilder let row: (DiffLine) -> Row

    /// One character of the diff's font (Settings > General).
    private static var characterWidth: CGFloat {
        ("0" as NSString).size(withAttributes: [.font: EditorFontStore.shared.font]).width
    }

    /// Both line numbers' gutters and their gap, the longest line (a tab
    /// counted as four), and room for a hunk's buttons.
    private var contentWidth: CGFloat {
        let longest = lines.lazy.map { $0.text.count + 3 * $0.text.filter { $0 == "\t" }.count }.max() ?? 0
        return 84 + CGFloat(longest) * Self.characterWidth + 24
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { row($0) }
                }
                .frame(width: max(proxy.size.width, contentWidth), alignment: .leading)
            }
        }
    }
}
