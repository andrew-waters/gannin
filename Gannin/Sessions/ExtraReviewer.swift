import Foundation

/// A built-in extra reviewer for pair reviews: another agent, from a CLI
/// installed on this Mac, that looks at the change alongside the claude
/// reviewer. Adding one is a code change, since each has its own command
/// line and output.
///
/// It runs once a round as a one-shot process in a throwaway copy of the
/// session's worktree, so whatever it edits is discarded, and returns its
/// findings as the fenced JSON list the claude reviewer ends with.
enum ExtraReviewer: String, CaseIterable, Identifiable, Codable, Hashable {
    case junie

    var id: String { rawValue }

    /// As the panel and settings name it.
    var title: String {
        switch self {
        case .junie: "Junie"
        }
    }

    /// What its run produced: a findings list (empty when nothing's left),
    /// or why there isn't one.
    enum Outcome: Equatable {
        case findings([SessionTranscript.Finding])
        case failed(String)
    }

    /// A finished script: its exit status and what it printed.
    typealias Result = (status: Int32, output: String, error: String)
    typealias Runner = @Sendable (String) async -> Result

    /// How long the CLI is asked to work.
    static let timeout: TimeInterval = 600
    /// How much longer a run is waited for after that, so a hung one
    /// can't hold the round.
    static let grace: TimeInterval = 60
    /// Exit status the script gives when it had to stop the CLI.
    static let timedOut: Int32 = 124

    /// The review prompt, ended the way the reviewer must answer.
    func prompt(_ review: String) -> String {
        review + "\n\nWhen there's nothing to fix, end with an empty list (`[]`)."
    }

    /// A bash script that copies `folder`, runs the CLI in the copy and
    /// prints its result file; the copy is removed however it ends. The
    /// CLI's own stdout is discarded: with Junie it is coloured text
    /// whatever the output format is.
    func script(folder: URL, prompt: String) -> String {
        switch self {
        case .junie:
            let milliseconds = Int(Self.timeout) * 1000
            // The CLI stops itself at its own timeout; this stops it a little
            // later if it hasn't.
            let watchdog = Int(Self.timeout) + 30
            return [
                #"d=$(mktemp -d "${TMPDIR:-/tmp}/gannin-junie.XXXXXX")"#,
                #"trap 'rm -rf "$d"' EXIT"#,
                "command -v junie >/dev/null 2>&1 || { echo 'junie is not installed on this Mac (not found on PATH)' >&2; exit 127; }",
                // A copy-on-write clone where the volume has them, which is
                // quick however big the worktrees are.
                "cp -cRP \(SessionScript.quoted(folder.path)) \"$d/project\" 2>/dev/null || { rm -rf \"$d/project\"; cp -RP \(SessionScript.quoted(folder.path)) \"$d/project\"; } || { echo \"Couldn't copy the worktree\" >&2; exit 1; }",
                "printf %s \(Data(prompt.utf8).base64EncodedString()) | base64 -d > \"$d/prompt\"",
                #"junie --project "$d/project" --output-format json --json-output-file "$d/result.json" --timeout \#(milliseconds) --skip-update-check "$(cat "$d/prompt")" >"$d/stdout" 2>"$d/stderr" &"#,
                "pid=$!",
                "( sleep \(watchdog); kill $pid 2>/dev/null ) &",
                "watchdog=$!",
                // Disowned, so bash doesn't print a job notice for it into the error text.
                "disown $watchdog",
                "wait $pid",
                "status=$?",
                "kill $watchdog 2>/dev/null",
                #"[ "$status" -eq 143 ] && { echo 'timed out' >&2; exit \#(Self.timedOut); }"#,
                #"if [ "$status" -ne 0 ]; then"#,
                #"  if [ -s "$d/stderr" ]; then tail -n 3 "$d/stderr" >&2; else tail -n 3 "$d/stdout" | LC_ALL=C sed $'s/\033\\[[0-9;]*[A-Za-z]//g' >&2; fi"#,
                "  exit $status",
                "fi",
                #"cat "$d/result.json""#,
            ].joined(separator: "\n") + "\n"
        }
    }

    /// The findings in what a run printed (its result file), or why there
    /// are none: Junie's file has the final text as `result`, with the list
    /// in a fenced `json` block.
    func outcome(for run: Result) -> Outcome {
        switch run.status {
        case 0:
            break
        case 127:
            return .failed(run.error.isEmpty ? "\(title) isn't installed on this Mac." : run.error)
        case Self.timedOut:
            return .failed("\(title) timed out after \(Int(Self.timeout / 60)) minutes.")
        default:
            let why = run.error.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(why.isEmpty ? "\(title) failed (exit \(run.status))." : "\(title) failed: \(why)")
        }
        struct Output: Decodable { let result: String? }
        guard let output = try? JSONDecoder().decode(Output.self, from: Data(run.output.utf8)), let reply = output.result else {
            return .failed("\(title) didn't write a result.")
        }
        guard let findings = ClaudeRunner.json([SessionTranscript.Finding].self, in: reply) else {
            return .failed("\(title) replied with no list of findings.")
        }
        return .findings(findings)
    }

    /// One round: copies, runs and reads. A run that hasn't finished
    /// `limit` seconds in is given up on (its script stops the CLI soon
    /// after, and removes the copy).
    func review(folder: URL, prompt: String, limit: TimeInterval = ExtraReviewer.timeout + ExtraReviewer.grace, run: @escaping Runner) async -> Outcome {
        let script = script(folder: folder, prompt: self.prompt(prompt))
        let finished: Result? = await withCheckedContinuation { continuation in
            let once = Once()
            Task {
                let result = await run(script)
                if once.first() { continuation.resume(returning: result) }
            }
            Task {
                try? await Task.sleep(for: .seconds(limit))
                if once.first() { continuation.resume(returning: nil) }
            }
        }
        guard let finished else { return .failed("\(title) timed out after \(Int(Self.timeout / 60)) minutes.") }
        return outcome(for: finished)
    }
}

/// True once, to whoever asks first.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false

    func first() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
    }
}
