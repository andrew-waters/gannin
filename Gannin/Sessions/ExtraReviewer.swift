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
    /// or why there isn't one, with what the CLI printed when that's the
    /// reason.
    enum Outcome: Equatable {
        case findings([SessionTranscript.Finding])
        case failed(String, output: String? = nil)
    }

    /// The end of what a CLI printed, kept for the panel: a failed run's
    /// reply can be long, and it's saved with the pairing.
    static func shown(_ output: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.suffix(8_000))
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

    /// The review prompt, ended the way the reviewer must answer. Junie
    /// writes its final summary to a fixed template and leaves out a list
    /// asked for in its reply, so the list is asked for in the summary
    /// itself, which is all `outcome(for:)` reads.
    func prompt(_ review: String) -> String {
        review + """


            Your final task summary (the text you finish with, not an earlier message) must contain, as its last section, the findings as a fenced ```json block, written out in full. \
            When there's nothing to fix, that block is an empty list (`[]`).
            """
    }

    /// Sent to Junie's session when its final summary had no fenced list.
    static let reminder = """
        Your final task summary didn't end with the findings as a fenced ```json block. \
        Reply with your findings as that block, written out in full (an empty list, `[]`, when there's nothing to fix).
        """
    /// Seconds a run must have left for Junie to be asked again.
    static let minimumRetry = 60

    /// A bash script that copies `folder`, runs the CLI in the copy and
    /// prints its result file; the copy is removed however it ends. The
    /// CLI's own stdout is discarded: with Junie it is coloured text
    /// whatever the output format is.
    ///
    /// If the result has no fenced list, the session it names (`sessionId`)
    /// is asked once more for it, within `timeout` in all.
    ///
    /// A worktree's `.git` file points at its admin directory in the main
    /// clone, so a git command run in a plain copy would change the real
    /// index, HEAD and branch. Each `.git` file in the copy is pointed at a
    /// private copy of that admin directory and of the clone's refs and
    /// config instead, borrowing the clone's objects read only (an
    /// alternate), so commits, checkouts and resets stay in the copy.
    ///
    /// `slack` is how many seconds past `timeout` the CLI is left before it
    /// is stopped, if it hasn't stopped itself.
    ///
    /// The copy lives in a folder named for `tag`, which `cancelScript(tag:)`
    /// finds to stop this run early.
    func script(folder: URL, prompt: String, tag: String = UUID().uuidString, timeout: TimeInterval = ExtraReviewer.timeout, slack: Int = 30) -> String {
        switch self {
        case .junie:
            let source = SessionScript.quoted(folder.path)
            return [
                "d=\(workFolder(tag: tag))",
                #"mkdir -m 700 "$d" || exit 1"#,
                #"trap 'rm -rf "$d"' EXIT"#,
                "src=\(source)",
                "command -v junie >/dev/null 2>&1 || { echo 'junie is not installed on this Mac (not found on PATH)' >&2; exit 127; }",
                // A copy-on-write clone where the volume has them, which is
                // quick however big the worktrees are.
                #"cp -cRP "$src" "$d/project" 2>/dev/null || { rm -rf "$d/project"; cp -RP "$src" "$d/project"; } || { echo "Couldn't copy the worktree" >&2; exit 1; }"#,
                #"n=0"#,
                #"find "$d/project" -maxdepth 3 -name .git -type f | while IFS= read -r f; do"#,
                #"  n=$((n + 1))"#,
                #"  gitdir=$(sed -n 's/^gitdir: //p' "$f")"#,
                // A relative gitdir is relative to where the file was copied from.
                #"  case "$gitdir" in /*) ;; *) gitdir="$(dirname "$src${f#"$d/project"}")/$gitdir" ;; esac"#,
                // Only a linked worktree has a commondir. A submodule's or a
                // separate git dir's `.git` is left as it was, so isn't isolated.
                #"  [ -f "$gitdir/commondir" ] || continue"#,
                #"  common=$(cd "$gitdir" && cd "$(cat "$gitdir/commondir")" && pwd -P) || exit 1"#,
                #"  g="$d/git/$n""#,
                #"  mkdir -p "$g" || exit 1"#,
                #"  rsync -a --exclude /objects --exclude /worktrees --exclude /lfs "$common/" "$g/common/" || exit 1"#,
                #"  mkdir -p "$g/common/objects/info" && echo "$common/objects" > "$g/common/objects/info/alternates" || exit 1"#,
                #"  cp -RP "$gitdir" "$g/admin" || exit 1"#,
                #"  echo "$g/common" > "$g/admin/commondir" && echo "$f" > "$g/admin/gitdir" && echo "gitdir: $g/admin" > "$f" || exit 1"#,
                "done || { echo \"Couldn't set up git in the copy\" >&2; exit 1; }",
                "printf %s \(Data(prompt.utf8).base64EncodedString()) | base64 -d > \"$d/prompt\"",
                // Job control, so the CLI and everything it starts are a process
                // group that can be stopped together. It stops bash giving a
                // background job no stdin, and this script is itself read from
                // stdin, so the CLI is given none: it could read the rest of it.
                "set -m",
                "printf %s \(Data(Self.reminder.utf8).base64EncodedString()) | base64 -d > \"$d/reminder\"",
                // Stopped while it was being copied: don't start it.
                #"[ -e "$d/cancel" ] && exit 130"#,
                // `run_junie <seconds> <result file> <junie arguments>`, leaving
                // how it ended in `$status`. Not run in a subshell, which has
                // no job control, so the watchdog's group couldn't be stopped.
                "run_junie() {",
                "  secs=$1; out=$2; shift 2",
                #"  junie --project "$d/project" --output-format json --json-output-file "$out" --timeout $((secs * 1000)) --skip-update-check "$@" </dev/null >"$d/stdout" 2>"$d/stderr" &"#,
                "  pid=$!",
                #"  echo $pid > "$d/pid""#,
                // Stopped in the moment before the pid was written.
                #"  [ -e "$d/cancel" ] && kill -TERM -$pid 2>/dev/null"#,
                "  ( sleep $((secs + \(slack))); kill -TERM -$pid 2>/dev/null ) &",
                "  watchdog=$!",
                // Disowned, so bash doesn't print a job notice for it into the error text.
                "  disown $watchdog",
                "  wait $pid",
                "  status=$?",
                // The watchdog's group, so its sleep goes too, and anything the
                // CLI left running.
                "  kill -TERM -$watchdog 2>/dev/null",
                "  kill -TERM -$pid 2>/dev/null",
                "}",
                "SECONDS=0",
                #"run_junie \#(Int(timeout)) "$d/result.json" "$(cat "$d/prompt")""#,
                #"[ "$status" -eq 143 ] && { echo 'timed out' >&2; exit \#(Self.timedOut); }"#,
                #"if [ "$status" -ne 0 ]; then"#,
                #"  if [ -s "$d/stderr" ]; then tail -n 3 "$d/stderr" >&2; else tail -n 3 "$d/stdout" | LC_ALL=C sed $'s/\033\\[[0-9;]*[A-Za-z]//g' >&2; fi"#,
                "  exit $status",
                "fi",
                // No fenced list (the fence opens a JSON list, `\n` being how the
                // result file writes a newline): ask the session named in the
                // result file once more for it, if the run left time. Never
                // `--resume` alone, which takes Junie's newest session whoever
                // started it. A retry that fails leaves the first result to be
                // read as it was.
                #"left=$((\#(Int(timeout)) - SECONDS))"#,
                #"sid=$(sed -n 's/.*"sessionId": *"\([^"]*\)".*/\1/p' "$d/result.json")"#,
                #"if [ -n "$sid" ] && ! grep -Eq '```json(\\n|[[:space:]])*\[' "$d/result.json" && [ "$left" -ge \#(Self.minimumRetry) ] && [ ! -e "$d/cancel" ]; then"#,
                #"  run_junie "$left" "$d/retry.json" --session-id "$sid" --resume "--task=$(cat "$d/reminder")""#,
                #"  [ "$status" -eq 0 ] && [ -s "$d/retry.json" ] && mv "$d/retry.json" "$d/result.json""#,
                "fi",
                #"cat "$d/result.json""#,
            ].joined(separator: "\n") + "\n"
        }
    }

    /// Where a run's copy and files are, as a shell word.
    private func workFolder(tag: String) -> String {
        #""${TMPDIR:-/tmp}/gannin-\#(rawValue).\#(tag)""#
    }

    /// A bash script that stops the run `script(tag:)` made, the CLI and
    /// everything it started, so a round you stopped doesn't go on using CPU
    /// and quota. The run's script then ends and removes its copy. It does
    /// nothing for a run that has already ended.
    func cancelScript(tag: String) -> String {
        [
            "d=\(workFolder(tag: tag))",
            #"[ -d "$d" ] || exit 0"#,
            #"touch "$d/cancel""#,
            #"read -r pid < "$d/pid" 2>/dev/null && kill -TERM -- "-$pid" 2>/dev/null"#,
            "exit 0",
        ].joined(separator: "\n") + "\n"
    }

    /// The findings in what a run printed (its result file), or why there
    /// are none: Junie's file has the final text as `result`, with the list
    /// in a fenced `json` block.
    func outcome(for run: Result) -> Outcome {
        switch run.status {
        case 0:
            break
        case 127:
            return .failed(run.error.isEmpty ? "\(title) isn't installed on this Mac." : run.error, output: Self.shown(run.output))
        case Self.timedOut:
            return .failed("\(title) timed out after \(Int(Self.timeout / 60)) minutes.", output: Self.shown(run.output))
        default:
            let why = run.error.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(why.isEmpty ? "\(title) failed (exit \(run.status))." : "\(title) failed: \(why)", output: Self.shown(run.output))
        }
        struct Output: Decodable { let result: String? }
        guard let output = try? JSONDecoder().decode(Output.self, from: Data(run.output.utf8)), let reply = output.result else {
            return .failed("\(title) didn't write a result.", output: Self.shown(run.output))
        }
        guard let findings = ScriptRunner.json([SessionTranscript.Finding].self, in: reply) else {
            return .failed("\(title) replied with no list of findings.", output: Self.shown(reply))
        }
        return .findings(findings)
    }

    /// One round: copies, runs and reads. A run that hasn't finished
    /// `limit` seconds in is given up on (its script stops the CLI soon
    /// after, and removes the copy). `tag` names the run for `cancelScript`.
    func review(folder: URL, prompt: String, tag: String = UUID().uuidString, limit: TimeInterval = ExtraReviewer.timeout + ExtraReviewer.grace, run: @escaping Runner) async -> Outcome {
        let script = script(folder: folder, prompt: self.prompt(prompt), tag: tag)
        let finished: Result? = await withCheckedContinuation { continuation in
            let once = Once()
            let timer = Task {
                do { try await Task.sleep(for: .seconds(limit)) } catch { return }
                if once.first() { continuation.resume(returning: nil) }
            }
            Task {
                let result = await run(script)
                if once.first() { continuation.resume(returning: result) }
                // Not left sleeping out the limit.
                timer.cancel()
            }
        }
        guard let finished else { return .failed("\(title) timed out after \(Int(Self.timeout / 60)) minutes.") }
        return outcome(for: finished)
    }
}

extension ExtraReviewer: OneShotReviewer {
    var providerID: ProviderID {
        switch self {
        case .junie: .junie
        }
    }

    /// It picks its own.
    var models: [AIModel] { [] }
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
