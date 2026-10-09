import Foundation
import Testing
@testable import Gannin

/// Reading claude's permission mode, and switching it by Shift+Tab.
struct SessionModeTests {
    private let rule = String(repeating: "─", count: 60)

    /// The bottom of a terminal with claude's input box and `footer` under it.
    private func screen(_ footer: [String], prompt: String = "❯ ") -> [String] {
        ["⏺ Done. The tests pass.", "", rule, prompt, rule] + footer + ["", ""]
    }

    @Test func footerNamesEachMode() {
        #expect(ClaudeMode.fromFooter(screen(["  ⏵⏵ auto mode on (shift+tab to cycle)"])) == .auto)
        #expect(ClaudeMode.fromFooter(screen(["  ⏵⏵ accept edits on (shift+tab to cycle)"])) == .acceptEdits)
        #expect(ClaudeMode.fromFooter(screen(["  ⏸ plan mode on (shift+tab to cycle)"])) == .plan)
        #expect(ClaudeMode.fromFooter(screen(["  ⏵⏵ bypass permissions on (shift+tab to cycle)"])) == .bypassPermissions)
    }

    @Test func footerWithNoModeIsTheDefault() {
        #expect(ClaudeMode.fromFooter(screen(["  ? for shortcuts"])) == .default)
        #expect(ClaudeMode.fromFooter(screen([])) == .default)
        #expect(ClaudeMode.fromFooter(screen(["  Context left until auto-compact: 8%"])) == .default)
    }

    @Test func footerReadsTheOlderRoundedBox() {
        let lines = [
            "╭" + String(repeating: "─", count: 58) + "╮",
            "│ > fix the build" + String(repeating: " ", count: 42) + "│",
            "╰" + String(repeating: "─", count: 58) + "╯",
            "  ⏵⏵ auto mode on (shift+tab to cycle)",
        ]
        #expect(ClaudeMode.fromFooter(lines) == .auto)
    }

    @Test func modeAboveTheBoxIsNotTheFooter() {
        // claude's own words, not its footer.
        let lines = ["I turned auto mode on (shift+tab to cycle) earlier.", rule, "❯ ", rule, "  ? for shortcuts"]
        #expect(ClaudeMode.fromFooter(lines) == .default)
    }

    @Test func noInputBoxCantBeRead() {
        let prompt = [
            rule,
            " Bash command",
            "   swift build",
            " Do you want to proceed?",
            " ❯ 1. Yes",
            "   2. Yes, and don't ask again for swift build commands",
            "   3. No, and tell Claude what to do differently (esc)",
        ]
        #expect(ClaudeMode.fromFooter(prompt) == nil)
        #expect(ClaudeMode.fromFooter([]) == nil)
        #expect(ClaudeMode.fromFooter(["", "", ""]) == nil)
    }

    @Test func transcriptKeepsTheLatestMode() {
        var reader = TranscriptReader()
        let records = [
            #"{"type":"user","permissionMode":"default","message":{"role":"user","content":"hello"},"uuid":"1"}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Hi"}]},"uuid":"2"}"#,
            #"{"type":"user","permissionMode":"auto","message":{"role":"user","content":"go on"},"uuid":"3"}"#,
            #"{"type":"user","isSidechain":true,"permissionMode":"plan","message":{"role":"user","content":"sub"},"uuid":"4"}"#,
        ]
        reader.consume(Data((records.joined(separator: "\n") + "\n").utf8))
        #expect(reader.summary.permissionMode == "auto")
        #expect(ClaudeMode(rawValue: reader.summary.permissionMode ?? "") == .auto)
    }

    @Test func transcriptWithoutAModeHasNone() {
        var reader = TranscriptReader()
        reader.consume(Data((#"{"type":"user","message":{"role":"user","content":"hello"},"uuid":"1"}"# + "\n").utf8))
        #expect(reader.summary.permissionMode == nil)
    }

    @Test func keysAreEncodedForTheKittyProtocol() {
        #expect(TerminalKeys.encode(TerminalKeys.shiftTab, kitty: true, reportAllKeys: false) == "\u{1B}[9;2u")
        #expect(TerminalKeys.encode(TerminalKeys.shiftTab, kitty: false, reportAllKeys: false) == "\u{1B}[Z")
        #expect(TerminalKeys.encode(TerminalKeys.escape, kitty: true, reportAllKeys: false) == "\u{1B}[27u")
        #expect(TerminalKeys.encode(TerminalKeys.escape, kitty: false, reportAllKeys: false) == "\u{1B}")
        #expect(TerminalKeys.encode("\r", kitty: true, reportAllKeys: false) == "\r")
        #expect(TerminalKeys.encode("\r", kitty: true, reportAllKeys: true) == "\u{1B}[13u")
        #expect(TerminalKeys.encode("\u{1B}[B", kitty: true, reportAllKeys: true) == "\u{1B}[B")
    }

    /// Runs a cycle against claude's modes in `order`, from its first,
    /// pressing until the cycle stops.
    private func run(_ order: [ClaudeMode], to target: ClaudeMode) -> (ModeCycle.Outcome, presses: Int, endedOn: ClaudeMode) {
        var cycle = ModeCycle(from: order[0], to: target)
        var index = 0
        var presses = 0
        while true {
            presses += 1
            index = (index + 1) % order.count
            let outcome = cycle.observe(order[index])
            if outcome != .pressAgain { return (outcome, presses, order[index]) }
        }
    }

    @Test func cycleStopsOnTheTarget() {
        let order: [ClaudeMode] = [.default, .acceptEdits, .plan, .auto]
        let result = run(order, to: .auto)
        #expect(result.0 == .landed)
        #expect(result.presses == 3)

        let back = run([.auto, .default, .acceptEdits, .plan], to: .default)
        #expect(back.0 == .landed)
        #expect(back.presses == 1)
    }

    @Test func cycleWithoutAutoIsUnavailableAndEndsWhereItStarted() {
        let result = run([.default, .acceptEdits, .plan], to: .auto)
        #expect(result.0 == .unavailable)
        #expect(result.presses == 3)
        #expect(result.endedOn == .default)
    }

    @Test func cycleThatNeverReachesAnotherTargetFails() {
        // From plan mode back to the default in a cycle missing it.
        let result = run([.plan, .auto, .acceptEdits], to: .default)
        #expect(result.0 == .failed)
        #expect(result.endedOn == .plan)
    }

    @Test func cycleGivesUpAfterTooManyPresses() {
        // A screen that never comes back round, as a misread would.
        var cycle = ModeCycle(from: .default, to: .auto)
        var outcomes: [ModeCycle.Outcome] = []
        for _ in 0..<ModeCycle.maxPresses {
            outcomes.append(cycle.observe(.acceptEdits))
        }
        #expect(outcomes.dropLast().allSatisfy { $0 == .pressAgain })
        #expect(outcomes.last == .failed)
    }

    @Test func labels() {
        #expect(ClaudeMode.default.label == "Attended")
        #expect(ClaudeMode.auto.label == "Unattended")
        #expect(ClaudeMode.auto.isUnattended)
        #expect(!ClaudeMode.acceptEdits.isUnattended)
    }
}
