# andrew-waters/gannin#343: Right-clicking an Ask or Planning row in the sidebar offers Rename and Delete

https://github.com/andrew-waters/gannin/issues/343

- State: open
- Labels: enhancement
- Opened by: @dwrss, 14 Oct 2026

## Description

## Problem
In the main window's sidebar, under Agents, the Ask and Planning groups list sessions, but right-clicking a row does nothing. `SessionSidebarRows.row` in `Gannin/Sessions/SessionViews.swift` only puts items in its `.contextMenu` for archived reviews and sessions with a PR. Asks can only be renamed or deleted from the Waiting on You page, and Plans only from Rituals › Planning, so the menu people expect is missing where they look first.

## Proposal
Give the sidebar's Ask rows the same menu as the Waiting on You page's Ask list (Open, Rename, Show in Finder, Delete), and the Planning rows the same menu as Rituals › Planning (Open, Delete). Delete asks first, with the same message as today. The confirmation and "Delete Anyway" handling is shared with those lists, not copied.

## Acceptance criteria
- [ ] Right-clicking an Ask row in the sidebar shows Open, Rename, Show in Finder and Delete
- [ ] Right-clicking a Planning row in the sidebar shows Open and Delete
- [ ] Delete confirms first and offers Delete Anyway when the folder can't be removed, as on the existing pages
- [ ] Docs: update `agents/ask.md` and `agents/planning.md` to mention the sidebar menu; CHANGELOG line added

## Context
Related: andrew-waters/gannin#61 (Ask keep, resume and delete).

## Working here

- You're in the team's harness, andrew-waters/gannin, checked out at `~/Projects/gannin`. Its CLAUDE.md lists the projects and how work goes here.
- The code repos are shared clones under `projects/<name>` (some a folder further down, as `projects/<group>/<name>`), kept on their default branch. Don't work in them. This issue's folder is `.worktrees/343-right-clicking-an-ask-or-planning-row-in/`: give each repo it touches a worktree there, on the branch `343-right-clicking-an-ask-or-planning-row-in`, from the harness root:

  ```bash
  git -C projects/<name> fetch origin
  git -C projects/<name> worktree add "$PWD/.worktrees/343-right-clicking-an-ask-or-planning-row-in/<name>" -b 343-right-clicking-an-ask-or-planning-row-in origin/HEAD
  ```

  If the branch already exists, leave out `-b` and `origin/HEAD`. If a repo isn't under `projects/` yet, clone it there first with `gh repo clone <owner>/<name> projects/<name>`.
- If the harness has no `projects/` folder, it's the code repo too: the code is andrew-waters/gannin itself. Don't work in its checkout; give it one worktree in the issue's folder the same way, with `git -C . fetch origin` and `git -C . worktree add "$PWD/.worktrees/343-right-clicking-an-ask-or-planning-row-in/gannin" -b 343-right-clicking-an-ask-or-planning-row-in origin/HEAD`, and do everything there, the plan included.
- When the change is ready for review (committed, built and checked; before a pull request is opened as ready for review, though a draft is fine), run `.worktrees/343-right-clicking-an-ask-or-planning-row-in/.gannin/ready-for-review "<what changed and where to look>"` and end your turn. Gannin may have a second agent review it; it can't edit, and its findings come back to you as a message. Fix those you agree with, say why not for the rest, commit, and run the script again. Gannin says when the review has settled, or to carry on without one.
- Commit in each worktree, and open a draft pull request per repo with `gh pr create --draft`, putting "Closes andrew-waters/gannin#343" in its body so it links to the issue.
- A plan for this issue goes in the harness as `plans/YYYY-MM-DD-<slug>.md` from `plans/_template.md` (older harnesses keep plans in `requirements/<module>/plans/`), with `issues: [andrew-waters/gannin#343]` and a summary in its front matter as `~/Projects/gannin/STANDARDS.md` sets out, if the harness has one (don't look for it anywhere else), so Gannin links it to the issue. Commit and push it in the harness, and tick its checkboxes off as tasks land. When the harness is the code repo, the plan goes in its worktree and ships in the same pull request, and only if the repo keeps a `plans/` folder.
- `.worktrees/343-right-clicking-an-ask-or-planning-row-in/.gannin/` is Gannin's (this brief and the session's hooks). `.worktrees/` and `projects/` are kept out of the harness's git.

## Scheduled run

Gannin started this session by itself, for the routine "Queue window". Nobody is watching it.

- Don't ask questions or wait for a plan to be approved: decide, write down why where the work is recorded (the plan, the commit, the pull request or the report), and carry on. If you can't go on without a person, stop and say why in your last message.
- You're in auto mode. A permission prompt or question waits for someone and holds the run up.
- It's stopped after 60 minutes or US$15.00 spent, whichever comes first, keeping what's done. Keep within that.
- Draft PR: once the change is committed, built and checked, push with `git push origin HEAD:<branch>` (this session's branch) and open a draft pull request (`gh pr create --draft`). Don't mark it ready for review or merge it.
