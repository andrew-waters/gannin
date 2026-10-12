import Foundation
import Testing
@testable import Gannin

/// How a diff's lines are split into the code each side's file holds, and
/// when highlighting is skipped.
struct DiffHighlighterTests {
    private let diff = """
        @@ -1,3 +1,3 @@
         let a = 1
        -let b = 2
        +let b = 3
         let c = 4
        @@ -10,1 +10,2 @@
         func f() {}
        +func g() {}
        """

    private var lines: [DiffLine] { GitDiff.lines(of: diff).0 }

    @Test func eachHunkHasANewAndAnOldSideWithoutMarkers() {
        let hunks = DiffHighlighter.hunks(lines)
        #expect(hunks.count == 2)
        #expect(hunks[0].new.map(\.text) == ["let a = 1", "let b = 3", "let c = 4"])
        #expect(hunks[0].old.map(\.text) == ["let a = 1", "let b = 2", "let c = 4"])
        #expect(hunks[1].new.map(\.text) == ["func f() {}", "func g() {}"])
        #expect(hunks[1].old.map(\.text) == ["func f() {}"])
    }

    @Test func sidesKeepTheLinesIDs() {
        let all = lines
        let hunk = DiffHighlighter.hunks(all)[0]
        let added = all.first { $0.kind == .added }!
        let removed = all.first { $0.kind == .removed }!
        #expect(hunk.new.contains { $0.id == added.id })
        #expect(!hunk.new.contains { $0.id == removed.id })
        #expect(hunk.old.contains { $0.id == removed.id })
    }

    @Test func aLineOverTheLengthCapSkipsTheFile() {
        let long = DiffLine(id: 0, kind: .added, text: "+" + String(repeating: "x", count: DiffHighlighter.maxLineLength))
        #expect(!DiffHighlighter.fitsCap([long]))
        #expect(DiffHighlighter.fitsCap(lines))
    }

    @Test func aFileOverTheSizeCapIsSkipped() async {
        let line = DiffLine(id: 0, kind: .context, text: " " + String(repeating: "x", count: 1_000))
        let many = Array(repeating: line, count: DiffHighlighter.maxCharacters / 1_000 + 1)
        #expect(await DiffHighlighter.shared.highlight(many, language: "swift", dark: false) == nil)
    }

    @Test func highlightsCodeWithoutItsMarkers() async throws {
        let result = try #require(await DiffHighlighter.shared.highlight(lines, language: "swift", dark: false))
        let added = try #require(lines.first { $0.kind == .added })
        #expect(String(try #require(result[added.id]).characters) == "let b = 3")
    }

    private func added(_ code: [String]) -> [DiffLine] {
        [DiffLine(id: 0, kind: .hunk, text: "@@ -1 +1 @@")] + code.enumerated().map { index, text in
            DiffLine(id: index + 1, kind: text.isEmpty ? .context : .added, text: (text.isEmpty ? " " : "+") + text)
        }
    }

    private func check(_ code: [String], language: String) async throws {
        let lines = added(code)
        let result = try #require(await DiffHighlighter.shared.highlight(lines, language: language, dark: true))
        var coloured = false
        for (index, text) in code.enumerated() {
            let line = try #require(result[index + 1])
            #expect(String(line.characters) == text)
            if line.runs.contains(where: { $0.foregroundColor != nil }) { coloured = true }
        }
        #expect(coloured)
    }

    @Test func swiftWithPunctuationQuotesTabsAndEmojiKeepsItsText() async throws {
        try await check([
            "func f<T: Equatable>(_ a: T, _ b: T) -> Bool where T: Hashable {",
            "\tlet s = \"it's \\\"quoted\\\" & <b>\" + 'x' // 🎉 done",
            "",
            "\treturn a == b && a != b || !(a < b)",
            "}",
        ], language: "swift")
    }

    @Test func tsxWithTagsKeepsItsText() async throws {
        try await check([
            "const el = <div className=\"a\" onClick={() => x > 1 && y}>{label} &amp; more</div>",
        ], language: "typescript")
    }
}
