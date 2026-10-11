# Changelog

All notable changes to Gannin are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Add your change under `## [Unreleased]` in the pull request that makes it, in an `Added`,
`Changed` or `Fixed` group. `docs/RELEASING.md` says how a release takes them.

## [Unreleased]

### Changed
- GitHub requests are now limited to 8 in flight across the app, so a Refresh can't trip GitHub's secondary rate limit; opening a PR, issue or review keeps two of those slots free so it doesn't wait behind a sync
- Refresh no longer fetches every open issue again each time; that happens on its own interval (Settings › Sync › Every open issue) or with Full Refresh, which saves API budget
- Each metrics sync fetches merged PRs from a day before the last sync to the second, rather than from the start of that day, so it downloads up to a day less

### Fixed
- Expanding a parent issue in Issues › All no longer crashes when it's showing sub-issues; the agent queue pill and Schedule for Agent menu, on each row, didn't reliably get their environment when a row was revealed by expanding its parent, which only `NSOutlineView` builds, outside the view's normal update cycle
- An org with more than 1000 open issues no longer loses its older open issues from Gannin when every open issue is fetched again; GitHub returns only 1000 of them, so ones it doesn't return are kept until they change
- A harness repo with too many files for GitHub to list at once now says so, instead of indexing only some of its documents without a word
- Issues › All, Not on a board and Views now show an outside repo's issues when the window's project names it, as Pull Requests already did; the issue history wasn't fetching them at all

### Added
- Post automatic reviews in Settings › Harness: each project can say on, off or as in Settings, instead of every project following the one Mac-wide choice
- Refines under Harness: a `refines/` folder for Design and Refine session records, in new harnesses too
- A sandbox's activity (Claude starting, prompts, the tools it uses, failures and when it's waiting on you) now shows in `container logs` and Orchard, with nothing from inside the commands or files and tokens redacted
- Session rules in Settings › General: block force pushes, pushes to other branches, branch and tag deletes, release writes, too many PR comments an hour, or commands of your own (or ask you first), checked outside Claude in every session

## [0.0.2] - 2026-10-05

### Added
- Projects as workspaces: each window picks Org › Project, with its own repos, harness, boards and settings
- A command palette (⌘K) for search and actions across every org
- New Issue (⌘N), with templates, a board, fields and a parent, and drafting with Claude
- Milestones and GitHub Releases under Delivery, with progress and the release each shipped
- Auto review when your review is requested, watching reviewed PRs for changes and resolving threads a later review says are dealt with
- Sessions watch their PRs across launches and can send new review feedback to Claude
- Choose a PR's reviewers from its drawer, and a tidier PR drawer
- Boards linked to a repo, a Boards page in place of a repo's Projects tab, and faster, more reliable board loading
- Harness document details with editable status, owner and domains, and single-repo harnesses
- Blockquotes, GitHub's alerts and more of its HTML rendered in descriptions

## [0.0.1] - 2026-10-02

### Added
- The first build of Gannin for Mac, signed, notarised and updating itself from gannin.ai
