import Testing
@testable import Gannin

/// Spotting claude's permission prompt on the terminal's screen.
struct PermissionPromptTests {
    private let rule = String(repeating: "─", count: 60)

    private let bashPrompt = [
        " Bash command",
        "   rtk proxy ls STANDARDS.md 2>&1 | head -30",
        " │ Reads outside the working directories are blocked",
        "",
        " Do you want to proceed?",
        " ❯ 1. Yes",
        "   2. No",
        "",
        " Esc to cancel · Tab to amend",
    ]

    @Test func readsABashPrompt() {
        #expect(PermissionChoice.promptShown(in: bashPrompt))
        #expect(PermissionChoice.read(from: bashPrompt).map(\.label) == ["Yes", "No"])
    }

    @Test func readsAnEditPrompt() {
        let prompt = [" Do you want to make this edit to Foo.swift?", " ❯ 1. Yes", "   2. Yes, allow all edits this session", "   3. No"]
        #expect(PermissionChoice.promptShown(in: prompt))
    }

    @Test func questionWithoutChoicesIsNotAPrompt() {
        #expect(!PermissionChoice.promptShown(in: [" Do you want to proceed?", "", rule]))
    }

    @Test func quotedQuestionIsNotAPrompt() {
        let lines = [#"⏺ Claude Code asks "Do you want to proceed?" before running it."#, "  1. Open Settings", rule, "❯ ", rule]
        #expect(!PermissionChoice.promptShown(in: lines))
    }

    @Test func choicesAboveTheQuestionAreStale() {
        let lines = ["  1. Yes", "  2. No", " Do you want to proceed?", "", rule]
        #expect(!PermissionChoice.promptShown(in: lines))
    }

    @Test func listInAnIndentedParagraphIsNotAPrompt() {
        let lines = ["⏺ Here is the plan.", "", "  Do you want to keep the old API?", "  1. Keep", "  2. Drop", "", rule, "❯ ", rule]
        #expect(!PermissionChoice.promptShown(in: lines))
    }

    @Test func readsAQuestionThatWrapsOnANarrowPane() {
        let prompt = [" Do you want to make this edit to", " Gannin/Sessions/SessionActions.swift?", " ❯ 1. Yes", "   2. No"]
        #expect(PermissionChoice.promptShown(in: prompt))
    }

    @Test func selectionCanSitOnALaterChoice() {
        let prompt = [" Do you want to proceed?", "   1. Yes", " ❯ 2. No"]
        #expect(PermissionChoice.promptShown(in: prompt))
    }
}
