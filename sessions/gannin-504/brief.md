# andrew-waters/gannin#504: Standup: shareable morning views that walk the board, with a style per team

https://github.com/andrew-waters/gannin/issues/504

## Description

## Problem

Rituals › Standup today shows what each person did on one day (By Person, Team and Changelog layouts, from the work log). That answers "what happened yesterday" but doesn't fit a standup run on a shared screen each morning, where the team wants to go through the board and the backlog together:

1. What's in Done, and anything that needs discussion
2. What's in review
3. What's in progress
4. What needs triage (backlog items with no Status)

Teams using Gannin won't all run standup the same way, so a single fixed view won't suit everyone.

## Proposal

Plan a replacement for the current Standup view that is built to be shared on screen and supports more than one standup style, each with its own view. The team (or org) picks its style.

Styles to cover first:

- **Walk the board**: a board-style view that goes column by column in the order above (Done and needs discussion, In review, In progress, Triage), so the team can quickly look over the tickets and the triage backlog.
- **Person by person**: one person at a time, showing their tickets across those same states, plus what they did (what the current By Person layout covers today).

Other styles we could add (to decide in the plan, not all needed now):

- **Blockers first**: only items that are blocked, stale, or waiting on review for a long time, for teams that keep standup short.
- **Goal or sprint progress**: items grouped by the current sprint, milestone or initiative, showing what moved toward it.
- **Changelog**: what shipped, grouped by investment category (the existing Changelog layout, kept as a style).
- **Async / written**: the Markdown notes per person, for teams that post standup rather than meet (builds on the current Notes feature).

The plan should say how the existing By Person, Team and Changelog layouts and Notes carry over, since this replaces the current view.

## Unknowns

- How "needs discussion" is marked: a board Status, a label, a field, or something set in Gannin. Not decided.
- How each team's board columns map to the four stages. Teams' workflow boards will have different Status options; the plan needs a mapping, and where it's configured (Settings, per team, per org) is not decided.
- What "shareable" should mean beyond being readable on a shared screen: for example a presentation or full-screen mode, stepping through sections, a link others can open, or an export. Not decided.
- Whether the style is chosen per team, per org, or per standup, and whether a team can switch between styles on the day.
- What date range the board views use (the board as it is now, or what changed since the last working day).

## Acceptance criteria

- [ ] A plan in the harness covering the styles above, which to build first, and how each maps onto a team's workflow board
- [ ] Walk the board and Person by person views designed for on-screen sharing, in the order Done and needs discussion, In review, In progress, Triage
- [ ] Triage shows the same issues as Prioritisation's triage list (open, on the workflow board, no Status)
- [ ] Each team can pick its standup style
- [ ] The current Standup view is replaced, with its existing layouts and Notes either carried over as styles or deliberately dropped (stated in the plan)
- [ ] Docs: `guides/standup` at gannin.ai/docs is rewritten; `guides/app-tour` and any settings page for the style choice updated

## Context

- Current behaviour: andrew-waters/gannin:docs-site/src/content/docs/guides/standup.md, `Gannin/WorkLog/StandupView.swift`
- Related: andrew-waters/gannin:plans/2026-10-08-planning-ceremony.md
- No existing issue found for this (searched "standup").

## Working here

- You're in the team's harness, andrew-waters/gannin, checked out at `~/Code/andrew-waters/gannin`. Its CLAUDE.md lists the projects and how work goes here.
- The code repos are shared clones under `projects/<name>` (some a folder further down, as `projects/<group>/<name>`), kept on their default branch. Don't work in them. This issue's folder is `.worktrees/504-standup-shareable-morning-views-that/`: give each repo it touches a worktree there, on the branch `504-standup-shareable-morning-views-that`, from the harness root:

  ```bash
  git -C projects/<name> fetch origin
  git -C projects/<name> worktree add "$PWD/.worktrees/504-standup-shareable-morning-views-that/<name>" -b 504-standup-shareable-morning-views-that origin/HEAD
  ```

  If the branch already exists, leave out `-b` and `origin/HEAD`. If a repo isn't under `projects/` yet, clone it there first with `gh repo clone <owner>/<name> projects/<name>`.
- If the harness has no `projects/` folder, it's the code repo too: the code is andrew-waters/gannin itself. Don't work in its checkout; give it one worktree in the issue's folder the same way, with `git -C . fetch origin` and `git -C . worktree add "$PWD/.worktrees/504-standup-shareable-morning-views-that/gannin" -b 504-standup-shareable-morning-views-that origin/HEAD`, and do everything there, the plan included.
- When the change is ready for review (committed, built and checked; before a pull request is opened as ready for review, though a draft is fine), run `.worktrees/504-standup-shareable-morning-views-that/.gannin/ready-for-review "<what changed and where to look>"` and end your turn. Gannin may have a second agent review it; it can't edit, and its findings come back to you as a message. Fix those you agree with, say why not for the rest, commit, and run the script again. Gannin says when the review has settled, or to carry on without one.
- Commit in each worktree, and open a pull request per repo with `gh pr create`, putting "Closes andrew-waters/gannin#504" in its body so it links to the issue. Before opening it as ready for review, run `.worktrees/504-standup-shareable-morning-views-that/.gannin/ready-for-review "<what changed and where to look>"` and wait for its outcome (opening it as a draft first is fine).
- A plan for this issue goes in the harness as `plans/YYYY-MM-DD-<slug>.md` from `plans/_template.md` (older harnesses keep plans in `requirements/<module>/plans/`), with `issues: [andrew-waters/gannin#504]` and a summary in its front matter as `~/Code/andrew-waters/gannin/STANDARDS.md` sets out, if the harness has one (don't look for it anywhere else), so Gannin links it to the issue. Commit and push it in the harness, and tick its checkboxes off as tasks land. When the harness is the code repo, the plan goes in its worktree and ships in the same pull request, and only if the repo keeps a `plans/` folder.
- `.worktrees/504-standup-shareable-morning-views-that/.gannin/` is Gannin's (this brief and the session's hooks). `.worktrees/` and `projects/` are kept out of the harness's git.
