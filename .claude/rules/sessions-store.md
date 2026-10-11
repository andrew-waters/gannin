---
paths:
  - "Gannin/Sessions/SessionStore*"
  - "Gannin/Sessions/SessionScript*"
  - "Gannin/Sessions/SessionLaunch*"
  - "Gannin/Sessions/WrapUp*"
  - "Gannin/Sessions/QuitGuard*"
  - "Gannin/Sessions/ClaudeRunner*"
  - "Gannin/Sessions/PromptWriting*"
---

# SessionStore, start scripts, brief, wrap-up, quit guard, ClaudeRunner

## Storage and start
- `SessionStore` persists `CodeSession`s in Application Support/<bundle ID>/Sessions and keeps their terminals, so closing a window leaves claude running. Work on This needs a project.
- Each session folder holds brief, settings and `start.sh` (`SessionScript`), run by a login interactive shell. It clones the harness (gh, else git) or `git pull --ff-only` (warns, doesn't fail), adds `projects/` and `.worktrees/` to `info/exclude`, copies brief and settings into `.worktrees/<branch>/.gannin/`, then runs `claude --session-id` (`--resume` once it has had a prompt) in the harness root. Inherited `CLAUDE_CODE_*` env vars are stripped.
- Brief: claude adds a worktree per touched repo at `.worktrees/<branch>/<name>` from the shared clone in `projects/<name>`. A harness with no `projects/` is the code repo and gets one worktree of itself, plan included. Older sessions keep the old layout (clone in the workspace, worktree beside it).
- Harness checkout per org: `sessionsHarnessPath.<org>`, default a checkout in a usual place found by its origin's whole repo name (so `gannin` never matches `gannin-legacy`), else `<workspace>/<org>-harness`. Per harness via `SessionStore.harnessPathKey(org, repo:)`.
- Connect with (`sessionsConnect`, e.g. `ssh -t devbox`): script, brief and settings are packed into one command (`SessionScript.remoteCommand`) and run in `sessionsRemoteHarnessPath.<org>` (no default).
- Hooks run with no terminal, so OSC 7777 rarely arrives. `SessionStore.poll` reads the files hooks write (state, pr, changed): every 1s locally, every 2s over the shared ssh connection (`readRemote`). Hooks in `--settings` report working / needs you / your turn / exited and the URL from `gh pr create`. Gannin never handles claude's login.
- Recording (`SessionStore.record`): one commit of `sessions/<issue repo>-<number>/brief.md` and `session.json` (`SessionRecord`: issue, repos, branch, starter, when, box, PRs) before the terminal starts, so the pull brings them; a server session reads its brief from there. A PR claude reports is layered onto the harness's `session.json`. Confirmation has a per-org "Don't ask again" (`sessionsRecordWithoutAsking.<org>`).
- `SessionBrief` (in `SessionScript.swift`): issue facts, board fields, parent, linked PRs, description and comments, harness documents about it (full) or mentioning it (summary only), learnings for its repos, and goals (`SessionBrief.goalsSection`, `advice`: measurables with a target that a change moves) as guidance it may set aside if it says why in the PR's Why.
- A session's Plans and requirements (`HarnessIssueSection`) come from the harness it runs in; the Claude Code window has no project, so it uses the org's home.
- Team prompts chosen in `SessionLaunchSheet` / `PromptPickerSections` go in `CodeSession.instructions`, appended to the first prompt (`SessionScript.firstPrompt`); a review's keeps its JSON ending. Starts with no sheet (notifications, menu bar, Review the Changes) take the defaults.

## Wrap-up on close (`WrapUp.swift`)
- `SessionStore.requestClose` sets `wrappingUp` (shown as `WrapUpSessionSheet`) only for an issue's own session or a quick change's, when `isClaudeRunning` (claude or a helper, not its leftover shell). Via the tab's X, Close Tab and the close shortcut; not Close Other Tabs. Gated by `sessionsWrapUpOnClose`.
- Unpushed commits are measured against the upstream, else `origin/<branch>` (a sandbox records no upstream), by `WorktreeChanges.notPushed` read through its own `SessionChanges`, whatever mode the pane is in.
- Checklist ticking (`HarnessChecklist`): `- [ ]` items in plans/requirements about its issue (not mere mentions), matched by their words, outside front matter and code, committed in one commit per file at the head; the button naming the harness is the confirmation. `tickOffPrompt` asks Claude instead.
- Outcomes: Keep Running (default), Stop Claude (`endAndClose`: ends claude and helpers, keeps worktrees, resumed on open), Finish and Clean Up only once every PR is merged (confirmed).

## Quit guard
- `GanninAppDelegate.applicationShouldTerminate` + `QuitGuard.swift` asks when sessions run. Sandboxes stop after this question (`stopSandboxesForQuit`).

## ClaudeRunner and Write with Claude
- `ClaudeRunner` runs `claude -p` one-offs: locally if claude is installed, else on the Connect with server via a bash script on stdin that writes prompt and files into a folder and runs claude there with only the tools given. Conversations use `--resume` in the same folder.
- `PromptWriting` (`WriteWithClaudeButton`, `PromptWritingSheet`) is one no-tools `ClaudeRunner` conversation; each reply is JSON with `message` and, once drafted, the whole `draft`, and the current draft goes with every later message (`firstPrompt`, `followUp`, `reply`). `PromptWriting.Purpose` (`houseRules`, `savedPrompt`, `authoring(kind)`) says what's written and where it goes. Cancel discards the conversation.
