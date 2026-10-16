import Testing
@testable import Gannin

/// The message a diff line's Ask Claude sends to the review.
struct DiffQuestionTests {
    private let lines = (0..<30).map { DiffLine(id: $0, kind: .context, text: " line \($0)", oldLine: $0 + 1, newLine: $0 + 1) }

    @Test func marksTheLineAndKeepsFiveEitherSide() {
        let message = DiffQuestion.message("Why?", path: "A.swift", anchor: (13, false), line: lines[12], in: lines)
        #expect(message.contains("A.swift, line 13"))
        #expect(message.contains(">  line 12"))
        #expect(message.contains("   line 7"))
        #expect(message.contains("   line 17"))
        #expect(!message.contains("line 6\n"))
        #expect(!message.contains("line 18"))
        #expect(message.hasSuffix("Why?"))
    }

    @Test func stopsAtTheEdgesOfTheFile() {
        let message = DiffQuestion.message("Why?", path: "A.swift", anchor: (1, false), line: lines[0], in: lines)
        #expect(message.contains(">  line 0"))
        #expect(message.contains("   line 5"))
        #expect(!message.contains("line 6"))
    }

    @Test func saysWhenTheLineIsOnTheOldSide() {
        let message = DiffQuestion.message("Why?", path: "A.swift", anchor: (4, true), line: lines[3], in: lines)
        #expect(message.contains("line 4 of the old file"))
    }
}
