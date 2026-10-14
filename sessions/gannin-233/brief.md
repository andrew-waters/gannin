# andrew-waters/gannin#233: Sync: pollers read the shared PR store

https://github.com/andrew-waters/gannin/issues/233

- State: open
- Opened by: @dwrss, 11 Oct 2026
- Parent: #213 Fix overlapping sync fetches and consolidate sync code (https://github.com/andrew-waters/gannin/issues/213)

## Description

## Problem

`EngineerWatch.engineerWork` (your open PRs and review requests, every 5 minutes), `watchedPullRequests` (PRs under review) and `sessionPullRequests` (each session's PRs, every 2 minutes) re-fetch PRs that `OrgStore`'s snapshot already holds. Session PRs are fetched one session at a time in sequence.

## Proposal

These pollers read the shared PR store when `updatedAt` matches and fetch only the volatile parts (checks, review threads, comments), for all sessions in one aliased by-node-ID query instead of a loop.

## Acceptance criteria

- [ ] `EngineerWatch`, the watched-review check and the session PR watch use the shared PR store for what it holds
- [ ] All sessions' PRs are fetched in one query per tick
- [ ] Notifications for failing checks, review feedback and approvals fire as before, covered by tests
- [ ] Settings › Sync › Spent shows lower cost for Your reviews and PRs, Watched reviews and Session pull requests compared with the Stage 0 numbers
- [ ] Docs: none unless a Sync setting's meaning changes

## Context

Part of #213. Plan: `plans/2026-10-11-sync-overlap-and-cleanup.md`, Stage 3c. Depends on the shared PR store (Stage 3b).

## Comments

### @dwrss, 11 Oct 2026 at 11:10

The session PR poller's own cost (probe first, one query per tick, no double fetch) is now #238, which comes first and doesn't need the shared PR store. This issue is about reading the shared store afterwards.

## Plans and requirements

From the team's harness repo, andrew-waters/gannin, which keeps plans, requirements and findings beside the code. Those about this issue are here in full; the rest mention it.

### Sync: one change feed per org

Plan, in progress, mentions it: `plans/2026-10-12-change-feed-per-org.md` (https://github.com/andrew-waters/gannin/blob/main/plans/2026-10-12-change-feed-per-org.md)

One cheap search per org says which PRs and issues changed, kept as an in-memory log the workload, issue history and work log read instead of each running a changes search, with each store's own search as the fallback.

### Sync: one PR store

Plan, done, mentions it: `plans/2026-10-12-shared-pr-store.md` (https://github.com/andrew-waters/gannin/blob/main/plans/2026-10-12-shared-pr-store.md)

One PullRequestStore keeps each PR once per org, as core fields plus a slot per store, so MetricsStore, WorkLogStore and OrgStore stop each saving their own copy.

## Working here

- You're in the team's harness, andrew-waters/gannin, checked out at `~/Projects/gannin`. Its CLAUDE.md lists the projects and how work goes here.
- The code repos are shared clones under `projects/<name>` (some a folder further down, as `projects/<group>/<name>`), kept on their default branch. Don't work in them. This issue's folder is `.worktrees/233-sync-pollers-read-the-shared-pr-store/`: give each repo it touches a worktree there, on the branch `233-sync-pollers-read-the-shared-pr-store`, from the harness root:

  ```bash
  git -C projects/<name> fetch origin
  git -C projects/<name> worktree add "$PWD/.worktrees/233-sync-pollers-read-the-shared-pr-store/<name>" -b 233-sync-pollers-read-the-shared-pr-store origin/HEAD
  ```

  If the branch already exists, leave out `-b` and `origin/HEAD`. If a repo isn't under `projects/` yet, clone it there first with `gh repo clone <owner>/<name> projects/<name>`.
- If the harness has no `projects/` folder, it's the code repo too: the code is andrew-waters/gannin itself. Don't work in its checkout; give it one worktree in the issue's folder the same way, with `git -C . fetch origin` and `git -C . worktree add "$PWD/.worktrees/233-sync-pollers-read-the-shared-pr-store/gannin" -b 233-sync-pollers-read-the-shared-pr-store origin/HEAD`, and do everything there, the plan included.
- When the change is ready for review (committed, built and checked; before a pull request is opened as ready for review, though a draft is fine), run `.worktrees/233-sync-pollers-read-the-shared-pr-store/.gannin/ready-for-review "<what changed and where to look>"` and end your turn. Gannin may have a second agent review it; it can't edit, and its findings come back to you as a message. Fix those you agree with, say why not for the rest, commit, and run the script again. Gannin says when the review has settled, or to carry on without one.
- Commit in each worktree, and open a pull request per repo with `gh pr create`, putting "Closes andrew-waters/gannin#233" in its body so it links to the issue.
- A plan for this issue goes in the harness as `plans/YYYY-MM-DD-<slug>.md` from `plans/_template.md` (older harnesses keep plans in `requirements/<module>/plans/`), with `issues: [andrew-waters/gannin#233]` and a summary in its front matter as the harness's STANDARDS.md sets out, so Gannin links it to the issue. Commit and push it in the harness, and tick its checkboxes off as tasks land. When the harness is the code repo, the plan goes in its worktree and ships in the same pull request, and only if the repo keeps a `plans/` folder.
- `.worktrees/233-sync-pollers-read-the-shared-pr-store/.gannin/` is Gannin's (this brief and the session's hooks). `.worktrees/` and `projects/` are kept out of the harness's git.
