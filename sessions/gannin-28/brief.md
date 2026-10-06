# andrew-waters/gannin#28: Github rate limiting

https://github.com/andrew-waters/gannin/issues/28

- State: open
- Opened by: @andrew-waters, 6 Oct 2026

## Description

## Problem

With regular use, Gannin can reach the hourly rate limit. When that happens, the data Gannin shows stops updating until the limit resets.

The controls for what gets fetched and how often aren't in one place, and there aren't enough of them to keep usage under the limit.

Unknown and still to be confirmed:

- Which rate limit it is. It is probably GitHub's API limit (REST, GraphQL or both), but that hasn't been checked.
- Which features or syncs use the most of the budget, and how many requests an hour Gannin makes now.
- Which existing settings already affect fetching, and where they live in the app today.
- Whether Gannin currently shows or handles the limit at all (remaining budget, reset time, backoff).

## Proposal

- Put every control over fetching and syncing in one settings view.
- Let the user choose **what** Gannin fetches: turn individual data sources or features on and off.
- Let the user choose **how often** each one refreshes, instead of one fixed rate for everything.

How to build it (scheduling, caching, backoff and so on) is not decided yet.

## Acceptance

- [ ] One settings view holds all controls that affect fetching and sync frequency.
- [ ] Each fetched data source or feature can be turned on or off there.
- [ ] Each one has its own refresh interval that can be changed there.
- [ ] With reasonable settings, normal use stays under the hourly rate limit (the target needs to be defined once the limit and current usage are known).
- [ ] `CLAUDE.md` is updated to describe the new settings and sync behaviour.

## Context

- No parent issue, harness plan or finding has been linked yet.

## Working here

- You're in the team's harness, andrew-waters/gannin, checked out at `~/Code/andrew-waters/gannin`. Its CLAUDE.md lists the projects and how work goes here.
- The code repos are shared clones under `projects/<name>` (some a folder further down, as `projects/<group>/<name>`), kept on their default branch. Don't work in them. This issue's folder is `.worktrees/28-github-rate-limiting/`: give each repo it touches a worktree there, on the branch `28-github-rate-limiting`, from the harness root:

  ```bash
  git -C projects/<name> fetch origin
  git -C projects/<name> worktree add "$PWD/.worktrees/28-github-rate-limiting/<name>" -b 28-github-rate-limiting origin/HEAD
  ```

  If the branch already exists, leave out `-b` and `origin/HEAD`. If a repo isn't under `projects/` yet, clone it there first with `gh repo clone <owner>/<name> projects/<name>`.
- If the harness has no `projects/` folder, it's the code repo too: the code is andrew-waters/gannin itself. Don't work in its checkout; give it one worktree in the issue's folder the same way, with `git -C . fetch origin` and `git -C . worktree add "$PWD/.worktrees/28-github-rate-limiting/gannin" -b 28-github-rate-limiting origin/HEAD`, and do everything there, the plan included.
- Commit in each worktree, and open a pull request per repo with `gh pr create`, putting "Closes andrew-waters/gannin#28" in its body so it links to the issue.
- A plan for this issue goes in the harness as `plans/YYYY-MM-DD-<slug>.md` from `plans/_template.md` (older harnesses keep plans in `requirements/<module>/plans/`), with `issues: [andrew-waters/gannin#28]` and a summary in its front matter as the harness's STANDARDS.md sets out, so Gannin links it to the issue. Commit and push it in the harness, and tick its checkboxes off as tasks land. When the harness is the code repo, the plan goes in its worktree and ships in the same pull request, and only if the repo keeps a `plans/` folder.
- `.worktrees/28-github-rate-limiting/.gannin/` is Gannin's (this brief and the session's hooks). `.worktrees/` and `projects/` are kept out of the harness's git.
