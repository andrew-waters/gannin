import Testing
@testable import Gannin

/// How a Vue component's lines are split into sections by language.
struct VueSectionsTests {
    private func runs(_ lines: [String]) -> [(String, [String])] {
        let code = lines.enumerated().map { DiffHighlighter.Code(id: $0.offset, text: $0.element) }
        return VueSections.runs(code).map { ($0.language, $0.code.map(\.text)) }
    }

    @Test func eachSectionIsInItsOwnLanguage() {
        let result = runs([
            "<template>", "  <p>hi</p>", "</template>",
            "<script lang=\"ts\">", "const a = 1", "</script>",
            "<style lang='scss' scoped>", ".a { b: c }", "</style>",
        ])
        #expect(result.map(\.0) == ["xml", "typescript", "xml", "scss", "xml"])
        #expect(result[1].1 == ["const a = 1"])
        #expect(result[3].1 == [".a { b: c }"])
    }

    @Test func scriptAndStyleDefaultToJavaScriptAndCSS() {
        let result = runs(["<script>", "a()", "</script>", "<style>", "p {}", "</style>"])
        #expect(result.map(\.0) == ["xml", "javascript", "xml", "css", "xml"])
    }

    @Test func aSectionOnOneLineStaysMarkup() {
        let result = runs(["<script src=\"a.js\"></script>", "<p>x</p>"])
        #expect(result.map(\.0) == ["xml"])
    }

    @Test func aHunkStartingInsideASectionTakesItsLanguageFromTheClosingTag() {
        let result = runs(["const a = 1", "</script>", "<template>"])
        #expect(result.map(\.0) == ["javascript", "xml"])
        #expect(result[0].1 == ["const a = 1"])
        #expect(runs(["p {}", "</style>"]).map(\.0) == ["css", "xml"])
    }

    @Test func linesWithNoTagAreMarkup() {
        #expect(runs(["<div>", "  x", "</div>"]).map(\.0) == ["xml"])
    }

    @Test func aSideWithNoTagIsGuessedFromItsContent() {
        #expect(runs(["  const a = 1", "  return a"]).map(\.0) == ["javascript"])
        #expect(runs(["  items.map(x => x.id)"]).map(\.0) == ["javascript"])
        #expect(runs(["  color: red;", "  margin: 0 auto;"]).map(\.0) == ["css"])
        #expect(runs([".card > a:hover {", "  color: red;", "}"]).map(\.0) == ["css"])
        #expect(runs(["  <p class=\"a\">", "  :class=\"b\""]).map(\.0) == ["xml"])
        #expect(runs(["  class=\"a\"", "  v-if=\"b\""]).map(\.0) == ["xml"])
        #expect(runs(["{{ count }}"]).map(\.0) == ["xml"])
    }

    @Test func scriptWinsOverStyleInAGuess() {
        #expect(runs(["if (a) {", "  b: c;", "}"]).map(\.0) == ["javascript"])
    }

    @Test func aScriptInAnotherLanguageStaysMarkup() {
        #expect(runs(["<script lang=\"coffee\">", "a = 1", "</script>"]).map(\.0) == ["xml"])
    }

    @Test func everyRunKeepsItsLinesInOrder() {
        let lines = ["<template>", "<script>", "a()", "</script>", "<style>", "p {}"]
        #expect(runs(lines).flatMap(\.1) == lines)
    }
}
