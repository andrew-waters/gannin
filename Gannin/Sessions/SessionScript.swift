#if os(macOS)
import Foundation

/// What a session's terminal runs, and the hooks claude reports through.
enum SessionScript {
    /// The zsh script a session's terminal sources: clone the repo if it
    /// isn't yet, add the worktree on the session's branch (the local branch,
    /// else origin's, else a new one from origin's default branch), copy the
    /// brief and settings into `.gannin/` (excluded from git), then start
    /// claude, or resume it once it has had a prompt. A shell stays open in
    /// the worktree after claude exits, or in the repo's folder if a step fails.
    static func start(_ session: CodeSession, root: URL, directory: URL) -> String {
        let issue = session.issue
        let prompt = """
            You're picking up \(issue.reference), "\(issue.title)", in \(session.repo). Read .gannin/brief.md first: it has the \
            issue, its discussion, where it sits on the board and any plans for it. Then look through the code and propose a plan \
            before changing anything.
            """
        return """
            # Written by Gannin for \(issue.reference). Run in the session's terminal.
            repo=\(quoted(session.repo))
            clone=\(quoted(SessionStore.clone(of: session.repo).path))
            worktree=\(quoted(SessionStore.worktree(for: session).path))
            branch=\(quoted(session.branch))
            session=\(quoted(directory.path))
            id=\(quoted(session.claudeID))

            gannin_fail() {
              print -P "%F{red}Gannin: $1%f"
              mkdir -p "${clone:h}" && cd "${clone:h}"
              exec zsh -l
            }

            if [[ ! -d "$clone/.git" ]]; then
              print -P "%F{8}Cloning $repo into $clone%f"
              mkdir -p "${clone:h}"
              if (( $+commands[gh] )); then
                gh repo clone "$repo" "$clone" || gannin_fail "Couldn't clone $repo."
              else
                git clone "https://github.com/$repo.git" "$clone" || gannin_fail "Couldn't clone $repo."
              fi
            fi

            if [[ ! -d "$worktree" ]]; then
              print -P "%F{8}Making a worktree for $branch%f"
              git -C "$clone" fetch --quiet origin || gannin_fail "Couldn't fetch $repo."
              base=$(git -C "$clone" symbolic-ref --quiet --short refs/remotes/origin/HEAD) || base=origin/main
              if git -C "$clone" show-ref --verify --quiet "refs/heads/$branch"; then
                git -C "$clone" worktree add "$worktree" "$branch"
              elif git -C "$clone" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
                git -C "$clone" worktree add --track -b "$branch" "$worktree" "origin/$branch"
              else
                git -C "$clone" worktree add --no-track -b "$branch" "$worktree" "$base"
              fi || gannin_fail "Couldn't make the worktree."
            fi

            cd "$worktree" || gannin_fail "The worktree isn't there."
            mkdir -p .gannin
            cp "$session/brief.md" "$session/settings.json" .gannin/
            exclude="$(git rev-parse --path-format=absolute --git-common-dir)/info/exclude"
            mkdir -p "${exclude:h}"
            grep -qx '.gannin/' "$exclude" 2>/dev/null || print '.gannin/' >> "$exclude"

            (( $+commands[claude] )) || gannin_fail "claude isn't on your PATH. Install Claude Code, then Restart the session."
            if [[ -e "$session/started" ]]; then
              claude --resume "$id" --settings .gannin/settings.json
            else
              claude --session-id "$id" --settings .gannin/settings.json \(quoted(prompt))
            fi
            printf exited > "$session/state"
            print -P "%F{8}Claude Code has exited. This shell is in the worktree; run claude --resume $id to go on.%f"
            exec zsh -l
            """
    }

    /// Claude Code settings for the session: hooks that write its state to
    /// the session's folder, and the PR it opens.
    static func settings(directory: URL) -> String {
        let dir = quoted(directory.path)
        func write(_ state: SessionState) -> [String: Any] {
            ["type": "command", "command": "printf \(state.rawValue) > \(dir)/state"] as [String: Any]
        }
        // `gh pr create` prints the new PR's URL; keep the last one seen.
        let pullRequest = #"input=$(cat); case "$input" in *'gh pr create'*) printf '%s' "$input" | grep -Eo 'https://github\.com/[^"\\ ]+/pull/[0-9]+' | tail -n 1 > \#(dir)/pr.tmp && [ -s \#(dir)/pr.tmp ] && mv \#(dir)/pr.tmp \#(dir)/pr ;; esac; exit 0"#
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

        var working = [
            "## Working here",
            "",
            "- This folder is a git worktree of \(session.repo) on branch `\(session.branch)`, made from origin's default branch.",
        ]
        if session.repo != reference.repo {
            working.append("- The issue lives in \(reference.repo), which holds issues rather than code.")
        }
        working += [
            "- When the change is ready, open a pull request with `gh pr create` and put \"Closes \(session.closingReference)\" in its body so it links to the issue.",
        ]
        if let harness {
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
