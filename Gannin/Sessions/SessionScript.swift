#if os(macOS)
import Foundation

/// What a session's terminal runs, and the hooks claude reports through.
/// Paths are shell expressions (`"$HOME"/'Gannin'`), so the same script
/// runs on this Mac or on a server reached with the Connect with command.
enum SessionScript {
    /// The escape code the hooks send through the terminal (OSC 7777):
    /// `state:working`, `pr:<url>`. It travels back over SSH, where the
    /// state files can't be read.
    static let signalCode = 7777

    /// The bash script a session runs. In the harness: clone it if it isn't
    /// there, else pull it (fast-forward only, carrying on if it can't),
    /// clone the code repo into its `projects/` if it isn't yet (or use one
    /// a folder down, as `projects/v2/<name>`), and add the worktree at
    /// `.worktrees/<branch>/<name>` on the session's branch (the local
    /// branch, else origin's, else a new one from origin's default branch),
    /// with `projects/` and `.worktrees/` kept out of the harness's git.
    /// Sessions from before the harness keep their clone in the workspace and
    /// the worktree beside it. Then copy the brief and settings into
    /// `.gannin/` (excluded from git) and start claude, or resume it once it
    /// has had a prompt. A shell stays open in the worktree after claude
    /// exits, or in the harness (or the repo's folder) if a step fails.
    ///
    /// `root` is the harness checkout, or for older sessions the workspace,
    /// as a shell expression.
    static func start(_ session: CodeSession, root: String, directory: String) -> String {
        let issue = session.issue
        let prompt = """
            You're picking up \(issue.reference), "\(issue.title)", in \(session.repo). Read .gannin/brief.md first: it has the \
            issue, its discussion, where it sits on the board and any plans for it. Then look through the code and propose a plan \
            before changing anything.
            """
        let places: String
        let prepare: String
        let addDir: String
        // A server session's brief comes from the harness once it's there.
        let briefSource = session.harnessFolder.map { folder in
            #"[ -e "$session/brief.md" ] || cp "$harness"/"# + quoted(folder) + #"/brief.md "$session/brief.md" || fail "The brief isn't in the harness yet. Pull it, then Restart."\#n"#
        } ?? ""
        if let harnessRepo = session.harnessRepo, session.harnessPath != nil {
            places = """
                harness=\(root)
                harness_repo=\(quoted(harnessRepo))
                name=\(quoted(session.repoName))
                clone="$harness/projects/$name"
                worktree="$harness/.worktrees/$branch/$name"
                home="$harness"
                """
            prepare = """
                if [ ! -e "$harness/.git" ]; then
                  note "Cloning the harness, $harness_repo, into $harness"
                  clone_repo "$harness_repo" "$harness" || fail "Couldn't clone the harness, $harness_repo."
                else
                  note "Updating the harness"
                  git -C "$harness" pull --ff-only --quiet || warn "Couldn't fast-forward the harness, so it's as it was. Pull it when you can."
                fi
                harness_exclude="$(git -C "$harness" rev-parse --path-format=absolute --git-common-dir)/info/exclude"
                mkdir -p "$(dirname "$harness_exclude")"
                for kept in projects .worktrees; do
                  git -C "$harness" check-ignore -q "$kept/x" || echo "/$kept/" >> "$harness_exclude"
                done
                if [ ! -e "$clone/.git" ]; then
                  for found in "$harness"/projects/*/"$name"; do
                    if [ -e "$found/.git" ]; then clone="$found"; break; fi
                  done
                fi

                """
            addDir = #" --add-dir "$harness""#
        } else {
            places = """
                clone=\(root)/"$repo"
                worktree="$clone.worktrees/$branch"
                home="$(dirname "$clone")"
                """
            prepare = ""
            addDir = ""
        }
        return """
            # Written by Gannin for \(issue.reference). Run in the session's terminal.
            session=\(directory)
            repo=\(quoted(session.repo))
            branch=\(quoted(session.branch))
            id=\(quoted(session.claudeID))
            \(places)

            note() { printf '\\033[90m%s\\033[0m\\n' "$1"; }
            warn() { printf '\\033[33mGannin: %s\\033[0m\\n' "$1"; }
            fail() {
              printf '\\033[31mGannin: %s\\033[0m\\n' "$1"
              if [ -d "$home" ]; then cd "$home"; else cd; fi
              exec "${SHELL:-bash}" -l
            }
            clone_repo() {
              mkdir -p "$(dirname "$2")"
              if command -v gh >/dev/null 2>&1; then
                gh repo clone "$1" "$2"
              else
                git clone "https://github.com/$1.git" "$2"
              fi
            }

            \(prepare)if [ ! -e "$clone/.git" ]; then
              note "Cloning $repo into $clone"
              clone_repo "$repo" "$clone" || fail "Couldn't clone $repo."
            fi

            if git -C "$clone" fetch --quiet origin; then
              fetched=1
            else
              fetched=
              warn "Couldn't fetch $repo."
            fi
            if [ ! -d "$worktree" ]; then
              [ -n "$fetched" ] || fail "Can't make the worktree without fetching $repo."
              note "Making a worktree for $branch"
              mkdir -p "$(dirname "$worktree")"
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
            \(briefSource)cp "$session/brief.md" "$session/settings.json" .gannin/
            exclude="$(git rev-parse --path-format=absolute --git-common-dir)/info/exclude"
            mkdir -p "$(dirname "$exclude")"
            grep -qx '.gannin/' "$exclude" 2>/dev/null || echo '.gannin/' >> "$exclude"

            command -v claude >/dev/null 2>&1 || fail "claude isn't on your PATH. Install Claude Code, then Restart the session."
            if [ -e "$session/started" ]; then
              claude --resume "$id" --settings .gannin/settings.json\(addDir)
            else
              claude --session-id "$id" --settings .gannin/settings.json\(addDir) \(quoted(prompt))
            fi
            printf exited > "$session/state"
            printf '\\033]\(signalCode);state:exited\\007' > /dev/tty 2>/dev/null
            note "Claude Code has exited. This shell is in the worktree; run claude --resume $id to go on."
            exec "${SHELL:-bash}" -l
            """
    }

    /// Claude Code settings for the session: hooks that write its state to
    /// the session's folder and send it through the terminal, and the PR
    /// it opens.
    static func settings(directory dir: String) -> String {
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
            ],
            "Notification": [group([write(.needsYou)])],
            "Stop": [group([write(.idle)])],
            "SessionEnd": [group([write(.exited)])],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: ["hooks": hooks], options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
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
                    lines += ["### \(document.title)", "", "\(document.kind.singular.capitalized), \(match.isSubject ? "about this issue" : "mentions it"): `\(document.path)` (\(url))", ""]
                    if match.isSubject {
                        let body = document.body.trimmingCharacters(in: .whitespacesAndNewlines)
                        lines += [body.count > maxDocumentLength ? String(body.prefix(maxDocumentLength)) + "\n\n(Cut short; the rest is at the link.)" : body, ""]
                    }
                }
            }
        }

        var working = ["## Working here", ""]
        if let harnessPath = session.harnessPath, let harnessRepo = session.harnessRepo {
            working += [
                "- This folder is a git worktree of \(session.repo) on branch `\(session.branch)`, made from origin's default branch. It sits in the team's harness, \(harnessRepo), checked out at `\(harnessPath)`: the worktree is `.worktrees/\(session.branch)/\(session.repoName)` there, and `projects/\(session.repoName)` stays on the default branch as the shared clone. The harness's CLAUDE.md is loaded as well as this repo's.",
                "- If the work spans another repo, add its worktree beside this one: `git -C <harness>/projects/<name> worktree add <harness>/.worktrees/\(session.branch)/<name> -b \(session.branch)` (clone it into `projects/` first if it isn't there).",
            ]
        } else {
            working.append("- This folder is a git worktree of \(session.repo) on branch `\(session.branch)`, made from origin's default branch.")
        }
        if session.repo != reference.repo {
            working.append("- The issue lives in \(reference.repo), which holds issues rather than code.")
        }
        working += [
            "- When the change is ready, open a pull request with `gh pr create` and put \"Closes \(session.closingReference)\" in its body so it links to the issue.",
        ]
        if session.harnessPath != nil {
            working.append("- A plan for this issue goes in the harness under `requirements/<module>/plans/`, with `| GitHub | \(reference.reference) |` in its header table so Gannin links it to the issue. Commit and push it in the harness checkout (not this worktree), and tick its checkboxes off as tasks land.")
        } else if let harness {
            working.append("- A plan's checkboxes are ticked off as its tasks land. The plan is in \(harness.repo), not this worktree.")
        }
        working += [
            "- `.gannin/` is Gannin's (this brief and the session's hooks) and is excluded from git.",
            "",
        ]
        lines += working
        return lines.joined(separator: "\n")
    }
}
#endif
