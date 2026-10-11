# Backlog: Claude Code sessions (core, Ask, Quick Change)

Docs checked: `docs-site/src/content/docs/sessions/` covers only where sessions run (index, this-mac, server, sandboxes). None of the below is documented yet unless noted.

## Session tabs and Work on This
- Work on This (issue page toolbar, and the context menu of Issues › All rows) starts the issue's session in the project's harness; no repo to pick. It opens as a tab in the one Claude Code window; tabs are remembered across launches.
- Each tab: large icon for its kind, kind (Plan, Review, Code or a helper's role) and issue or PR above the title. + opens a popover with New Ask, Quick Change and New Plan buttons over a filterable list of started sessions with no tab open. Tabs drag into order; Rename Tab or double-click names one (empty restores the title). ⌘W closes a tab and claude keeps running; a running issue or quick change session asks first (wrap-up sheet).
- Helpers show inside their session's tab under a switcher of Work and each helper by role with its state. The tab shows pair review progress, else helper count, and is marked when a helper is waiting on you.
- Each tab is a terminal beside a side panel (opens 440 pt wide, draggable down to 300): the issue (state, plans and requirements from the harness opening in a sheet) or Changes. A helper's panel is Session, naming the session it helps with Show Session and Open Issue.
- Tab bar grid shows every session; Show Beside puts two tabs side by side. Sessions idle three days are stale. Once every PR is merged (or stale), Finish and Clean Up in the panel removes worktrees and forgets the session.
- Attention: a session going to Needs you, or working to Your turn, while you're not looking is flagged: tab mark, Dock count, notification (Settings > General > Agent) that opens its tab; the tab bar's "N waiting" or Window > Next Session Waiting on You (⇧⌘J) goes to the longest waiting.
- What claude asks shows as a card floating over the terminal (every question with option tiles and an Other field, or a permission prompt with the command) and on Claude Code › Agents with what claude said before. Sessions whose turn it is get a reply box there.
- Activity pane: events, cost, working vs waiting time, files edited, last test or build, context used of 200k or 1M; plans written under `plans/` (Read, Approve Plan, Request Changes); a reviewer's findings (Add to Comments).
- Settings > General > Agent: provider (Anthropic only) and model sessions start with (empty leaves it to Claude Code).

## Composer
- Under the terminal: prompt box, saved prompts (Settings, ⌃1 to ⌃9), Esc to interrupt, Attended or Unattended, context gauge with /compact, last test result.

## Attended and Unattended
- Attended is claude's default mode, Unattended its auto mode. Accept edits, plan and bypass modes are only shown, by claude's names. The composer menu switches it. If auto mode can't be reached, Unattended is disabled with a line saying why. Leave Unattended on the permission card (and as the last quick reply on a Needs you notification) means Allow this and stop asking.

## Changes pane
- Branch and Uncommitted modes. Uncommitted stages, unstages, discards (file or hunk), commits and pushes. Each worktree says what isn't pushed. Files and lines open in the chosen editor (VS Code, Cursor, Zed also over SSH remote). Clicking a line number leaves a comment; comments are sent together from the bar under the list.

## PRs pane
- Lists the session's PRs with state, review, conflicts and checks. Send Failures to Claude passes failed checks; open review threads and reviews with words are ticked and sent as one prompt. Per-session Send new feedback to Claude (default in Settings > General > Agent, off): new failures and feedback are pasted in when claude is waiting, else queued until its turn ends. Notifications flag new failures and new review feedback from others; not conversation comments, approvals or conflicts. Checked every 2 minutes, every minute while checks run (Settings › Sync).

## Session rules
- Settings › General › Session rules, off until one is ticked. Ready-made: no force push, push only to the session's branch, no branch or tag deletes, no `gh release` writes, at most N PR comments or reviews an hour. Custom: a `grep -E` pattern to Block or Ask me. Applies on this Mac, servers and sandboxes. Blocked calls show in Activity. It's a guardrail, not a security boundary: an encoded or scripted command can get round it.

## Pair review
- Settings > General > Agent, Review a session's work with a second agent (on), and each session's own choice, status, Show Reviewer, Stop and Review Now in its Activity pane. Loop runs at most 3 rounds, ends Settled when a round finds nothing.

## Ask
- New Ask: button at top of the sidebar, Claude Code window's +, Agents' toolbar, palette. A first-message box with project and the team's Ask prompts and skills; Return starts, Shift-Return is a new line. Always runs on this Mac.
- Panel is Session (no Changes; PRs only once it has some; then Activity): Artifacts (claude.ai artifacts it published, open or copy; Ask for an Artifact), Files (everything it made, plus Written elsewhere, newest first with size and time). Click opens; drag drags the file. Menu: Open With, Show in Finder, Save a Copy, Copy, Commit to Harness (Quick Look preview, destination `research/<date>-<id>/<name>` with a README, sensitive-data warning, tick box, Cancel default).
- Ask sessions are kept until deleted: Agents page and sidebar Agents › Ask list them (title, first message, files, last active); Rename and Delete (confirmed). No Finish and Clean Up.

## Quick Change
- For a snag, tweak or one-line fix from a note. New Quick Change: sidebar button beside New Ask, Claude Code window's +, Agents' toolbar, palette. Form: project, repo (project's first, then org's), note, optional title (else first line), screenshots (drop, paste, add; images only, 20 MB each), Create an issue for it (on by default, asked each time), team prompts and skills, Run in (with sandboxing on), Record the session in the harness.
- With an issue: filed from the note, assigned to you, added to the workflow board with Status set to the first in-progress option (a failure shows in the panel; the session still starts). Without: no issue, brief says "Quick change, no issue." in the PR.
- Screenshots aren't uploaded or committed unless Add the screenshots to the issue is ticked (off each time; button becomes Commit N Images, Create Issue and Start). Tab is Quick Change (a bolt); panel shows note and screenshots.

## Dropped
- Plan and issue references (#131, #123, #52, #68, #129, plans/...): history.
- Helper `Review the Changes` entry-point wording: derivable from code.
- Pair review, tab layout, `SessionTab.panelMaxWidth`/`sessionPanelWidth` identifiers: UI detail, grep finds them.
- `WorkloadTab.ask` legacy raw value note: derivable from the enum.
- Exhaustive "where New Ask is launched from" lists in code rules: kept only in backlog.
- Session rules ready-made rule enumerations in code rule: grep finds them.
