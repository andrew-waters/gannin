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
    private static func settingsName(_ session: CodeSession) -> String {
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
    private static func harnessStart(_ session: CodeSession, harness: String, directory: String) -> String {
        let issue = session.issue
        let folder = ".worktrees/\(session.branch)"
        let prompt = firstPrompt(session, otherwise: """
            You're picking up \(issue.reference), "\(issue.title)", in the team's harness. Read \(folder)/.gannin/brief.md first: \
            it has the issue, its discussion, where it sits on the board and any plans for it. Work out which repos it touches \
            (those under projects/, or the harness itself when it's the code repo and has no projects/) and look through their \
            code, then propose a plan before changing anything. Make the changes in a worktree per repo under \(folder)/, as \
            the brief says, never in projects/ or the harness checkout itself.
            """)
        // A server session's brief comes from the harness once it's there.
        let briefSource = session.harnessFolder.map { recorded in
            #"[ -e "$session/brief.md" ] || cp "$harness"/"# + quoted(recorded) + #"/brief.md "$session/brief.md" || fail "The brief isn't in the harness yet. Pull it, then Restart."\#n"#
        } ?? ""
        return """
            # Written by Gannin for \(issue.reference). Run in the session's terminal.
            session=\(directory)
            harness=\(harness)
            harness_repo=\(quoted(session.harnessRepo ?? session.repo))
            id=\(quoted(session.claudeID))
            folder="$harness"/\(quoted(folder))

            note() { printf '\\033[90m%s\\033[0m\\n' "$1"; }
            warn() { printf '\\033[33mGannin: %s\\033[0m\\n' "$1"; }
            fail() {
              printf '\\033[31mGannin: %s\\033[0m\\n' "$1"
              if [ -d "$harness" ]; then cd "$harness"; else cd; fi
              exec "${SHELL:-bash}" -l
            }

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
              git -C "$harness" pull --ff-only --quiet || warn "Couldn't fast-forward the harness, so it's as it was. Pull it when you can."
            fi
            exclude="$(git -C "$harness" rev-parse --path-format=absolute --git-common-dir)/info/exclude"
            mkdir -p "$(dirname "$exclude")"
            for kept in projects .worktrees; do
              git -C "$harness" check-ignore -q "$kept/x" || echo "/$kept/" >> "$exclude"
            done

            mkdir -p "$folder/.gannin" || fail "Couldn't make $folder."
            \(briefSource)cp "$session/brief.md" "$folder/.gannin/"
            cp "$session/settings.json" "$folder/.gannin/\(settingsName(session))"
            cd "$harness" || fail "The harness isn't there."

            command -v claude >/dev/null 2>&1 || fail "claude isn't on your PATH. Install Claude Code, then Restart the session."
            if [ -e "$session/started" ]; then
              claude --resume "$id"\(options(session)) --settings "$folder/.gannin/\(settingsName(session))"
            else
              claude --session-id "$id"\(options(session)) --settings "$folder/.gannin/\(settingsName(session))" \(quoted(prompt))
            fi
            printf exited > "$session/state"
            printf '\\033]\(signalCode);state:exited\\007' > /dev/tty 2>/dev/null
            note "Claude Code has exited. This shell is in the harness; run claude --resume $id to go on."
            exec "${SHELL:-bash}" -l
            """
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
            cp "$session/settings.json" .gannin/\(settingsName(session))
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
    static func settings(directory dir: String, isRemote: Bool) -> String {
        func signal(_ payload: String) -> String {
            #"printf '\033]\#(signalCode);\#(payload)\007' > /dev/tty 2>/dev/null"#
        }
        func write(_ state: SessionState) -> [String: Any] {
            ["type": "command", "command": "printf \(state.rawValue) > \(dir)/state 2>/dev/null; \(signal("state:" + state.rawValue)); exit 0"] as [String: Any]
        }
        // `gh pr create` prints the new PR's URL; keep the last one seen.
        let pullRequest = #"input=$(cat); case "$input" in *'gh pr create'*) url=$(printf '%s' "$input" | grep -Eo 'https://github\.com/[^"\\ ]+/pull/[0-9]+' | tail -n 1); if [ -n "$url" ]; then printf '%s' "$url" > \#(dir)/pr; printf '\033]\#(signalCode);pr:%s\007' "$url" > /dev/tty 2>/dev/null; fi ;; esac; exit 0"#
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
                group([command(pullRequest)], matcher: "Bash"),
                // So the Changes pane reads the worktrees now, not on its
                // next slow look.
                // A new value each time, for Gannin to compare.
                group([command("printf %s \"$(date +%s)-$$\" > \(dir)/changed 2>/dev/null; \(signal("changed")); exit 0")], matcher: "Edit|MultiEdit|Write|NotebookEdit|Bash"),
            ],
            // A permission prompt or a dialog, not the reminder after a
            // minute idle, which is still your turn.
            "Notification": [group([write(.needsYou)], matcher: "permission_prompt|elicitation_dialog")],
            // Its questions, as they're shown.
            "PreToolUse": [group([write(.needsYou)], matcher: "AskUserQuestion")],
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
        let data = (try? JSONSerialization.data(
            withJSONObject: ["hooks": hooks, "statusLine": ["type": "command", "command": statusLine]],
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
    static func remoteCommand(directory: String, script: String, brief: String?, settings: String) -> String {
        func unpack(_ text: String, _ file: String) -> String {
            "printf %s \(Data(text.utf8).base64EncodedString()) | base64 -d > \"$d/\(file)\""
        }
        let bootstrap = """
            d=\(directory)
            mkdir -p "$d"
            \(unpack(script, "start.sh"))
            \(brief.map { unpack($0, "brief.md") } ?? "rm -f \"$d/brief.md\"")
            \(unpack(settings, "settings.json"))
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

    static func make(session: CodeSession, record: IssueRecord?, detail: ItemDetail?, parent: IssueRecord?, harness: HarnessIndex?) -> String {
        let reference = session.issue
        var lines = ["# \(reference.reference): \(reference.title)", "", reference.url.absoluteString, ""]

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

        if let harness {
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
                "  If the branch already exists, leave out `-b` and `origin/HEAD`. If a repo isn't under `projects/` yet, clone it there first with `gh repo clone <owner>/<name> projects/<name>`.",
                "- If the harness has no `projects/` folder, it's the code repo too: the code is \(harnessRepo) itself. Don't work in its checkout; give it one worktree in the issue's folder the same way, with `git -C . fetch origin` and `git -C . worktree add \"$PWD/\(folder)/\(harnessRepo.split(separator: "/").last ?? "")\" -b \(session.branch) origin/HEAD`, and do everything there, the plan included.",
            ]
            if !linkedRepos.isEmpty {
                working.append("- The issue's linked pull requests are in \(linkedRepos.map { "`\($0)`" }.joined(separator: ", ")), so start there.")
            }
            if reference.repo != harnessRepo {
                working.append("- The issue lives in \(reference.repo).")
            }
            working += [
                "- Commit in each worktree, and open a pull request per repo with `gh pr create`, putting \"Closes \(reference.reference)\" in its body so it links to the issue.",
                "- A plan for this issue goes in the harness as `plans/YYYY-MM-DD-<slug>.md` from `plans/_template.md` (older harnesses keep plans in `requirements/<module>/plans/`), with `issues: [\(reference.reference)]` and a summary in its front matter as the harness's STANDARDS.md sets out, so Gannin links it to the issue. Commit and push it in the harness, and tick its checkboxes off as tasks land. When the harness is the code repo, the plan goes in its worktree and ships in the same pull request, and only if the repo keeps a `plans/` folder.",
                "- `\(folder)/.gannin/` is Gannin's (this brief and the session's hooks). `.worktrees/` and `projects/` are kept out of the harness's git.",
                "",
            ]
        } else {
            working.append("- This folder is a git worktree of \(session.repo) on branch `\(session.branch)`, made from origin's default branch.")
            if session.repo != reference.repo {
                working.append("- The issue lives in \(reference.repo), which holds issues rather than code.")
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
}
