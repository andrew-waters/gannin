import Foundation

/// Anthropic's Claude Code: the interactive provider every session runs on
/// today, and the one that answers Gannin's one-off questions (`claude -p`).
/// Everything that names claude's command line, settings, hooks, transcript
/// folder, modes or sandbox config is here.
struct ClaudeCodeProvider: InteractiveProvider, AskingProvider {
    var providerID: ProviderID { .claudeCode }
    var command: String { "claude" }

    var models: [AIModel] {
        [
            AIModel(id: "claude-fable-5-1", name: "Claude Fable 5.1"),
            AIModel(id: "claude-opus-5-5", name: "Claude Opus 5.5"),
            AIModel(id: "claude-sonnet-5", name: "Claude Sonnet 5"),
            AIModel(id: "claude-haiku-4-5-20251001", name: "Claude Haiku 4.5"),
        ]
    }

    // MARK: Launch

    /// `--model` with the model picked in Settings, applied on each start
    /// and resume (nothing when it's left to Claude Code), and a reviewer's
    /// tools taken away.
    private func options(_ session: CodeSession) -> String {
        var options = SessionStore.model.map { " --model \(SessionScript.quoted($0))" } ?? ""
        // A reviewer reads and reports; it can't change the code.
        var disallowed = session.isReviewer ? ["Edit", "MultiEdit", "Write", "NotebookEdit"] : []
        // A scheduled run goes only as far as its routine's limit lets it.
        if let run = session.routineRun { disallowed += run.disallowedTools }
        if !disallowed.isEmpty { options += " --disallowedTools \(SessionScript.quoted(disallowed.joined(separator: ",")))" }
        return options
    }

    func launch(_ session: CodeSession, settings: String, prompt: String?) -> String {
        let prompt = prompt.map { " " + SessionScript.quoted($0) } ?? ""
        return """
            command -v claude >/dev/null 2>&1 || fail "claude isn't on your PATH. Install Claude Code, then Resume the session."
            if [ -e "$session/started" ]; then
              claude --resume "$id"\(options(session)) --settings \(settings)
            else
              claude --session-id "$id"\(options(session)) --settings \(settings)\(prompt)
            fi
            """
    }

    // MARK: Settings and hooks

    /// The PostToolUse command that records a PR the session opens in `dir`'s
    /// `pr` file. A new PR's URL is in the result of a call that creates one;
    /// only those results are read, since any other call that mentions a PR
    /// (viewing or listing them, a file naming one) would otherwise be
    /// recorded as the session's own. A creating call is a Bash command that
    /// runs, at the start of a command (after `&&`, `;`, `|`, `(`, `$(`, a
    /// backtick or a newline, and any `VAR=value` words):
    /// - `gh pr create`: its result is the new PR's URL, so every URL in it is
    ///   kept.
    /// - `gh api` to a path ending in `/pulls` with `-X POST`, `--method POST`,
    ///   or a `-f`, `-F`, `--field`, `--raw-field` or `--input` (which make gh
    ///   POST), and no `-X GET`, all in that one `gh api` command (up to the
    ///   next `&&`, `;`, `|`, unescaped quote or newline), not elsewhere in
    ///   the call. Its result is the whole PR, body included, so only its
    ///   `html_url` or `url` is kept (a REST object's `url` is on
    ///   api.github.com, so it never matches).
    /// A PR-creating MCP tool (`create_pull_request`) is read the same way: the
    ///   GitHub MCP server's result is a short `{id, url}` object.
    /// Left out, so the session records no PR: a wrapper script, a `gh`
    /// reached through `xargs`, `env` or `then`, a quoted `VAR="a b"` prefix,
    /// and `gh api` with its method or path in a variable.
    ///
    /// Claude Code writes tool_name and tool_input before tool_response, and
    /// the command relies on that order: `SessionPullRequestHookTests` runs it
    /// against JSON in that order and is what would show it change. A tool
    /// call can open more than one PR (one per repo in one command), so every
    /// URL seen is kept, one per line, not just the last.
    static func pullRequestHook(directory dir: String) -> String {
        let signalCode = SessionScript.signalCode
        return #"""
        input=$(cat)
        call=$(printf '%s' "$input" | sed 's/"tool_response".*//')
        has() { printf '%s' "$call" | grep -Eq -- "$1"; }
        # Each `gh api` command on its own line, ending at a separator, an
        # unescaped quote or a newline, so a flag on another command in the same
        # call isn't taken as this one's.
        creates() { printf '%s' "$call" | grep -Eo 'gh api ([^&;|`"\\]|\\[^n])*' | grep -E '/pulls([ ]|\\|$)' | grep -Ei '(-X ?|--method[ =])POST| (-[fF]|--field|--raw-field|--input)[ =]' | grep -Eiv '(-X ?|--method[ =])GET' | grep -q .; }
        start='"tool_name": ?"Bash".*"command": ?"(.*(&&|;|\||\\n|\(|`))? *([A-Za-z_][A-Za-z0-9_]*=[^ ]+ +)*'
        url='https://github\.com/[^"\\ ]+/pull/[0-9]+'
        if has "$start"'gh pr create'; then
          re=$url
        elif has '"tool_name": ?"[^"]*create_pull_request"' || { has "$start"'gh api ' && creates; }; then
          re='"(html_)?url\\*": ?\\*"'"$url"
        else
          exit 0
        fi
        printf '%s' "$input" | sed 's/.*"tool_response"//' | grep -Eo "$re" | grep -Eo "$url" | while IFS= read -r found; do grep -qxF "$found" \#(dir)/pr 2>/dev/null || { printf '%s\n' "$found" >> \#(dir)/pr; printf '\033]\#(signalCode);pr:%s\007' "$found" > /dev/tty 2>/dev/null; }; done
        exit 0
        """#
    }

    /// Claude Code settings for the session: hooks that write its state to
    /// the session's folder and send it through the terminal, the PR it
    /// opens, and a statusLine command that saves Claude Code's own
    /// context-window stats for `SessionTranscript.contextLimit(from:)`.
    /// `isRemote` is whether this runs on a server: the user's own
    /// statusLine command, read from this Mac, wouldn't exist there.
    /// `allowing` is commands it runs without asking (the pair review's
    /// script). `rules` is the session rules' hook command
    /// (`SessionRules.hookCommand`), nil with none set. `sandboxed` adds hooks
    /// that write what claude's doing to the sandbox's activity log
    /// (`SandboxLaunch.activityScript`).
    func settings(directory dir: String, isRemote: Bool, allowing: [String] = [], rules: String? = nil, sandboxed: Bool = false) -> String {
        let signalCode = SessionScript.signalCode
        func signal(_ payload: String) -> String {
            #"printf '\033]\#(signalCode);\#(payload)\007' > /dev/tty 2>/dev/null"#
        }
        func write(_ state: SessionState) -> [String: Any] {
            ["type": "command", "command": "printf \(state.rawValue) > \(dir)/state 2>/dev/null; \(signal("state:" + state.rawValue)); exit 0"] as [String: Any]
        }
        let pullRequest = Self.pullRequestHook(directory: dir)
        func command(_ command: String) -> [String: Any] { ["type": "command", "command": command] }
        func group(_ hooks: [[String: Any]], matcher: String? = nil) -> [String: Any] {
            var group: [String: Any] = ["hooks": hooks]
            group["matcher"] = matcher
            return group
        }
        // Session rules: Claude Code runs every matching hook at once, and a
        // deny wins whatever the order.
        let ruleGroups = rules.map { [group([command($0)], matcher: SessionRules.matcher)] } ?? []
        var hooks: [String: Any] = [
            "SessionStart": [group([write(.idle)])],
            "UserPromptSubmit": [group([command("touch \(dir)/started"), write(.working)])],
            "PostToolUse": [
                group([write(.working)], matcher: "*"),
                group([command(pullRequest)], matcher: "*"),
                // So the Changes pane reads the worktrees now, not on its
                // next slow look.
                // A new value each time, for Gannin to compare.
                group([command("printf %s \"$(date +%s)-$$\" > \(dir)/changed 2>/dev/null; \(signal("changed")); exit 0")], matcher: "Edit|MultiEdit|Write|NotebookEdit|Bash"),
            ],
            // A permission prompt or a dialog, not the reminder after a
            // minute idle, which is still your turn.
            "Notification": [group([write(.needsYou)], matcher: "permission_prompt|elicitation_dialog")],
            // A permission prompt clears the moment its tool is let through,
            // not once it's finished running: a slow command would otherwise
            // leave the card up for as long as the command takes.
            "PreToolUse": ruleGroups + [
                group([write(.working)], matcher: "*"),
                // Its questions, as they're shown; listed after "*" so this
                // wins when both match AskUserQuestion's own tool call.
                group([write(.needsYou)], matcher: "AskUserQuestion"),
            ],
            "Stop": [group([write(.idle)])],
            "SessionEnd": [group([write(.exited)])],
        ]
        if sandboxed {
            // Events and tool names only, never what's in them.
            let activity = [command("[ -x \(SandboxLaunch.activityScriptPath) ] && \(SandboxLaunch.activityScriptPath) hook; exit 0")]
            let matchers: [String: String?] = [
                "SessionStart": nil, "UserPromptSubmit": nil, "PreToolUse": "*", "PostToolUseFailure": "*",
                "Notification": "permission_prompt|elicitation_dialog", "Stop": nil, "SessionEnd": nil,
            ]
            for (event, matcher) in matchers {
                hooks[event] = ((hooks[event] as? [[String: Any]]) ?? []) + [group(activity, matcher: matcher)]
            }
        }
        // Its `context_window` tells Gannin the model's real limit.
        // `--settings` replaces rather than merges a scalar key like
        // `statusLine`, so this would otherwise blank out a statusLine the
        // user set up themselves: run theirs in turn, on the same input,
        // and print its output instead of the model's name. Only for a
        // local session: a server's own command (and its own statusLine)
        // live on that box, not this Mac's `~/.claude/settings.json`.
        let render = (isRemote ? nil : Self.usersStatusLineCommand()).map { #"printf '%s' "$input" | { "# + $0 + "\n}" }
            ?? #"printf '%s' "$input" | sed -n 's/.*"display_name":"\([^"]*\)".*/\1/p' | head -n1"#
        let statusLine = #"input=$(cat); printf '%s' "$input" | tr -d '\n' > \#(dir)/statusline 2>/dev/null; \#(render)"#
        var object: [String: Any] = ["hooks": hooks, "statusLine": ["type": "command", "command": statusLine]]
        if !allowing.isEmpty { object["permissions"] = ["allow": allowing.map { "Bash(\($0):*)" }] }
        let data = (try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// The command behind the user's own statusLine, if they've set one in
    /// `~/.claude/settings.json`.
    private static func usersStatusLineCommand() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/settings.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let statusLine = object["statusLine"] as? [String: Any],
              statusLine["type"] as? String == "command",
              let command = statusLine["command"] as? String else { return nil }
        return command
    }

    // MARK: Transcript

    /// `~/.claude/projects/<folder>/<id>.jsonl`, whichever folder claude
    /// filed it under.
    func transcript(for session: CodeSession, home: URL?) -> URL? {
        let projects = home ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/projects", directoryHint: .isDirectory)
        let folders = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        return folders.lazy.map { $0.appending(path: "\(session.claudeID).jsonl") }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    func remoteTranscripts(for session: CodeSession, sandboxDirectory: String?) -> String {
        // A sandbox's claude keeps its transcripts in its issue's claude-home there.
        (sandboxDirectory.map { $0 + "/\(homeFolder)/projects/*/" + session.claudeID + ".jsonl " } ?? "")
            + #""$HOME"/.claude/projects/*/"# + session.claudeID + ".jsonl"
    }

    func transcriptReader() -> any TranscriptParsing { TranscriptReader() }

    // MARK: Modes and sandbox

    var modes: (any ModeControl)? { ClaudeModes() }

    var sandbox: (any ProviderSandbox)? { self }

    // MARK: One-off questions

    /// Where `claude -p` runs, worked out once.
    @MainActor private static var place: ScriptRunner.Place?

    /// Runs `claude -p` on this Mac when claude is installed here, else on
    /// the server Settings connects to. Everything travels on standard input
    /// (a script that writes the prompt and any files into a folder, then
    /// runs claude there), so nothing is too big for a command line. claude
    /// runs signed in as you, with only the tools it's given. With
    /// `onChunk`, it streams (`--include-partial-messages`) and the return
    /// value is read back from the result event rather than assembled from
    /// the chunks, so a preamble before a tool call doesn't linger.
    @MainActor
    func ask(
        _ prompt: String, org: String, files: [String: Data], folder: String?, tools: [String],
        session: (id: String, resume: Bool)?, model: String?, onChunk: (@MainActor (String) -> Void)?
    ) async throws -> String {
        try NetworkGate.checkProcess()
        let place = try await Self.resolvePlace()
        let body = Self.askScript(prompt, files: files, folder: folder, tools: tools, session: session, model: model, streams: onChunk != nil)

        guard let onChunk else {
            let result = await Task.detached { ScriptRunner.run(body, place: place) }.value
            guard result.status == 0 else {
                throw ScriptRunner.Failure(message: result.error.isEmpty ? "Claude didn't answer (exit \(result.status))." : result.error)
            }
            return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let (stream, continuation) = AsyncStream<String>.makeStream()
        let resultTask = Task.detached {
            let result = ScriptRunner.run(body, place: place) { line in
                if let text = Self.textDelta(in: line) { continuation.yield(text) }
            }
            continuation.finish()
            return result
        }
        for await chunk in stream { onChunk(chunk) }
        let result = await resultTask.value
        guard result.status == 0 else {
            throw ScriptRunner.Failure(message: result.error.isEmpty ? "Claude didn't answer (exit \(result.status))." : result.error)
        }
        let final = result.output.split(separator: "\n").compactMap { Self.finalResult(in: String($0)) }.last
        return (final ?? result.output).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The script `ask` runs: into a folder (a stable one under the
    /// temporary folder to resume in, else a fresh one removed after), the
    /// files and prompt, then claude reading the prompt on stdin.
    static func askScript(_ prompt: String, files: [String: Data], folder: String?, tools: [String], session: (id: String, resume: Bool)?, model: String?, streams: Bool) -> String {
        var options: [String] = ["-p"]
        options += streams
            ? ["--output-format", "stream-json", "--include-partial-messages", "--verbose"]
            : ["--output-format", "text"]
        if let model { options += ["--model", model] }
        if !tools.isEmpty { options += ["--allowedTools", tools.joined(separator: ",")] }
        if let session { options += [session.resume ? "--resume" : "--session-id", session.id] }

        var script = ["set -e"]
        if let folder {
            let safe = String(folder.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
            script.append(#"d="${TMPDIR:-/tmp}/"# + safe + #"""#)
            script.append(#"mkdir -p "$d""#)
        } else {
            script.append(#"d=$(mktemp -d "${TMPDIR:-/tmp}/gannin-claude.XXXXXX")"#)
            script.append(#"trap 'rm -rf "$d"' EXIT"#)
        }
        script.append(#"cd "$d""#)
        for (path, data) in files.sorted(by: { $0.key < $1.key }) {
            let quoted = SessionScript.quoted(path)
            script.append("mkdir -p \"$(dirname \(quoted))\"")
            script.append("printf %s \(data.base64EncodedString()) | base64 -d > \(quoted)")
        }
        script.append("printf %s \(Data(prompt.utf8).base64EncodedString()) | base64 -d > .gannin-prompt")
        script.append("command -v claude >/dev/null 2>&1 || { echo 'claude is not installed here' >&2; exit 127; }")
        script.append("claude \(options.map(SessionScript.quoted).joined(separator: " ")) < .gannin-prompt")
        return script.joined(separator: "\n") + "\n"
    }

    /// Here if `claude` is on this Mac's PATH, else the server.
    @MainActor
    private static func resolvePlace() async throws -> ScriptRunner.Place {
        if let place { return place }
        let found = await Task.detached { ScriptRunner.run("command -v claude", place: .local) }.value
        if found.status == 0, !found.output.isEmpty {
            place = .local
        } else if let connect = SessionStore.connectCommand, let arguments = Shell.sshArguments(connect) {
            place = .remote(arguments)
        } else {
            throw ScriptRunner.Failure(message: "Claude Code isn't installed on this Mac, and Settings doesn't connect to a server that has it.")
        }
        return place!
    }

    /// A `--output-format stream-json` line, read leniently: only the
    /// fields `textDelta` and `finalResult` use are declared.
    private nonisolated struct StreamLine: Decodable {
        nonisolated struct Event: Decodable {
            nonisolated struct Delta: Decodable {
                let type: String?
                let text: String?
            }
            let type: String
            let delta: Delta?
        }
        let type: String
        let event: Event?
        let result: String?
    }

    /// The text claude just wrote, from a `content_block_delta` stream
    /// event; nil for any other line (tool calls, turn boundaries, usage).
    private nonisolated static func textDelta(in line: String) -> String? {
        guard let parsed = try? JSONDecoder().decode(StreamLine.self, from: Data(line.utf8)),
              parsed.type == "stream_event", parsed.event?.type == "content_block_delta",
              parsed.event?.delta?.type == "text_delta" else { return nil }
        return parsed.event?.delta?.text
    }

    /// The whole reply, from the `result` line stream-json ends with.
    private nonisolated static func finalResult(in line: String) -> String? {
        guard let parsed = try? JSONDecoder().decode(StreamLine.self, from: Data(line.utf8)), parsed.type == "result" else { return nil }
        return parsed.result
    }
}

/// Claude Code's modes: read off its footer, cycled with Shift+Tab.
struct ClaudeModes: ModeControl {
    func mode(fromFooter lines: [String]) -> ClaudeMode? { ClaudeMode.fromFooter(lines) }
    var cycleKey: String { TerminalKeys.shiftTab }
}

extension ClaudeCodeProvider: ProviderSandbox {
    var configHome: String { "/root/.claude" }
    var homeFolder: String { "claude-home" }
    var configVariable: String { "CLAUDE_CONFIG_DIR" }

    /// Claude Code's shared config, kept past first-run prompts: onboarding
    /// done, this harness trusted (added beside others'), and an API key
    /// approved when one is passed in. Nothing comes from anyone's own
    /// `~/.claude`. Needs `$harness` and `$CLAUDE_CONFIG_DIR`.
    static let seedConfig = """
        cfg="$CLAUDE_CONFIG_DIR/.claude.json"
        [ -s "$cfg" ] || echo '{}' > "$cfg"
        jq --arg h "$harness" --arg k "${ANTHROPIC_API_KEY: -20}" \\
          '.hasCompletedOnboarding = true | .theme = (.theme // "dark")
           | .projects[$h] = ((.projects[$h] // {}) + {hasTrustDialogAccepted: true, hasCompletedProjectOnboarding: true})
           | if $k == "" then . else .customApiKeyResponses.approved = (((.customApiKeyResponses.approved // []) + [$k]) | unique) end' \\
          "$cfg" > "$cfg.$$" && mv "$cfg.$$" "$cfg"
        """

    var prepare: String {
        """
        \(Self.seedConfig)
        # One Claude credential at most: an API key, or claude's own login.
        unset CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_AUTH_TOKEN
        if [ -z "${ANTHROPIC_API_KEY:-}" ] && [ ! -f "$CLAUDE_CONFIG_DIR/.credentials.json" ]; then
          note "Claude isn't signed in in your sandboxes yet. When it asks, choose your Claude account, open the link it shows, sign in, and paste the code back. Your other sandboxes stay signed in."
          activity "Waiting for you: Claude needs signing in, in the session's terminal"
        fi
        """
    }
}
