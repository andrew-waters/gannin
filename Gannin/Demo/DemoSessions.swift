import Foundation

/// The demo build's Claude Code sessions: one working, one waiting on you,
/// one done, each on a fixture issue with an invented transcript, screen
/// and changes. Nothing runs claude, git or gh: the screen is fed to a
/// terminal with no process (`SessionTerminal.replay`) and the changes
/// stand in for git's output (`SessionChanges.show`).
enum DemoSessions {
    struct Changes {
        /// What `SessionChanges.listScript` would print.
        let list: String
        /// Each file's unified diff, by path.
        let diffs: [String: String]
    }

    struct Fixture {
        let session: CodeSession
        let state: SessionState
        let waitingSince: Date?
        let transcript: SessionTranscript
        /// The terminal at a width in columns.
        let screen: (Int) -> String
        let changes: Changes
    }

    /// The working session, which the session shot shows.
    static let workingID = UUID(uuidString: "D3E0C0DE-0334-4000-8000-000000000001")!
    static let waitingID = UUID(uuidString: "D3E0C0DE-0334-4000-8000-000000000002")!
    static let doneID = UUID(uuidString: "D3E0C0DE-0334-4000-8000-000000000003")!

    static var changes: [UUID: Changes] {
        Dictionary(uniqueKeysWithValues: fixtures.map { ($0.session.id, $0.changes) })
    }

    /// Puts the sessions in the store, the working one's tab showing.
    static func show(in store: SessionStore) {
        for fixture in fixtures {
            store.showFixture(fixture.session, state: fixture.state, waitingSince: fixture.waitingSince,
                              transcript: fixture.transcript, screen: fixture.screen)
        }
        store.selectedTab = workingID
    }

    // MARK: Building

    private static func ago(minutes: Double) -> Date { DemoFixture.now.addingTimeInterval(-minutes * 60) }

    private static func session(_ id: UUID, issue number: Int, minutesAgo: Double) -> CodeSession {
        let issue = DemoFixture.issues.first { $0.number == number }!
        let reference = IssueReference(org: DemoFixture.org, id: issue.id, number: issue.number, title: issue.title, repo: issue.repo, url: issue.url)
        return CodeSession(id: id, issue: reference, repo: issue.repo, branch: SessionStore.branchName(reference),
                           createdAt: ago(minutes: minutesAgo), lastActiveAt: ago(minutes: 1))
    }

    private static func event(_ n: Int, _ kind: SessionTranscript.Event.Kind, _ minutesAgo: Double, _ text: String, failed: Bool? = false) -> SessionTranscript.Event {
        SessionTranscript.Event(id: "demo-\(n)", kind: kind, at: ago(minutes: minutesAgo), text: text,
                                failed: kind == .prompt || kind == .reply ? nil : failed)
    }

    /// One worktree's changes as `listScript` prints them.
    private static func list(_ files: [(status: String, added: Int, removed: Int, path: String)], unpushed: Int?) -> String {
        let rs = "\u{1E}"
        var lines = ["\(rs)worktree\t.", "\(rs)base\t4f2c9a1\torigin/main", "\(rs)push\t\(unpushed.map(String.init) ?? "-")", "\(rs)staged", "\(rs)status"]
        lines += files.map { "\($0.status)\t\($0.path)" }
        lines.append("\(rs)numstat")
        lines += files.map { "\($0.added)\t\($0.removed)\t\($0.path)" }
        lines.append("\(rs)untracked")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Screens

    private static let esc = "\u{1B}["
    private static let orange = "\(esc)38;5;174m", grey = "\(esc)38;5;246m", bold = "\(esc)1m",
                       green = "\(esc)38;5;114m", red = "\(esc)38;5;203m", violet = "\(esc)38;5;141m", reset = "\(esc)0m"
    private static let promptBand = "\(esc)48;5;237m", addedBand = "\(esc)48;5;22m"
    /// Starts a line `terminal` fills to the full width with a background.
    private static let bandMark = "\u{1}"

    /// Claude Code's screen at a width: the conversation, then the input
    /// between two rules and the mode line under it, as wide as the
    /// terminal.
    private static func terminal(_ lines: [String]) -> (Int) -> String {
        { columns in
            let width = max(columns, 40)
            let rule = grey + String(repeating: "─", count: width) + reset
            let body = lines.map { line -> String in
                let parts = line.split(separator: bandMark, maxSplits: 2, omittingEmptySubsequences: false)
                guard parts.count == 3 else { return line }
                let band = String(parts[1]), text = String(parts[2])
                let padding = max(0, width - visibleCount(text))
                return band + text.replacingOccurrences(of: reset, with: reset + band) + String(repeating: " ", count: padding) + reset
            }
            return (body + [
                "",
                rule,
                "\(bold)>\(reset) \(esc)7m \(reset)",
                rule,
                "  \(violet)⏵⏵ auto mode on\(reset)\(grey) (shift+tab to cycle)\(reset)",
            ]).joined(separator: "\r\n")
        }
    }

    /// Characters a line shows, leaving out its colour codes.
    private static func visibleCount(_ text: String) -> Int {
        text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression).count
    }

    private static func band(_ background: String, _ text: String) -> String { bandMark + background + bandMark + text }

    private static func prompt(_ text: String) -> String { band(promptBand, "\(grey)>\(reset) \(text)") }
    private static func said(_ text: String) -> String { "⏺ \(text)" }
    private static func tool(_ name: String, _ arg: String, failed: Bool = false) -> String {
        "\(failed ? red : green)⏺\(reset) \(bold)\(name)\(reset)(\(arg))"
    }
    private static func result(_ text: String) -> String { "  \(grey)⎿\(reset)  \(text)" }
    /// A diff line under an Update, as Claude Code numbers and shades it.
    private static func diff(_ number: Int, _ text: String, added: Bool = false) -> String {
        let line = "      \(grey)\(number)\(reset) \(added ? "+" : " ") \(text)"
        return added ? band(addedBand, line) : line
    }

    // MARK: The sessions

    static let fixtures: [Fixture] = [working, waiting, done]

    private static var working: Fixture {
        var transcript = SessionTranscript()
        transcript.model = "claude-opus-5-5"
        transcript.costUSD = 1.84
        transcript.contextTokens = 61_000
        transcript.workingSeconds = 14 * 60
        transcript.waitingSeconds = 3 * 60
        transcript.filesEdited = ["src/board/PilotTimes.tsx", "src/board/ArrivalsBoard.tsx", "src/api/pilots.ts"]
        transcript.lastCheck = SessionTranscript.Check(command: "npm test -- board", passed: true, at: ago(minutes: 2))
        transcript.lastReply = "The pilot boarding time now shows under each arrival, with a dash when none is booked yet."
        transcript.events = [
            event(1, .prompt, 18, "Work on lumen-harbor/beacon-web#181: Show pilot boarding times"),
            event(2, .tool(name: "Read"), 17, "src/board/ArrivalsBoard.tsx"),
            event(3, .tool(name: "Grep"), 16, "pilotBoarding"),
            event(4, .reply, 15, "The arrivals board has no pilot data yet. I'll add a pilots endpoint client, then a column."),
            event(5, .tool(name: "Write"), 12, "src/api/pilots.ts"),
            event(6, .tool(name: "Edit"), 9, "src/board/ArrivalsBoard.tsx"),
            event(7, .tool(name: "Write"), 6, "src/board/PilotTimes.tsx"),
            event(8, .tool(name: "Bash"), 2, "npm test -- board"),
            event(9, .reply, 1, "The pilot boarding time now shows under each arrival, with a dash when none is booked yet."),
            event(10, .tool(name: "Edit"), 0.3, "src/board/PilotTimes.test.tsx", failed: nil),
        ]
        let screen = terminal([
            prompt("Work on lumen-harbor/beacon-web#181: Show pilot boarding times"),
            "",
            said("I'll read the arrivals board first to see where the times would go."),
            "",
            tool("Read", "src/board/ArrivalsBoard.tsx"),
            result("Read 214 lines"),
            "",
            tool("Grep", "pattern: \"pilotBoarding\""),
            result("Found 0 files"),
            "",
            said("The board has no pilot data yet. I'll add a small client for the pilots"),
            "  endpoint, then a column that shows each arrival's boarding time.",
            "",
            tool("Write", "src/api/pilots.ts"),
            result("Wrote 38 lines to src/api/pilots.ts"),
            "",
            tool("Update", "src/board/ArrivalsBoard.tsx"),
            result("Updated src/board/ArrivalsBoard.tsx with 12 additions and 3 removals"),
            diff(88, "    <ArrivalRow arrival={arrival}>"),
            diff(89, "      <PilotTimes boarding={pilots[arrival.vessel]} />", added: true),
            diff(90, "    </ArrivalRow>"),
            "",
            tool("Bash", "npm test -- board"),
            result("\(green)✓\(reset) 24 passed (1.9s)"),
            "",
            said("The pilot boarding time now shows under each arrival, with a dash when"),
            "  none is booked yet. Adding a test for the late-booking case next.",
            "",
            "\(orange)✻ Writing tests…\(reset) \(grey)(38s · ↓ 1.2k tokens · esc to interrupt)\(reset)",
        ])
        let changes = Changes(
            list: list([("A", 38, 0, "src/api/pilots.ts"), ("M", 12, 3, "src/board/ArrivalsBoard.tsx"), ("A", 46, 0, "src/board/PilotTimes.tsx")], unpushed: nil),
            diffs: ["src/api/pilots.ts": """
                diff --git a/src/api/pilots.ts b/src/api/pilots.ts
                new file mode 100644
                --- /dev/null
                +++ b/src/api/pilots.ts
                @@ -0,0 +1,12 @@
                +import { get } from "./client";
                +
                +export interface PilotBooking {
                +  vessel: string;
                +  boardingAt: string | null;
                +}
                +
                +/** Each arriving vessel's pilot booking, by vessel. */
                +export async function pilotBookings(day: string): Promise<Record<string, PilotBooking>> {
                +  const bookings = await get<PilotBooking[]>(`/pilots?day=${day}`);
                +  return Object.fromEntries(bookings.map((b) => [b.vessel, b]));
                +}
                """]
        )
        return Fixture(session: session(workingID, issue: 181, minutesAgo: 18), state: .working, waitingSince: nil,
                       transcript: transcript, screen: screen, changes: changes)
    }

    private static var waiting: Fixture {
        var transcript = SessionTranscript()
        transcript.model = "claude-opus-5-5"
        transcript.costUSD = 0.92
        transcript.contextTokens = 34_000
        transcript.workingSeconds = 7 * 60
        transcript.filesEdited = ["reports/totals.py"]
        transcript.lastCheck = SessionTranscript.Check(command: "pytest reports", passed: false, at: ago(minutes: 6))
        transcript.question = SessionTranscript.Question(id: "demo-question", items: [
            SessionTranscript.Question.Item(
                header: "Boundaries",
                question: "Should a shift that runs past midnight on the last day count towards that month or the next?",
                options: [
                    SessionTranscript.Question.Option(label: "The month it started", description: "Matches the harbour board's paper reports."),
                    SessionTranscript.Question.Option(label: "Split by hours", description: "More exact, but totals change for past months."),
                ],
                multiSelect: false
            ),
        ])
        transcript.events = [
            event(1, .prompt, 12, "Work on lumen-harbor/chart-room#46: Totals off by one on month boundaries"),
            event(2, .tool(name: "Read"), 11, "reports/totals.py"),
            event(3, .tool(name: "Bash"), 6, "pytest reports", failed: true),
            event(4, .reply, 5, "The off-by-one is a shift crossing midnight on the last day. Which month should it count towards?"),
        ]
        let screen = terminal([
            prompt("Work on lumen-harbor/chart-room#46: Totals off by one on month boundaries"),
            "",
            tool("Read", "reports/totals.py"),
            result("Read 96 lines"),
            "",
            tool("Bash", "pytest reports", failed: true),
            result("\(red)1 failed\(reset), 11 passed: test_month_totals_include_overnight_shift"),
            "",
            said("The off-by-one is a shift crossing midnight on the last day of the month:"),
            "  it's counted in both months. Before I fix it, which month should it count towards?",
        ])
        let changes = Changes(list: list([("M", 9, 4, "reports/totals.py")], unpushed: nil), diffs: [:])
        return Fixture(session: session(waitingID, issue: 46, minutesAgo: 12), state: .needsYou, waitingSince: ago(minutes: 5),
                       transcript: transcript, screen: screen, changes: changes)
    }

    private static var done: Fixture {
        var transcript = SessionTranscript()
        transcript.model = "claude-opus-5-5"
        transcript.costUSD = 2.37
        transcript.contextTokens = 88_000
        transcript.workingSeconds = 21 * 60
        transcript.filesEdited = ["deploy/registry.tf", "docs/credentials.md"]
        transcript.lastCheck = SessionTranscript.Check(command: "terraform validate", passed: true, at: ago(minutes: 40))
        transcript.lastReply = "Opened lumen-harbor/dockyard#106: the registry credentials now rotate every 30 days, documented in docs/credentials.md."
        transcript.events = [
            event(1, .prompt, 70, "Work on lumen-harbor/dockyard#88: Rotate the registry credentials"),
            event(2, .tool(name: "Edit"), 55, "deploy/registry.tf"),
            event(3, .tool(name: "Bash"), 40, "terraform validate"),
            event(4, .reply, 35, "Opened lumen-harbor/dockyard#106: the registry credentials now rotate every 30 days, documented in docs/credentials.md."),
        ]
        let screen = terminal([
            prompt("Work on lumen-harbor/dockyard#88: Rotate the registry credentials"),
            "",
            tool("Bash", "terraform validate"),
            result("\(green)Success!\(reset) The configuration is valid."),
            "",
            said("Opened lumen-harbor/dockyard#106: the registry credentials now rotate every"),
            "  30 days, documented in docs/credentials.md.",
        ])
        let changes = Changes(list: list([("M", 22, 6, "deploy/registry.tf"), ("A", 31, 0, "docs/credentials.md")], unpushed: 0), diffs: [:])
        return Fixture(session: session(doneID, issue: 88, minutesAgo: 70), state: .idle, waitingSince: ago(minutes: 35),
                       transcript: transcript, screen: screen, changes: changes)
    }
}
