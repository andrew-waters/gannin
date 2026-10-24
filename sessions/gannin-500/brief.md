# andrew-waters/gannin#500: New Issue: start with Claude, then confirm the details

https://github.com/andrew-waters/gannin/issues/500

- State: open
- Labels: enhancement
- Opened by: @andrew-waters, 24 Oct 2026
- Board "Roadmap": Status Todo

## Description

## Problem

Draft with Claude is the last section of the New Issue sheet, below the template, title, description and images. Most issues start as a rough line, so you have to scroll past an empty form to reach the part that writes it, and the conversation is squeezed into a Form section next to fields it's about to overwrite.

## Proposal

Make New Issue two steps:

1. **Write it with Claude, or skip.** The sheet opens here. Claude's conversation is on the left and a read-only preview of the issue it has drafted (title, description, labels, suggested board fields) is on the right. Skip goes straight to step 2 with an empty form.
2. **Confirm.** Today's editable form (title, description, template, images, board and fields, assignees, labels, parent), filled from the draft, where you check the details and Create.

## Acceptance criteria

- [ ] New Issue and New Sub-issue open on the Claude step, with a way to skip it.
- [ ] The Claude step is split: the conversation on the left, a read-only preview of the draft on the right that updates with each reply.
- [ ] Next (or Skip) moves to the form, filled from the draft; Back returns to the conversation.
- [ ] Decided and implemented:
  - which pickers sit on the Claude step (repository, kind, template and skills shape the draft, so probably there);
  - whether going back to Claude after editing the form keeps or overwrites those edits;
  - how Create Another, Cancel and Escape behave on each step;
  - where images are added.
- [ ] Nothing is written to GitHub before Create, as now.
- [ ] Docs: `guides/new-issue.md` describes the two steps; check the other pages that mention Draft with Claude (`agents/write-with-claude.md`, `agents/workflows.md`, `agents/routines.md`, `guides/onboarding-and-decisions.md`, `guides/harness-pages.md`, `settings/org/harness.md`).

## Context

From a quick change note; too big for one. The sheet is `Gannin/Issues/NewIssue.swift` (`NewIssueSheet`, `claudeSection`).

## Working here

- You're in the team's harness, andrew-waters/gannin, checked out at `~/Code/andrew-waters/gannin`. Its CLAUDE.md lists the projects and how work goes here.
- The code repos are shared clones under `projects/<name>` (some a folder further down, as `projects/<group>/<name>`), kept on their default branch. Don't work in them. This issue's folder is `.worktrees/500-new-issue-start-with-claude-then-confirm/`: give each repo it touches a worktree there, on the branch `500-new-issue-start-with-claude-then-confirm`, from the harness root:

  ```bash
  git -C projects/<name> fetch origin
  git -C projects/<name> worktree add "$PWD/.worktrees/500-new-issue-start-with-claude-then-confirm/<name>" -b 500-new-issue-start-with-claude-then-confirm origin/HEAD
  ```

  If the branch already exists, leave out `-b` and `origin/HEAD`. If a repo isn't under `projects/` yet, clone it there first with `gh repo clone <owner>/<name> projects/<name>`.
- If the harness has no `projects/` folder, it's the code repo too: the code is andrew-waters/gannin itself. Don't work in its checkout; give it one worktree in the issue's folder the same way, with `git -C . fetch origin` and `git -C . worktree add "$PWD/.worktrees/500-new-issue-start-with-claude-then-confirm/gannin" -b 500-new-issue-start-with-claude-then-confirm origin/HEAD`, and do everything there, the plan included.
- When the change is ready for review (committed, built and checked; before a pull request is opened as ready for review, though a draft is fine), run `.worktrees/500-new-issue-start-with-claude-then-confirm/.gannin/ready-for-review "<what changed and where to look>"` and end your turn. Gannin may have a second agent review it; it can't edit, and its findings come back to you as a message. Fix those you agree with, say why not for the rest, commit, and run the script again. Gannin says when the review has settled, or to carry on without one.
- Commit in each worktree, and open a pull request per repo with `gh pr create`, putting "Closes andrew-waters/gannin#500" in its body so it links to the issue. Before opening it as ready for review, run `.worktrees/500-new-issue-start-with-claude-then-confirm/.gannin/ready-for-review "<what changed and where to look>"` and wait for its outcome (opening it as a draft first is fine).
- A plan for this issue goes in the harness as `plans/YYYY-MM-DD-<slug>.md` from `plans/_template.md` (older harnesses keep plans in `requirements/<module>/plans/`), with `issues: [andrew-waters/gannin#500]` and a summary in its front matter as `~/Code/andrew-waters/gannin/STANDARDS.md` sets out, if the harness has one (don't look for it anywhere else), so Gannin links it to the issue. Commit and push it in the harness, and tick its checkboxes off as tasks land. When the harness is the code repo, the plan goes in its worktree and ships in the same pull request, and only if the repo keeps a `plans/` folder.
- `.worktrees/500-new-issue-start-with-claude-then-confirm/.gannin/` is Gannin's (this brief and the session's hooks). `.worktrees/` and `projects/` are kept out of the harness's git.
