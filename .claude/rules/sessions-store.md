---
paths:
  - "Gannin/Sessions/SessionStore*"
  - "Gannin/Sessions/SessionScript*"
  - "Gannin/Sessions/SessionLaunch*"
  - "Gannin/Sessions/WrapUp*"
  - "Gannin/Sessions/QuitGuard*"
  - "Gannin/Sessions/ScriptRunner*"
---

# SessionStore, scripts, wrap-up, quit, ScriptRunner

## Start and recording
- Record the session in the harness (`sessions/<issue repo>-<number>/brief.md` and `session.json`, one commit) before the terminal starts, so the harness pull brings them; a server session reads its brief from there. Layer a PR claude reports onto the harness's `session.json`.
- `start.sh` pulls the harness with `git pull --ff-only` and must warn, not fail, when that can't happen. It keeps `projects/` and `.worktrees/` in `info/exclude`, copies brief and settings to `.worktrees/<branch>/.gannin/`, then runs `claude --session-id` (`--resume` once it has had a prompt) in the harness root.
- Strip inherited `CLAUDE_CODE_*` variables when starting claude.
- Find a harness checkout by its origin's whole repo name, so `gannin` never matches a clone of `gannin-legacy`. The setting is `sessionsHarnessPath.<org>`, keyed per harness by `SessionStore.harnessPathKey`.
- Hooks run with no terminal, so `HookFileWatcher` (with `SessionStore.poll` as its safety net) and `readRemote` over ssh read the files they write; don't depend on OSC 7777 arriving.
- A server session packs script, brief and settings into one command (`SessionScript.remoteCommand`).
- Never handle claude's login; it runs as the user.
- Keep team prompts, if picked, in `CodeSession.instructions` appended to the first prompt (`SessionScript.firstPrompt`). A review keeps its JSON ending.
- Goals in the brief are guidance claude may set aside if it says why in the PR's Why (`SessionBrief.goalsSection`).

## Tabs
- Insert a tab only through `insertionIndex` and walk them through `displayedTabs`, never `tabs` directly: `tabs` is the one stored order, and the groups (work, then reviews) are derived from it by `tabGroups`, so a writer that skips the helper leaves reviews among work. `SessionTabBar` likewise renders from `tabGroups`, with the group divider only when both groups are non-empty.

## Wrap-up on close (`WrapUp.swift`)
- Measure unpushed commits against the upstream, else `origin/<branch>`: a sandbox records no upstream. Read it with its own `SessionChanges`, whatever mode the pane is in (`WorktreeChanges.notPushed`).
- Ask only for an issue's own session or a quick change's, and only while `isClaudeRunning` (claude or a helper, not its leftover shell). Never ask on Close Other Tabs.
- Tick `- [ ]` items only in plans and requirements about the issue (not mere mentions), matched by their words, outside front matter and code. Commit one commit per file at the head; the button naming the harness is the confirmation.
- Keep Running stays the default. Finish and Clean Up is offered only once every PR is merged, and is confirmed.

## Feedback sent to claude
- New PR feedback is pasted now if claude awaits a prompt, else queued in `pendingFeedback` until its turn ends. Mark it sent only once pasted, and drop it if claude exits first; never mark it sent early.

## Quit
- Sandboxes stop only after the quit question is answered (`stopSandboxesForQuit`).

## One-off questions
- `ClaudeCodeProvider.ask` runs `claude -p` locally if installed, else on the Connect with server with only the tools given; follow-ups use `--resume` in the same folder. `ScriptRunner` runs the script on its box and strips inherited `CLAUDE_CODE_*` variables.

## Testing
- `SessionTabGroupsTests.swift`, `WrapUpTests.swift`, `SessionBriefGoalsTests.swift`, `SessionModeTests.swift`, `SessionRulesTests.swift`. `SandboxLaunchTests.swift` covers script generation for sandboxes. Nothing covers `SessionStore.record` or the quit guard.
