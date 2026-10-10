import Foundation

/// What a session's terminal runs, and the hooks claude reports through.
/// Paths are shell expressions (`"$HOME"/'Gannin'`), so the same script
/// runs on this Mac or on a server reached with the Connect with command.
enum SessionScript {
    /// The escape code the hooks send through the terminal (OSC 7777).
    /// Claude Code runs hooks with no terminal, so from a hook it rarely
    /// arrives; the files they write are what Gannin reads, over ssh for a
    /// server (`SessionStore.poll`). The start script's own do arrive:
    /// `state:working`, `pr:<url>`, and `changed` after claude edits a file
    /// or runs a command. It travels back over SSH, where the
    /// state files can't be read.
    static let signalCode = 7777

    /// A helper's settings (its hooks) beside the issue's own, in the
    /// folder they share.
    static func settingsName(_ session: CodeSession) -> String {
        session.isHelper ? "settings-\(session.id.uuidString.prefix(8)).json" : "settings.json"
    }

    /// `--model` with the model picked in Settings, applied on each start
    /// and resume (nothing when it's left to Claude Code), and a reviewer's
    /// tools taken away.
    private static func options(_ session: CodeSession) -> String {
        var options = SessionStore.model.map { " --model \(quoted($0))" } ?? ""
        // A reviewer reads and reports; it can't change the code.
        if session.isReviewer { options += " --disallowedTools 'Edit,MultiEdit,Write,NotebookEdit'" }
        return options
    }

    /// Claude's first prompt: the helper's or the issue's, then what was
    /// picked from the team's prompts and skills.
    private static func firstPrompt(_ session: CodeSession, otherwise issuePrompt: String) -> String {
        [session.prompt ?? issuePrompt, session.instructions].compactMap { $0 }.joined(separator: "\n\n")
    }

    /// The bash script a session runs: claude starts, or resumes once it has
    /// had a prompt, with a shell left open after it exits (or if a step
    /// fails). `root` is the harness checkout, or for older sessions the
    /// workspace, as a shell expression.
    static func start(_ session: CodeSession, root: String, directory: String) -> String {
        session.isInHarness ? harnessStart(session, harness: root, directory: directory) : repoStart(session, root: root, directory: directory)
    }

    /// In the harness: clone it if it isn't there, else pull it
    /// (fast-forward only, carrying on if it can't), with `projects/` and
    /// `.worktrees/` kept out of its git. The issue gets its folder,
    /// `.worktrees/<branch>/`, with the brief and settings in its `.gannin/`,
    /// and claude runs in the harness itself, adding a worktree there for
    /// each repo the issue touches.
    static func harnessStart(_ session: CodeSession, harness: String, directory: String) -> String {
        let folder = ".worktrees/\(session.branch)"
        // A server session's brief comes from the harness once it's there.
        let briefSource = session.harnessFolder.map { recorded in
            #"[ -e "$session/brief.md" ] || cp "$harness"/"# + quoted(recorded) + #"/brief.md "$session/brief.md" || fail "The brief isn't in the harness yet. Pull it, then Restart."\#n"#
        } ?? ""
        let prepare = """
            # Written by Gannin for \(session.longReference). Run in the session's terminal.
            session=\(directory)
            harness=\(harness)
            harness_repo=\(quoted(session.harnessRepo ?? session.repo))
            id=\(quoted(session.claudeID))
            folder="$harness"/\(quoted(folder))

            \(functions)

            if [ ! -e "$harness/.git" ]; then
              note "Cloning the harness, $harness_repo, into $harness"
              mkdir -p "$(dirname "$harness")"
              if command -v gh >/dev/null 2>&1; then
                gh repo clone "$harness_repo" "$harness" || fail "Couldn't clone the harness, $harness_repo."
              else
                git clone "https://github.com/$harness_repo.git" "$harness" || fail "Couldn't clone the harness, $harness_repo."
              fi
            else
              note "Updating the harness"
              \(harnessGuard(session))git -C "$harness"\(guardsGit(session) ? " -c core.hooksPath=/dev/null -c core.fsmonitor=false" : "") pull --ff-only --quiet || warn "Couldn't fast-forward the harness, so it's as it was. Pull it when you can."
            fi
            exclude="$(git -C "$harness" rev-parse --path-format=absolute --git-common-dir)/info/exclude"
            mkdir -p "$(dirname "$exclude")"
            for kept in projects .worktrees; do
              git -C "$harness" check-ignore -q "$kept/x" || echo "/$kept/" >> "$exclude"
            done

            mkdir -p "$folder/.gannin" || fail "Couldn't make $folder."
            \(briefSource)cp "$session/brief.md" "$folder/.gannin/"
            \(session.isQuickChange ? attachmentsStep : "")\(session.isAsk ? askFolder : "")\(readyForReviewStep(session, directory: directory, into: #""$folder/.gannin""#))cp "$session/settings.json" "$folder/.gannin/\(settingsName(session))"
            cd "$harness" || fail "The harness isn't there."

            """
        if session.isSandboxed {
            return prepare + SandboxLaunch.hostSteps(session, folder: folder)
        }
        return prepare + claudeSteps(session, settings: #""$folder/.gannin/"# + settingsName(session) + #"""#, shellNote: "This shell is in the harness")
    }

    /// A quick change's screenshots, from the session's folder into its
    /// `.gannin/`. Ends with a newline.
    private static let attachmentsStep = """
        if [ -d "$session/\(SessionStore.attachmentsFolder)" ]; then
          mkdir -p "$folder/.gannin/\(SessionStore.attachmentsFolder)" && cp -R "$session/\(SessionStore.attachmentsFolder)/." "$folder/.gannin/\(SessionStore.attachmentsFolder)/" || warn "Couldn't copy the screenshots into the session's folder."
        fi

        """

    /// Whether git on the box is guarded for this session: a sandbox could
    /// have written the harness's `.git` (`SandboxGitGuard`).
    private static func guardsGit(_ session: CodeSession) -> Bool {
        session.isSandboxed || SandboxCredentials.isEnabled
    }

    /// The harness checked before it's pulled, in a subshell so the guard's
    /// settings don't reach claude. Ends with a newline.
    private static func harnessGuard(_ session: CodeSession) -> String {
        guard guardsGit(session) else { return "" }
        return "why=$(\n" + SandboxGitGuard.functions + "\ngannin_check \"$harness\"\n) || fail \"$why\"\n  "
    }

    /// The shell functions the scripts share: a grey note, an orange
    /// warning, and a red failure that leaves a shell open where it can.
    static let functions = """
        note() { printf '\\033[90m%s\\033[0m\\n' "$1"; }
        warn() { printf '\\033[33mGannin: %s\\033[0m\\n' "$1"; }
        fail() {
          printf '\\033[31mGannin: %s\\033[0m\\n' "$1"
          if [ -d "$harness" ]; then cd "$harness"; else cd; fi
          exec "${SHELL:-bash}" -l
        }
        """

    /// Running claude in the harness root: a new conversation with the first
    /// prompt, or `--resume` once it has had one, then a shell once it
    /// exits. `settings` is a shell word. Needs `$session`, `$id` and the
    /// shared functions.
    /// `afterExit` is what follows claude's exit: by default a note and a
    /// login shell where it ran.
    static func claudeSteps(_ session: CodeSession, settings: String, shellNote: String, afterExit: String? = nil) -> String {
        let folder = ".worktrees/\(session.branch)"
        let issue = session.issue
        let prompt = firstPrompt(session, otherwise: """
            You're picking up \(issue.reference), "\(issue.title)", in the team's harness. Read \(folder)/.gannin/brief.md first: \
            it has the issue, its discussion, where it sits on the board and any plans for it. Work out which repos it touches \
            (those under projects/, or the harness itself when it's the code repo and has no projects/) and look through their \
            code, then propose a plan before changing anything. Make the changes in a worktree per repo under \(folder)/, as \
            the brief says, never in projects/ or the harness checkout itself.
            """)
        return """
            command -v claude >/dev/null 2>&1 || fail "claude isn't on your PATH. Install Claude Code, then Restart the session."
            if [ -e "$session/started" ]; then
              claude --resume "$id"\(options(session)) --settings \(settings)
            else
              claude --session-id "$id"\(options(session)) --settings \(settings) \(quoted(prompt))
            fi
            printf exited > "$session/state"
            printf '\\033]\(signalCode);state:exited\\007' > /dev/tty 2>/dev/null
            \(afterExit ?? "note \"Claude Code has exited. \(shellNote); run claude --resume $id to go on.\"\nexec \"${SHELL:-bash}\" -l")
            """
    }

    /// An Ask session's `files/` for what it makes, and the org data Gannin
    /// wrote for it (`SessionStore.writeAskContext`) as its `context/`,
    /// fresh on every start and resume. Ends with a newline, as it's laid
    /// in before the next line.
    private static let askFolder = """
        mkdir -p "$folder/files"
        if [ -d "$session/context" ]; then rm -rf "$folder/context" && cp -R "$session/context" "$folder/context"; fi

        """

    /// The script the working agent runs when its change is ready for a
    /// second agent to review (`PairReview`): it writes a new token and its
    /// note, on one line, to `review-request` in the session's folder
    /// (`directory`, a shell expression on the same box), which Gannin reads
    /// with the hooks' other files.
    static func readyForReview(_ session: CodeSession, directory: String) -> String {
        """
        #!/bin/bash
        # Written by Gannin for \(session.longReference). Run it when the change is ready for a second agent
        # to review, with a note on what changed and where to look.
        note=$(printf '%s' "$*" | tr '\\n' ' ')
        printf '%s %s\\n' "$(date +%s)-$$" "$note" > \(directory)/review-request || { echo "Couldn't tell Gannin." >&2; exit 1; }
        echo "Gannin has it. With pair review on, a second agent reviews the change and its findings come to you as a message; otherwise you'll be told to carry on. End your turn and wait for that message."

        """
    }

    /// The start script's line writing `ready-for-review` into the folder's
    /// `.gannin` (`folder`, a shell expression), for an issue's own session
    /// only. Ends with a newline, as it's laid in before the next line.
    private static func readyForReviewStep(_ session: CodeSession, directory: String, into folder: String) -> String {
        guard session.canPairReview else { return "" }
        let script = Data(readyForReview(session, directory: directory).utf8).base64EncodedString()
        return "printf %s \(script) | base64 -d > \(folder)/ready-for-review && chmod +x \(folder)/ready-for-review\n"
    }

    /// Sessions from before the harness: clone the repo into the workspace
    /// if it isn't yet, add the worktree beside it on the session's branch
    /// (the local branch, else origin's, else a new one from origin's
    /// default branch), copy the brief and settings into its `.gannin/`
    /// (excluded from git), and run claude there.
    private static func repoStart(_ session: CodeSession, root: String, directory: String) -> String {
        let issue = session.issue
        let prompt = firstPrompt(session, otherwise: """
            You're picking up \(issue.reference), "\(issue.title)", in \(session.repo). Read .gannin/brief.md first: it has the \
            issue, its discussion, where it sits on the board and any plans for it. Then look through the code and propose a plan \
            before changing anything.
            """)
        return """
            # Written by Gannin for \(issue.reference). Run in the session's terminal.
            session=\(directory)
            repo=\(quoted(session.repo))
            branch=\(quoted(session.branch))
            id=\(quoted(session.claudeID))
            clone=\(root)/"$repo"
            worktree="$clone.worktrees/$branch"

            note() { printf '\\033[90m%s\\033[0m\\n' "$1"; }
            fail() {
              printf '\\033[31mGannin: %s\\033[0m\\n' "$1"
              mkdir -p "$(dirname "$clone")" && cd "$(dirname "$clone")"
              exec "${SHELL:-bash}" -l
            }

            if [ ! -d "$clone/.git" ]; then
              note "Cloning $repo into $clone"
              mkdir -p "$(dirname "$clone")"
              if command -v gh >/dev/null 2>&1; then
                gh repo clone "$repo" "$clone" || fail "Couldn't clone $repo."
              else
                git clone "https://github.com/$repo.git" "$clone" || fail "Couldn't clone $repo."
              fi
            fi

            if [ ! -d "$worktree" ]; then
              note "Making a worktree for $branch"
              git -C "$clone" fetch --quiet origin || fail "Couldn't fetch $repo."
              base=$(git -C "$clone" symbolic-ref --quiet --short refs/remotes/origin/HEAD) || base=origin/main
              if git -C "$clone" show-ref --verify --quiet "refs/heads/$branch"; then
                git -C "$clone" worktree add "$worktree" "$branch" || fail "Couldn't make the worktree."
              elif git -C "$clone" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
                git -C "$clone" worktree add --track -b "$branch" "$worktree" "origin/$branch" || fail "Couldn't make the worktree."
              else
                git -C "$clone" worktree add --no-track -b "$branch" "$worktree" "$base" || fail "Couldn't make the worktree."
              fi
            fi

            cd "$worktree" || fail "The worktree isn't there."
            mkdir -p .gannin
            cp "$session/brief.md" .gannin/
            \(readyForReviewStep(session, directory: directory, into: ".gannin"))cp "$session/settings.json" .gannin/\(settingsName(session))
            exclude="$(git rev-parse --path-format=absolute --git-common-dir)/info/exclude"
            mkdir -p "$(dirname "$exclude")"
            grep -qx '.gannin/' "$exclude" 2>/dev/null || echo '.gannin/' >> "$exclude"

            command -v claude >/dev/null 2>&1 || fail "claude isn't on your PATH. Install Claude Code, then Restart the session."
            if [ -e "$session/started" ]; then
              claude --resume "$id"\(options(session)) --settings .gannin/\(settingsName(session))
            else
              claude --session-id "$id"\(options(session)) --settings .gannin/\(settingsName(session)) \(quoted(prompt))
            fi
            printf exited > "$session/state"
            printf '\\033]\(signalCode);state:exited\\007' > /dev/tty 2>/dev/null
            note "Claude Code has exited. This shell is in the worktree; run claude --resume $id to go on."
            exec "${SHELL:-bash}" -l
            """
    }

    /// Claude Code settings for the session: hooks that write its state to
    /// the session's folder and send it through the terminal, the PR it
    /// opens, and a statusLine command that saves Claude Code's own
    /// context-window stats for `SessionTranscript.contextLimit(from:)`.
    /// `isRemote` is whether this runs on a server: the user's own
    /// statusLine command, read from this Mac, wouldn't exist there.
    /// `allowing` is commands it runs without asking (the pair review's
    /// script).
    static func settings(directory dir: String, isRemote: Bool, allowing: [String] = []) -> String {
        func signal(_ payload: String) -> String {
            #"printf '\033]\#(signalCode);\#(payload)\007' > /dev/tty 2>/dev/null"#
        }
        func write(_ state: SessionState) -> [String: Any] {
            ["type": "command", "command": "printf \(state.rawValue) > \(dir)/state 2>/dev/null; \(signal("state:" + state.rawValue)); exit 0"] as [String: Any]
        }
        // A new PR's URL is somewhere in the tool call's own input or
        // result, whether it came from `gh pr create` or a PR-creating MCP
        // tool: scan every tool call for one rather than matching only
        // Bash's. A tool call can open more than one (a PR per repo in one
        // command), so keep every one seen, one per line, not just the last.
        let pullRequest = #"input=$(cat); printf '%s' "$input" | grep -Eo 'https://github\.com/[^"\\ ]+/pull/[0-9]+' | while IFS= read -r url; do grep -qxF "$url" \#(dir)/pr 2>/dev/null || { printf '%s\n' "$url" >> \#(dir)/pr; printf '\033]\#(signalCode);pr:%s\007' "$url" > /dev/tty 2>/dev/null; }; done; exit 0"#
        func command(_ command: String) -> [String: Any] { ["type": "command", "command": command] }
        func group(_ hooks: [[String: Any]], matcher: String? = nil) -> [String: Any] {
            var group: [String: Any] = ["hooks": hooks]
            group["matcher"] = matcher
            return group
        }
        let hooks: [String: Any] = [
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
            "PreToolUse": [
                group([write(.working)], matcher: "*"),
                // Its questions, as they're shown; listed after "*" so this
                // wins when both match AskUserQuestion's own tool call.
                group([write(.needsYou)], matcher: "AskUserQuestion"),
            ],
            "Stop": [group([write(.idle)])],
            "SessionEnd": [group([write(.exited)])],
        ]
        // Its `context_window` tells Gannin the model's real limit.
        // `--settings` replaces rather than merges a scalar key like
        // `statusLine`, so this would otherwise blank out a statusLine the
        // user set up themselves: run theirs in turn, on the same input,
        // and print its output instead of the model's name. Only for a
        // local session: a server's own command (and its own statusLine)
        // live on that box, not this Mac's `~/.claude/settings.json`.
        let render = (isRemote ? nil : usersStatusLineCommand()).map { #"printf '%s' "$input" | { "# + $0 + "\n}" }
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

    /// What the terminal runs on a server: unpack the script, brief and
    /// settings into the session's folder there, then run the script in the
    /// server's login shell, so its PATH and claude's login are the box's.
    /// Everything travels as base64 inside the command, stdin left to claude.
    /// The brief is left out (nil) once it's in the harness, which the
    /// script pulls.
    /// `files` are more to unpack beside them (a sandbox's `inner.sh`).
    static func remoteCommand(directory: String, script: String, brief: String?, settings: String, files: [String: String] = [:]) -> String {
        func unpack(_ text: String, _ file: String) -> String {
            "printf %s \(Data(text.utf8).base64EncodedString()) | base64 -d > \"$d/\(file)\""
        }
        let bootstrap = """
            d=\(directory)
            mkdir -p "$d"
            \(unpack(script, "start.sh"))
            \(brief.map { unpack($0, "brief.md") } ?? "rm -f \"$d/brief.md\"")
            \(unpack(settings, "settings.json"))
            \(files.sorted { $0.key < $1.key }.map { unpack($0.value, $0.key) }.joined(separator: "\n"))
            printf starting > "$d/state"
            exec "${SHELL:-bash}" -lic 'exec bash "$0"' "$d/start.sh"
            """
        return #"bash -c "$(printf %s \#(Data(bootstrap.utf8).base64EncodedString()) | base64 -d)""#
    }

    /// The Connect with command around the remote command: in place of
    /// `{command}` when it has one, else after it.
    static func connecting(_ connect: String, to remote: String) -> String {
        let argument = quoted(remote)
        return connect.contains("{command}") ? connect.replacingOccurrences(of: "{command}", with: argument) : "\(connect) \(argument)"
    }

    /// A path for the shell: `~/x` as `"$HOME"/'x'`, anything else quoted.
    static func shellPath(_ path: String) -> String {
        if path == "~" { return #""$HOME""# }
        if path.hasPrefix("~/") { return #""$HOME"/"# + quoted(String(path.dropFirst(2))) }
        return quoted(path)
    }

    /// Single-quoted for the shell.
    static func quoted(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}

/// The issue as claude first reads it: what Gannin already knows, so a
/// session starts with the context instead of going looking for it.
enum SessionBrief {
    /// A plan or requirement about the issue is included whole, up to this.
    private static let maxDocumentLength = 30_000

    /// `goals` are the project's measurables (`OrgConfig.measurables`);
    /// those a change bears on are listed, as guidance.
    static func make(session: CodeSession, record: IssueRecord?, detail: ItemDetail?, parent: IssueRecord?, harness: HarnessIndex?, goals: [Measurable] = []) -> String {
        let reference = session.issue
        var lines = session.hasNoIssue
            ? ["# Quick change in \(reference.repo): \(reference.title)", ""]
            : ["# \(reference.reference): \(reference.title)", "", reference.url.absoluteString, ""]

        var facts: [String] = []
        if let record {
            facts.append("State: \(record.isOpen ? "open" : record.isNotPlanned ? "closed, not planned" : "closed")")
            if let type = record.issueType { facts.append("Type: \(type)") }
            if !record.labels.isEmpty { facts.append("Labels: \(record.labels.joined(separator: ", "))") }
            if let milestone = record.milestone { facts.append("Milestone: \(milestone)") }
            if let author = record.author { facts.append("Opened by: @\(author), \(record.createdAt.formatted(date: .abbreviated, time: .omitted))") }
            if !record.assignees.isEmpty { facts.append("Assignees: \(record.assignees.map { "@\($0)" }.joined(separator: ", "))") }
            if let parent { facts.append("Parent: #\(parent.number) \(parent.title) (\(parent.url.absoluteString))") }
            for board in record.projectFields {
                let values = board.values.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value.display)" }
                facts.append("Board \"\(board.projectTitle)\": \(values.joined(separator: ", "))")
            }
            for pr in record.linkedPullRequests {
                facts.append("Linked PR: #\(pr.number), \(pr.state.lowercased()) (\(pr.url.absoluteString))")
            }
        }
        if !facts.isEmpty {
            lines += facts.map { "- \($0)" }
            lines.append("")
        }

        if session.isQuickChange {
            // The note is the issue's description, if it has one.
            lines += quickChangeSections(session)
        } else {
            lines += ["## Description", ""]
            if let detail {
                let body = detail.body.trimmingCharacters(in: .whitespacesAndNewlines)
                lines += [body.isEmpty ? "(No description.)" : body, ""]
                if !detail.recentComments.isEmpty {
                    let heading = detail.commentCount > detail.recentComments.count
                        ? "## Recent comments (\(detail.recentComments.count) of \(detail.commentCount))"
                        : "## Comments"
                    lines += [heading, ""]
                    for comment in detail.recentComments {
                        let who = comment.author.map { "@\($0.login)" } ?? "someone"
                        lines += ["### \(who), \(comment.createdAt.formatted(date: .abbreviated, time: .shortened))", "", comment.body, ""]
                    }
                }
            } else {
                lines += ["(Not loaded in Gannin yet. `gh issue view \(reference.number) --repo \(reference.repo) --comments` has it.)", ""]
            }
        }

        if let harness, !session.hasNoIssue {
            let matches = harness.matches(repo: reference.repo, number: reference.number)
            if !matches.isEmpty {
                lines += [
                    "## Plans and requirements",
                    "",
                    "From the team's harness repo, \(harness.repo), which keeps plans, requirements and findings beside the code. Those about this issue are here in full; the rest mention it.",
                    "",
                ]
                for match in matches {
                    let document = match.document
                    let url = harness.url(for: document)?.absoluteString ?? document.path
                    lines += ["### \(document.title)", "", "\(document.kind.singular.capitalized)\(document.statusLabel.map { ", \($0.lowercased())" } ?? ""), \(match.isSubject ? "about this issue" : "mentions it"): `\(document.path)` (\(url))", ""]
                    if let summary = document.summary { lines += [summary, ""] }
                    if match.isSubject {
                        let body = document.body.trimmingCharacters(in: .whitespacesAndNewlines)
                        lines += [body.count > maxDocumentLength ? String(body.prefix(maxDocumentLength)) + "\n\n(Cut short; the rest is at the link.)" : body, ""]
                    }
                }
            }
        }

        if let harness {
            // The issue's repo and its linked PRs': where the code likely is.
            let repos = [reference.repo] + (record?.linkedPullRequests ?? []).compactMap { HarnessLearningDraft.repo(of: $0.url) }
            var seen: Set<String> = []
            let learnings = repos.flatMap { harness.learnings(for: $0) }.filter { seen.insert($0.id).inserted }
            if !learnings.isEmpty {
                lines += [
                    "## Learnings",
                    "",
                    "Rules and reasons people gave in earlier reviews, kept in the harness under `learnings/<repo>/`, each scoped to the code it's about. Follow those that cover code you change (each file has the reason in full); if one stands in the way of the issue, say so rather than working around it. Other repos' are in their own folders there.",
                    "",
                    HarnessLearning.list(learnings),
                    "",
                ]
            }
        }

        lines += goalsSection(goals)

        var working = ["## Working here", ""]
        if session.isInHarness, let harnessPath = session.harnessPath, let harnessRepo = session.harnessRepo {
            let folder = ".worktrees/\(session.branch)"
            // Where linked PRs were opened: likely where the code is.
            var seen: Set<String> = []
            let linkedRepos = (record?.linkedPullRequests ?? []).compactMap { pr -> String? in
                let parts = pr.url.pathComponents.filter { $0 != "/" }
                return parts.count >= 2 ? "\(parts[0])/\(parts[1])" : nil
            }
            .filter { seen.insert($0).inserted }
            working += [
                "- You're in the team's harness, \(harnessRepo), checked out at `\(harnessPath)`. Its CLAUDE.md lists the projects and how work goes here.",
                "- The code repos are shared clones under `projects/<name>` (some a folder further down, as `projects/<group>/<name>`), kept on their default branch. Don't work in them. This issue's folder is `\(folder)/`: give each repo it touches a worktree there, on the branch `\(session.branch)`, from the harness root:",
                "",
                "  ```bash",
                "  git -C projects/<name> fetch origin",
                "  git -C projects/<name> worktree add \"$PWD/\(folder)/<name>\" -b \(session.branch) origin/HEAD",
                "  ```",
                "",
                session.isSandboxed
                    ? "  If the branch already exists, leave out `-b` and `origin/HEAD`. You're in a sandbox: only the repos already under `projects/` are here (\(SandboxLaunch.cloneRepos(session).joined(separator: ", "))), and a clone made in it would vanish when it stops. If the issue needs another repo, stop and ask the user to clone it into `projects/` on their Mac and restart the session. Commits are signed for you. The repos' git dirs are read-only apart from what commits, fetches and worktrees write, so git config and hooks can't be changed, no upstream is recorded (push with `git push origin HEAD` and open the PR with `gh pr create --head <branch>`), branches can't be deleted, and an error about packed-refs.lock after a rebase or pull is expected and harmless."
                    : "  If the branch already exists, leave out `-b` and `origin/HEAD`. If a repo isn't under `projects/` yet, clone it there first with `gh repo clone <owner>/<name> projects/<name>`.",
                "- If the harness has no `projects/` folder, it's the code repo too: the code is \(harnessRepo) itself. Don't work in its checkout; give it one worktree in the issue's folder the same way, with `git -C . fetch origin` and `git -C . worktree add \"$PWD/\(folder)/\(harnessRepo.split(separator: "/").last ?? "")\" -b \(session.branch) origin/HEAD`, and do everything there, the plan included.",
            ]
            if session.canPairReview {
                working.append(readyForReviewNote(session))
            }
            if !linkedRepos.isEmpty {
                working.append("- The issue's linked pull requests are in \(linkedRepos.map { "`\($0)`" }.joined(separator: ", ")), so start there.")
            }
            if reference.repo != harnessRepo {
                working.append("- The issue lives in \(reference.repo).")
            }
            working += [
                session.hasNoIssue
                    ? "- Commit in the worktree, and open a pull request with `gh pr create`. There's no issue, so don't make one or invent a reference: put \"Quick change, no issue.\" in its body where `Closes` would go, and keep the branch's name, `\(session.branch)`."
                    : "- Commit in each worktree, and open a pull request per repo with `gh pr create`, putting \"Closes \(reference.reference)\" in its body so it links to the issue.",
                session.isQuickChange
                    ? "- A quick change needs no plan document. If it grows to need one, stop and say so instead."
                    : "- A plan for this issue goes in the harness as `plans/YYYY-MM-DD-<slug>.md` from `plans/_template.md` (older harnesses keep plans in `requirements/<module>/plans/`), with `issues: [\(reference.reference)]` and a summary in its front matter as the harness's STANDARDS.md sets out, so Gannin links it to the issue. Commit and push it in the harness, and tick its checkboxes off as tasks land. When the harness is the code repo, the plan goes in its worktree and ships in the same pull request, and only if the repo keeps a `plans/` folder.",
                "- `\(folder)/.gannin/` is Gannin's (this brief and the session's hooks). `.worktrees/` and `projects/` are kept out of the harness's git.",
                "",
            ]
        } else {
            working.append("- This folder is a git worktree of \(session.repo) on branch `\(session.branch)`, made from origin's default branch.")
            if session.repo != reference.repo {
                working.append("- The issue lives in \(reference.repo), which holds issues rather than code.")
            }
            if session.canPairReview {
                working.append(readyForReviewNote(session))
            }
            working.append("- When the change is ready, open a pull request with `gh pr create` and put \"Closes \(session.closingReference)\" in its body so it links to the issue.")
            if let harness {
                working.append("- A plan's checkboxes are ticked off as its tasks land. The plan is in \(harness.repo), not this worktree.")
            }
            working += [
                "- `.gannin/` is Gannin's (this brief and the session's hooks) and is excluded from git.",
                "",
            ]
        }
        lines += working
        return lines.joined(separator: "\n")
    }

    /// The org-wide goals with a target whose metric a change moves, each
    /// with what it means for the change; nothing when there are none.
    static func goalsSection(_ measurables: [Measurable]) -> [String] {
        let goals = measurables.compactMap { goal -> String? in
            guard goal.team == nil, let target = goal.targetText, let metric = goal.metric, let advice = advice(metric) else { return nil }
            let unit = metric.countUnit(per: goal.cadence)
            return "- **\(goal.name)**: \(unit.isEmpty ? target : "\(target) \(unit)"). \(advice)"
        }
        guard !goals.isEmpty else { return [] }
        return [
            "## Goals",
            "",
            "The project's goals, from its scorecard in Gannin. The team watches these numbers, so keep them in mind as you work. They're guidance, not rules: when the issue is better served by setting one aside (a change that can't be made smaller, say), do, and say which goal and why in the pull request's description, under Why. Don't set one aside without saying so.",
            "",
        ] + goals + [""]
    }

    /// What a goal on the metric asks of a change, or nil for one a change
    /// doesn't move (reviews others give, the issue's own time in progress).
    static func advice(_ metric: ScorecardMetric) -> String? {
        switch metric {
        case .prSize: "Lines added and removed per PR: keep the change to what the issue needs, and leave unrelated tidying for another PR."
        case .prFiles: "Files a PR touches: don't spread the change across files it doesn't need."
        case .cycleTime: "First commit to merge: a small PR that's easy to review merges sooner."
        case .throughput: "PRs merged: a large change may go better as a few PRs that each stand alone."
        case .rework: "PRs changed after their first review: check the work before asking for one."
        case .unreviewed: "PRs merged without a review: never merge your own PR unreviewed."
        case .flakyRuns: "CI runs that pass only on a re-run: don't add tests that pass or fail by chance."
        case .firstReview, .answered, .slowReviews, .openPullRequests, .issueCycleTime: nil
        }
    }

    /// When and how to ask for a second agent's review (`PairReview`).
    private static func readyForReviewNote(_ session: CodeSession) -> String {
        "- When the change is ready for review (committed, built and checked; before a pull request is opened as ready for review, though a draft is fine), run `\(session.readyForReviewScript) \"<what changed and where to look>\"` and end your turn. Gannin may have a second agent review it; it can't edit, and its findings come back to you as a message. Fix those you agree with, say why not for the rest, commit, and run the script again. Gannin says when the review has settled, or to carry on without one."
    }
}
