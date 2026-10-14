# andrew-waters/gannin#234: Sync: keep one copy of open issues on disk

https://github.com/andrew-waters/gannin/issues/234

- State: open
- Opened by: @dwrss, 11 Oct 2026
- Parent: #213 Fix overlapping sync fetches and consolidate sync code (https://github.com/andrew-waters/gannin/issues/213)

## Description

## Problem

Every open issue is stored twice on disk and kept up to date twice: in `OrgSnapshot.issues` (the light version `OrgStore` fetches) and in `IssueHistory.issues` (the heavy version `IssueStore` fetches, with timeline events and board fields). Board field values are also in `ProjectStore`'s items, and `IssueStore.record*` merges them by hand so edits show in both.

## Proposal

One source for open issues. `OrgStore` derives its light view from the issue store, or the reverse, and `ProjectStore`'s item field values merge through one write path instead of the hand merging in `IssueStore.record*`.

## Acceptance criteria

- [ ] Open issues have a single copy on disk
- [ ] The workload, Inbox and issue pages show the same data as before, covered by tests
- [ ] Board field edits update every view through one write path
- [ ] Existing caches migrate or are rebuilt, with the backfill called out in the release notes
- [ ] Docs: none unless a Sync setting's meaning changes

## Context

Part of #213. Plan: `plans/2026-10-11-sync-overlap-and-cleanup.md`, Stage 3d. Depends on the Stage 0 issue. Independent of 3a to 3c, though it also touches `OrgStore` and `IssueStore`.

## Comments

### @dwrss, 11 Oct 2026 at 11:36

**Decision needed before building: may an upgrade rebuild a cache once?**

Changing what this store keeps on disk bumps the cache's version, and an old cache is then discarded and fetched again from GitHub (a backfill of the metrics window, the issue history or the work log, spending API budget once).

Open question for the owner: is that acceptable, with the backfill called out in the release notes? If not, this needs a migration that reads the old file instead, which is more work.

Also decide first whether the Stage 0 numbers on #230 say this is worth doing at all.


## Working here

- You're in the team's harness, andrew-waters/gannin, checked out at `~/Projects/gannin`. Its CLAUDE.md lists the projects and how work goes here.
- The code repos are shared clones under `projects/<name>` (some a folder further down, as `projects/<group>/<name>`), kept on their default branch. Don't work in them. This issue's folder is `.worktrees/234-sync-keep-one-copy-of-open-issues-on/`: give each repo it touches a worktree there, on the branch `234-sync-keep-one-copy-of-open-issues-on`, from the harness root:

  ```bash
  git -C projects/<name> fetch origin
  git -C projects/<name> worktree add "$PWD/.worktrees/234-sync-keep-one-copy-of-open-issues-on/<name>" -b 234-sync-keep-one-copy-of-open-issues-on origin/HEAD
  ```

  If the branch already exists, leave out `-b` and `origin/HEAD`. If a repo isn't under `projects/` yet, clone it there first with `gh repo clone <owner>/<name> projects/<name>`.
- If the harness has no `projects/` folder, it's the code repo too: the code is andrew-waters/gannin itself. Don't work in its checkout; give it one worktree in the issue's folder the same way, with `git -C . fetch origin` and `git -C . worktree add "$PWD/.worktrees/234-sync-keep-one-copy-of-open-issues-on/gannin" -b 234-sync-keep-one-copy-of-open-issues-on origin/HEAD`, and do everything there, the plan included.
- When the change is ready for review (committed, built and checked; before a pull request is opened as ready for review, though a draft is fine), run `.worktrees/234-sync-keep-one-copy-of-open-issues-on/.gannin/ready-for-review "<what changed and where to look>"` and end your turn. Gannin may have a second agent review it; it can't edit, and its findings come back to you as a message. Fix those you agree with, say why not for the rest, commit, and run the script again. Gannin says when the review has settled, or to carry on without one.
- Commit in each worktree, and open a pull request per repo with `gh pr create`, putting "Closes andrew-waters/gannin#234" in its body so it links to the issue.
- A plan for this issue goes in the harness as `plans/YYYY-MM-DD-<slug>.md` from `plans/_template.md` (older harnesses keep plans in `requirements/<module>/plans/`), with `issues: [andrew-waters/gannin#234]` and a summary in its front matter as the harness's STANDARDS.md sets out, so Gannin links it to the issue. Commit and push it in the harness, and tick its checkboxes off as tasks land. When the harness is the code repo, the plan goes in its worktree and ships in the same pull request, and only if the repo keeps a `plans/` folder.
- `.worktrees/234-sync-keep-one-copy-of-open-issues-on/.gannin/` is Gannin's (this brief and the session's hooks). `.worktrees/` and `projects/` are kept out of the harness's git.
