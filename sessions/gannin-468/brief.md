# andrew-waters/gannin#468: Show whether review has been requested, not just who the reviewers are

https://github.com/andrew-waters/gannin/issues/468

- State: open
- Labels: enhancement
- Opened by: @andrew-waters, 23 Oct 2026

## Description

## Problem

The reviewers column doesn't say what its names mean. Someone looking at a pull request can't tell whether a name is a person who has already reviewed it, a person who has been asked to review it, or both. So it's hard to see which PRs are still waiting for a reviewer to act and which have already had a review.

Things this issue doesn't yet know:
- Which views show the reviewers column (the PR list, the issue timeline, a session's PRs or somewhere else).
- What the column is filled from today: requested reviewers, submitted reviews or a mix of both.
- Whether team review requests (as opposed to individual people) need to be shown too.

## Proposal

Show whether review has been requested, so it's clear which reviewers have been asked and which have reviewed. How to show it (a separate column, a marker on each name, a tooltip and so on) hasn't been decided.

## Acceptance criteria

- [ ] For each PR it's clear which reviewers have been asked to review and haven't reviewed yet.
- [ ] It's clear which reviewers have already submitted a review.
- [ ] A PR with no reviewers and no review requests is shown as such.
- [ ] Docs: which pages at gannin.ai/docs change (to be confirmed once the affected views are known), or "none".

## Context

Raised by andrew-waters. No parent issue, harness document or related PR has been identified yet.

## Working here

- You're in the team's harness, andrew-waters/gannin, checked out at `~/Code/andrew-waters/gannin`. Its CLAUDE.md lists the projects and how work goes here.
- The code repos are shared clones under `projects/<name>` (some a folder further down, as `projects/<group>/<name>`), kept on their default branch. Don't work in them. This issue's folder is `.worktrees/468-show-whether-review-has-been-requested/`: give each repo it touches a worktree there, on the branch `468-show-whether-review-has-been-requested`, from the harness root:

  ```bash
  git -C projects/<name> fetch origin
  git -C projects/<name> worktree add "$PWD/.worktrees/468-show-whether-review-has-been-requested/<name>" -b 468-show-whether-review-has-been-requested origin/HEAD
  ```

  If the branch already exists, leave out `-b` and `origin/HEAD`. If a repo isn't under `projects/` yet, clone it there first with `gh repo clone <owner>/<name> projects/<name>`.
- If the harness has no `projects/` folder, it's the code repo too: the code is andrew-waters/gannin itself. Don't work in its checkout; give it one worktree in the issue's folder the same way, with `git -C . fetch origin` and `git -C . worktree add "$PWD/.worktrees/468-show-whether-review-has-been-requested/gannin" -b 468-show-whether-review-has-been-requested origin/HEAD`, and do everything there, the plan included.
- When the change is ready for review (committed, built and checked; before a pull request is opened as ready for review, though a draft is fine), run `.worktrees/468-show-whether-review-has-been-requested/.gannin/ready-for-review "<what changed and where to look>"` and end your turn. Gannin may have a second agent review it; it can't edit, and its findings come back to you as a message. Fix those you agree with, say why not for the rest, commit, and run the script again. Gannin says when the review has settled, or to carry on without one.
- Commit in each worktree, and open a pull request per repo with `gh pr create`, putting "Closes andrew-waters/gannin#468" in its body so it links to the issue. Before opening it as ready for review, run `.worktrees/468-show-whether-review-has-been-requested/.gannin/ready-for-review "<what changed and where to look>"` and wait for its outcome (opening it as a draft first is fine).
- A plan for this issue goes in the harness as `plans/YYYY-MM-DD-<slug>.md` from `plans/_template.md` (older harnesses keep plans in `requirements/<module>/plans/`), with `issues: [andrew-waters/gannin#468]` and a summary in its front matter as `~/Code/andrew-waters/gannin/STANDARDS.md` sets out, if the harness has one (don't look for it anywhere else), so Gannin links it to the issue. Commit and push it in the harness, and tick its checkboxes off as tasks land. When the harness is the code repo, the plan goes in its worktree and ships in the same pull request, and only if the repo keeps a `plans/` folder.
- `.worktrees/468-show-whether-review-has-been-requested/.gannin/` is Gannin's (this brief and the session's hooks). `.worktrees/` and `projects/` are kept out of the harness's git.
