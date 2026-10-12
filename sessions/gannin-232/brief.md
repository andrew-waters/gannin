# andrew-waters/gannin#232: Sync: share one PR store between the workload, metrics and work log

https://github.com/andrew-waters/gannin/issues/232

- State: open
- Opened by: @dwrss, 11 Oct 2026
- Parent: #213 Fix overlapping sync fetches and consolidate sync code (https://github.com/andrew-waters/gannin/issues/213)

## Description

## Problem

A PR is fetched in four shapes with no shared cache: `OrgStore`'s snapshot, `MetricsStore`'s merged PRs (with reviews, timeline and commits), `WorkLogStore`'s PRs (with commits and reviews) and `IssueRecord`'s linked PRs. A merged PR in the lookback window is downloaded by three stores, each on its own schedule and kept in its own file.

## Proposal

A `PullRequestStore` keyed by node ID holds the fields the PR stores share (state, dates, author, reviews, commits). `MetricsStore`, `WorkLogStore` and `OrgStore` read from it and fetch only their extra fields. Migrate one consumer at a time, starting with `MetricsStore`'s merged PRs where the lookback covers them.

## Acceptance criteria

- [ ] A PR is stored once and shared by `OrgStore`, `MetricsStore` and `WorkLogStore`
- [ ] Each consumer's numbers are unchanged for the same data, covered by tests
- [ ] `OrgStore.updatePullRequest`'s optimistic writes go through the shared store
- [ ] Existing caches migrate or are rebuilt, with the backfill called out in the release notes
- [ ] Settings › Sync › Spent shows lower cost for the PR sources compared with the Stage 0 numbers
- [ ] Docs: none unless a Sync setting's meaning changes

## Context

Part of #213. Plan: `plans/2026-10-11-sync-overlap-and-cleanup.md`, Stage 3b. Depends on the Stage 0 issue and works best after the change feed (Stage 3a). Stage 3c builds on it.

## Comments

### @dwrss, 11 Oct 2026 at 11:36

**Decision needed before building: may an upgrade rebuild a cache once?**

Changing what this store keeps on disk bumps the cache's version, and an old cache is then discarded and fetched again from GitHub (a backfill of the metrics window, the issue history or the work log, spending API budget once).

Open question for the owner: is that acceptable, with the backfill called out in the release notes? If not, this needs a migration that reads the old file instead, which is more work.

Also decide first whether the Stage 0 numbers on #230 say this is worth doing at all.


## Plans and requirements

From the team's harness repo, andrew-waters/gannin, which keeps plans, requirements and findings beside the code. Those about this issue are here in full; the rest mention it.

### Sync: one change feed per org

Plan, in progress, mentions it: `plans/2026-10-12-change-feed-per-org.md` (https://github.com/andrew-waters/gannin/blob/main/plans/2026-10-12-change-feed-per-org.md)

One cheap search per org says which PRs and issues changed, kept as an in-memory log the workload, issue history and work log read instead of each running a changes search, with each store's own search as the fallback.

## Working here

- You're in the team's harness, andrew-waters/gannin, checked out at `~/Projects/gannin`. Its CLAUDE.md lists the projects and how work goes here.
- The code repos are shared clones under `projects/<name>` (some a folder further down, as `projects/<group>/<name>`), kept on their default branch. Don't work in them. This issue's folder is `.worktrees/232-sync-share-one-pr-store-between-the/`: give each repo it touches a worktree there, on the branch `232-sync-share-one-pr-store-between-the`, from the harness root:

  ```bash
  git -C projects/<name> fetch origin
  git -C projects/<name> worktree add "$PWD/.worktrees/232-sync-share-one-pr-store-between-the/<name>" -b 232-sync-share-one-pr-store-between-the origin/HEAD
  ```

  If the branch already exists, leave out `-b` and `origin/HEAD`. If a repo isn't under `projects/` yet, clone it there first with `gh repo clone <owner>/<name> projects/<name>`.
- If the harness has no `projects/` folder, it's the code repo too: the code is andrew-waters/gannin itself. Don't work in its checkout; give it one worktree in the issue's folder the same way, with `git -C . fetch origin` and `git -C . worktree add "$PWD/.worktrees/232-sync-share-one-pr-store-between-the/gannin" -b 232-sync-share-one-pr-store-between-the origin/HEAD`, and do everything there, the plan included.
- When the change is ready for review (committed, built and checked; before a pull request is opened as ready for review, though a draft is fine), run `.worktrees/232-sync-share-one-pr-store-between-the/.gannin/ready-for-review "<what changed and where to look>"` and end your turn. Gannin may have a second agent review it; it can't edit, and its findings come back to you as a message. Fix those you agree with, say why not for the rest, commit, and run the script again. Gannin says when the review has settled, or to carry on without one.
- Commit in each worktree, and open a pull request per repo with `gh pr create`, putting "Closes andrew-waters/gannin#232" in its body so it links to the issue.
- A plan for this issue goes in the harness as `plans/YYYY-MM-DD-<slug>.md` from `plans/_template.md` (older harnesses keep plans in `requirements/<module>/plans/`), with `issues: [andrew-waters/gannin#232]` and a summary in its front matter as the harness's STANDARDS.md sets out, so Gannin links it to the issue. Commit and push it in the harness, and tick its checkboxes off as tasks land. When the harness is the code repo, the plan goes in its worktree and ships in the same pull request, and only if the repo keeps a `plans/` folder.
- `.worktrees/232-sync-share-one-pr-store-between-the/.gannin/` is Gannin's (this brief and the session's hooks). `.worktrees/` and `projects/` are kept out of the harness's git.
