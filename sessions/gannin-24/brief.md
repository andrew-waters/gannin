# andrew-waters/gannin#24: Releases page shows every release, with download and star stats for each repository

https://github.com/andrew-waters/gannin/issues/24

- State: open
- Labels: bug, enhancement
- Opened by: @andrew-waters, 6 Oct 2026
- Assignees: @andrew-waters
- Board "Roadmap": Status Todo

## Description

## Problem

The releases page is truncated: not every release appears. The likely cause is that only the first page of results from the GitHub API is fetched and later pages are never requested. This has not been confirmed in the code yet.

Not yet known:
- Which repositories or how many releases it takes to trigger the truncation.
- Whether releases are dropped at a fixed count (for example 30, the GitHub API default page size) or in some other way.

The releases view also has no usage signal for the repositories it covers. There is no way to see how much each release is downloaded or how a repository's stars are growing.

## Proposal

1. **Fix truncation.** Show every release for each repository, not just the first page.
2. **Per-repository stats in releases.** Show download counts and star counts for each repository listed in the releases view.
3. **Main view summary.**
   - Total downloads across repositories.
   - A graph of downloads over time.
   - Star counts, with a graph of stars over time in the style of a stargazers chart.

Not yet decided:
- Where download counts come from. GitHub release asset `download_count` is the obvious source, but it is a running total. A graph over time would need Gannin to record snapshots periodically, unless another source is used. Nobody has decided how often to snapshot or where to store the snapshots.
- Whether star history comes from the stargazers API (which gives a `starred_at` date for each star, so history can be rebuilt) or from Gannin's own snapshots.
- Whether "main view" means the top of the releases page or Gannin's home view.
- Whether totals cover every repository Gannin tracks or only the ones that publish releases.
- What "star gazer type graphic" should look like exactly: a cumulative stars line, avatars of recent stargazers, or both.

## Acceptance

- [ ] The releases page lists every release for a repository with more releases than one API page holds.
- [ ] Each repository in the releases view shows its download count and star count.
- [ ] The main view shows total downloads.
- [ ] The main view shows a graph of downloads over time.
- [ ] The main view shows star counts and a stars-over-time graphic.
- [ ] Data sources and refresh/snapshot approach for the time-series graphs are decided and noted on this issue.

## Context

Raised by andrew-waters. No parent issue, harness document or related PRs identified. The duplicate check has not been run yet.

## Working here

- You're in the team's harness, andrew-waters/gannin, checked out at `~/Code/andrew-waters/gannin`. Its CLAUDE.md lists the projects and how work goes here.
- The code repos are shared clones under `projects/<name>` (some a folder further down, as `projects/<group>/<name>`), kept on their default branch. Don't work in them. This issue's folder is `.worktrees/24-releases-page-shows-every-release-with/`: give each repo it touches a worktree there, on the branch `24-releases-page-shows-every-release-with`, from the harness root:

  ```bash
  git -C projects/<name> fetch origin
  git -C projects/<name> worktree add "$PWD/.worktrees/24-releases-page-shows-every-release-with/<name>" -b 24-releases-page-shows-every-release-with origin/HEAD
  ```

  If the branch already exists, leave out `-b` and `origin/HEAD`. If a repo isn't under `projects/` yet, clone it there first with `gh repo clone <owner>/<name> projects/<name>`.
- If the harness has no `projects/` folder, it's the code repo too: the code is andrew-waters/gannin itself. Don't work in its checkout; give it one worktree in the issue's folder the same way, with `git -C . fetch origin` and `git -C . worktree add "$PWD/.worktrees/24-releases-page-shows-every-release-with/gannin" -b 24-releases-page-shows-every-release-with origin/HEAD`, and do everything there, the plan included.
- Commit in each worktree, and open a pull request per repo with `gh pr create`, putting "Closes andrew-waters/gannin#24" in its body so it links to the issue.
- A plan for this issue goes in the harness as `plans/YYYY-MM-DD-<slug>.md` from `plans/_template.md` (older harnesses keep plans in `requirements/<module>/plans/`), with `issues: [andrew-waters/gannin#24]` and a summary in its front matter as the harness's STANDARDS.md sets out, so Gannin links it to the issue. Commit and push it in the harness, and tick its checkboxes off as tasks land. When the harness is the code repo, the plan goes in its worktree and ships in the same pull request, and only if the repo keeps a `plans/` folder.
- `.worktrees/24-releases-page-shows-every-release-with/.gannin/` is Gannin's (this brief and the session's hooks). `.worktrees/` and `projects/` are kept out of the harness's git.
