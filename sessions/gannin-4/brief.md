# andrew-waters/gannin#4: Add a Cmd+K command palette for global search and actions

https://github.com/andrew-waters/gannin/issues/4

- State: open
- Labels: accessibility, enhancement
- Opened by: @andrew-waters, 4 Oct 2026
- Assignees: @andrew-waters
- Board "Roadmap": Status Todo

## Description

## Problem

There is no single place in Gannin to find something or run an action. To reach an item you have to know where it lives and click through to it, and actions are spread across the screens they belong to. This slows down anyone who uses the app a lot and knows what they want.

## Proposal

Add a command palette that opens with Cmd+K (Ctrl+K on Windows and Linux) from anywhere in the app. It does two jobs:

- **Global search:** type to find anything in Gannin and jump straight to it.
- **Actions:** type to find and run app commands, such as navigation and common operations, without leaving the keyboard.

Still to decide (left open on purpose):

- Which entities are searchable. "Everything" is the goal, but the first list (for example issues, plans, requirements, findings, settings) has not been agreed.
- Which actions go in the first version.
- Whether search runs on the client over loaded data or needs a backend or index.
- How results are ranked and grouped (by type, by recent use), and whether recent items or suggestions show before the user types.
- What happens if Cmd+K is already used somewhere in the app.

## Acceptance

- [ ] Cmd+K (Ctrl+K off macOS) opens the palette from any screen, and Esc closes it
- [ ] Typing filters results across the agreed searchable entities, and choosing a result goes to it
- [ ] Typing also matches the agreed set of actions, and choosing one runs it
- [ ] Results are grouped or labelled so search hits and actions are clearly different
- [ ] Fully usable by keyboard (arrow keys, Enter, Esc), with focus handled correctly and results announced to screen readers
- [ ] Shows a clear empty state when nothing matches

## Context

No parent issue or harness document has been identified for this yet.

## Working here

- You're in the team's harness, andrew-waters/gannin, checked out at `~/Code/andrew-waters/gannin`. Its CLAUDE.md lists the projects and how work goes here.
- The code repos are shared clones under `projects/<name>` (some a folder further down, as `projects/<group>/<name>`), kept on their default branch. Don't work in them. This issue's folder is `.worktrees/4-add-a-cmd-k-command-palette-for-global/`: give each repo it touches a worktree there, on the branch `4-add-a-cmd-k-command-palette-for-global`, from the harness root:

  ```bash
  git -C projects/<name> fetch origin
  git -C projects/<name> worktree add "$PWD/.worktrees/4-add-a-cmd-k-command-palette-for-global/<name>" -b 4-add-a-cmd-k-command-palette-for-global origin/HEAD
  ```

  If the branch already exists, leave out `-b` and `origin/HEAD`. If a repo isn't under `projects/` yet, clone it there first with `gh repo clone <owner>/<name> projects/<name>`.
- If the harness has no `projects/` folder, it's the code repo too: the code is andrew-waters/gannin itself. Don't work in its checkout; give it one worktree in the issue's folder the same way, with `git -C . fetch origin` and `git -C . worktree add "$PWD/.worktrees/4-add-a-cmd-k-command-palette-for-global/gannin" -b 4-add-a-cmd-k-command-palette-for-global origin/HEAD`, and do everything there, the plan included.
- Commit in each worktree, and open a pull request per repo with `gh pr create`, putting "Closes andrew-waters/gannin#4" in its body so it links to the issue.
- A plan for this issue goes in the harness as `plans/YYYY-MM-DD-<slug>.md` from `plans/_template.md` (older harnesses keep plans in `requirements/<module>/plans/`), with `issues: [andrew-waters/gannin#4]` and a summary in its front matter as the harness's STANDARDS.md sets out, so Gannin links it to the issue. Commit and push it in the harness, and tick its checkboxes off as tasks land. When the harness is the code repo, the plan goes in its worktree and ships in the same pull request, and only if the repo keeps a `plans/` folder.
- `.worktrees/4-add-a-cmd-k-command-palette-for-global/.gannin/` is Gannin's (this brief and the session's hooks). `.worktrees/` and `projects/` are kept out of the harness's git.
