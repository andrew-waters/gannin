# andrew-waters/gannin#484: Filter pull requests by repo, author, review state and status

https://github.com/andrew-waters/gannin/issues/484

## Description

## Problem

The pull request list can only be narrowed with the filters it has today, so it is hard to focus on the PRs that matter. I can't hide PRs from a given repo or author, hide ones I've already reviewed, or narrow the list by status.

Not yet known: which filters exist today, and where exactly they appear in the app.

## Proposal

Add these filters next to the existing PR filters:

- **Repo**: include or exclude PRs from chosen repos.
- **Author**: include or exclude PRs by chosen authors.
- **Reviewed**: hide PRs I have already reviewed.
- **Status**: filter by PR status.

The existing filters should keep working and combine with the new ones.

To decide:

- What "status" means here: open, draft or ready for review, the review decision (approved, changes requested), CI checks, or the Status field on the workflow board.
- Whether "reviewed" means any review from me, or only a review on the latest commit.
- Whether each filter works as include, exclude or both.
- Whether filter choices are remembered between launches.

## Acceptance criteria

- [ ] PRs can be filtered by repo
- [ ] PRs can be filtered by author
- [ ] PRs I have already reviewed can be hidden
- [ ] PRs can be filtered by status (meaning to be agreed, see Proposal)
- [ ] New filters combine with the existing PR filters
- [ ] Docs: which pages at gannin.ai/docs change (not yet known)

## Context

Requested by andrew-waters. No parent issue, harness document or related PRs known.

## Working here

- You're in the team's harness, andrew-waters/gannin, checked out at `~/Code/andrew-waters/gannin`. Its CLAUDE.md lists the projects and how work goes here.
- The code repos are shared clones under `projects/<name>` (some a folder further down, as `projects/<group>/<name>`), kept on their default branch. Don't work in them. This issue's folder is `.worktrees/484-filter-pull-requests-by-repo-author/`: give each repo it touches a worktree there, on the branch `484-filter-pull-requests-by-repo-author`, from the harness root:

  ```bash
  git -C projects/<name> fetch origin
  git -C projects/<name> worktree add "$PWD/.worktrees/484-filter-pull-requests-by-repo-author/<name>" -b 484-filter-pull-requests-by-repo-author origin/HEAD
  ```

  If the branch already exists, leave out `-b` and `origin/HEAD`. If a repo isn't under `projects/` yet, clone it there first with `gh repo clone <owner>/<name> projects/<name>`.
- If the harness has no `projects/` folder, it's the code repo too: the code is andrew-waters/gannin itself. Don't work in its checkout; give it one worktree in the issue's folder the same way, with `git -C . fetch origin` and `git -C . worktree add "$PWD/.worktrees/484-filter-pull-requests-by-repo-author/gannin" -b 484-filter-pull-requests-by-repo-author origin/HEAD`, and do everything there, the plan included.
- When the change is ready for review (committed, built and checked; before a pull request is opened as ready for review, though a draft is fine), run `.worktrees/484-filter-pull-requests-by-repo-author/.gannin/ready-for-review "<what changed and where to look>"` and end your turn. Gannin may have a second agent review it; it can't edit, and its findings come back to you as a message. Fix those you agree with, say why not for the rest, commit, and run the script again. Gannin says when the review has settled, or to carry on without one.
- Commit in each worktree, and open a pull request per repo with `gh pr create`, putting "Closes andrew-waters/gannin#484" in its body so it links to the issue. Before opening it as ready for review, run `.worktrees/484-filter-pull-requests-by-repo-author/.gannin/ready-for-review "<what changed and where to look>"` and wait for its outcome (opening it as a draft first is fine).
- A plan for this issue goes in the harness as `plans/YYYY-MM-DD-<slug>.md` from `plans/_template.md` (older harnesses keep plans in `requirements/<module>/plans/`), with `issues: [andrew-waters/gannin#484]` and a summary in its front matter as `~/Code/andrew-waters/gannin/STANDARDS.md` sets out, if the harness has one (don't look for it anywhere else), so Gannin links it to the issue. Commit and push it in the harness, and tick its checkboxes off as tasks land. When the harness is the code repo, the plan goes in its worktree and ships in the same pull request, and only if the repo keeps a `plans/` folder.
- `.worktrees/484-filter-pull-requests-by-repo-author/.gannin/` is Gannin's (this brief and the session's hooks). `.worktrees/` and `projects/` are kept out of the harness's git.
