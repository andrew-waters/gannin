# andrew-waters/gannin#476: Show CI time per pull request, with averages and what drives it, in the metrics

https://github.com/andrew-waters/gannin/issues/476

## Description

## Problem

We can't see how much CI time each pull request uses, what a typical PR costs, or why some PRs use much more than others. Without that we can't tell whether CI cost is growing or what is behind it.

Note: the request said "COI time". This draft assumes that means CI time (time spent in CI runs for a PR). If it means something else, this issue needs rewording.

## Proposal

For each pull request, record how much CI time it used, and show it in the metrics:

- CI time per PR
- Averages across PRs (the period and grouping are still to be decided)
- The reasons a PR used the time it did, so outliers can be explained

Still unknown and to decide in triage:

- How CI time is measured: wall-clock duration of runs, billable minutes, or both, and whether re-runs and cancelled runs count
- Which CI systems are in scope (GitHub Actions only, or others too)
- What "reasons" means in practice, for example re-runs after failures, number of pushes, which workflows or jobs ran, or PR size. None of these has been agreed
- Where the metrics appear: an existing metrics view in Gannin, a new one, or somewhere else
- Which average to show (mean, median or both) and over what window

## Acceptance criteria

- [ ] Each PR shows the CI time it used, measured as agreed above
- [ ] The metrics show average CI time per PR over the agreed window
- [ ] For each PR the metrics show what made up its CI time, broken down by the agreed reasons
- [ ] Docs: which pages at gannin.ai/docs change is not yet known; at least the metrics page if one covers PR metrics

## Context

- No parent issue, harness document or related PRs known yet.
- The duplicate check and the repo's issue template were not checked (GitHub access was not granted in this session); the body follows the default shape in skills/create-issue.md.

## Working here

- You're in the team's harness, andrew-waters/gannin, checked out at `~/Code/andrew-waters/gannin`. Its CLAUDE.md lists the projects and how work goes here.
- The code repos are shared clones under `projects/<name>` (some a folder further down, as `projects/<group>/<name>`), kept on their default branch. Don't work in them. This issue's folder is `.worktrees/476-show-ci-time-per-pull-request-with/`: give each repo it touches a worktree there, on the branch `476-show-ci-time-per-pull-request-with`, from the harness root:

  ```bash
  git -C projects/<name> fetch origin
  git -C projects/<name> worktree add "$PWD/.worktrees/476-show-ci-time-per-pull-request-with/<name>" -b 476-show-ci-time-per-pull-request-with origin/HEAD
  ```

  If the branch already exists, leave out `-b` and `origin/HEAD`. If a repo isn't under `projects/` yet, clone it there first with `gh repo clone <owner>/<name> projects/<name>`.
- If the harness has no `projects/` folder, it's the code repo too: the code is andrew-waters/gannin itself. Don't work in its checkout; give it one worktree in the issue's folder the same way, with `git -C . fetch origin` and `git -C . worktree add "$PWD/.worktrees/476-show-ci-time-per-pull-request-with/gannin" -b 476-show-ci-time-per-pull-request-with origin/HEAD`, and do everything there, the plan included.
- When the change is ready for review (committed, built and checked; before a pull request is opened as ready for review, though a draft is fine), run `.worktrees/476-show-ci-time-per-pull-request-with/.gannin/ready-for-review "<what changed and where to look>"` and end your turn. Gannin may have a second agent review it; it can't edit, and its findings come back to you as a message. Fix those you agree with, say why not for the rest, commit, and run the script again. Gannin says when the review has settled, or to carry on without one.
- Commit in each worktree, and open a pull request per repo with `gh pr create`, putting "Closes andrew-waters/gannin#476" in its body so it links to the issue. Before opening it as ready for review, run `.worktrees/476-show-ci-time-per-pull-request-with/.gannin/ready-for-review "<what changed and where to look>"` and wait for its outcome (opening it as a draft first is fine).
- A plan for this issue goes in the harness as `plans/YYYY-MM-DD-<slug>.md` from `plans/_template.md` (older harnesses keep plans in `requirements/<module>/plans/`), with `issues: [andrew-waters/gannin#476]` and a summary in its front matter as `~/Code/andrew-waters/gannin/STANDARDS.md` sets out, if the harness has one (don't look for it anywhere else), so Gannin links it to the issue. Commit and push it in the harness, and tick its checkboxes off as tasks land. When the harness is the code repo, the plan goes in its worktree and ships in the same pull request, and only if the repo keeps a `plans/` folder.
- `.worktrees/476-show-ci-time-per-pull-request-with/.gannin/` is Gannin's (this brief and the session's hooks). `.worktrees/` and `projects/` are kept out of the harness's git.
