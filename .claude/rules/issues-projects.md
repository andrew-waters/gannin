---
paths:
  - "Gannin/Issues/**"
  - "Gannin/Projects/**"
  - "Gannin/FieldViews/**"
  - "Gannin/Planning/**"
---

# Issues, boards, views, planning

## Issue history (`IssueStore`)
- Keeps issues closed since the window's starting Monday plus every open issue, with board status changes (`ProjectV2ItemStatusChangedEvent`), assignments, reopenings, sub-issues added and closing PRs. Closed weeks are parallel searches, changes are by `updated:`.
- Open issues are refetched in full hourly or on Full Refresh (`refetchOpen`; plain Refresh doesn't) because board moves don't touch `updatedAt`. Reading boards needs the `project` scope.
- Outside repos (`OrgConfig.outsideRepos`) are separate `repo:`-qualified batched searches (`GitHubAPI.outsideRepoCohorts`/`outsideRepoBatches`). A new one gets a full backfill (back to the history's `coveredFrom` if deeper than the window); a known one trusts a changes search. `IssueHistory.outsideReposFetched` tracks which have a baseline.
- Unreadable outside repos come from `OrgStore.snapshot(for:)?.unreadableRepos`, not a fresh GitHub call. Until that snapshot has loaded readability is unknown, not clear (`IssueStore.outsideRepoPlan`), so they're skipped that round rather than searched and possibly pruned on a guess. A known outside repo is also fetched hourly by the workload snapshot: an accepted doubling of cost.
- Pages that let outside repos through (via `repoExclusion`): All, Not on a board, Views, Epics, Board Hygiene, Prioritisation, Dashboard's committed-overdue flag, Inbox, Ask. Issue flow, Investments, Recap, Scorecards, Standup and the Weekly Digest's Shipped list call `OrgConfig.excludesForIssueHistoryPages`, which never does, so `outsideReposNotice` stays accurate.
- `PullRequest.changedFiles` is optional so old caches load; a snapshot without it is searched in full next refresh (`OrgSnapshot.lacksFileCounts`), and old `MetricsHistory` PRs are looked up once by node ID (`MetricsHistory.filledChangedFiles`, 25 a query, halved on GitHub timeout, saved as it goes).
- `IssueWorkflow`: cycle time stops on any non-in-progress status or close and restarts on return; lead time is created to closed as completed; flow efficiency is the share of in-progress days with linked PR activity; scope creep is the share of sub-issues added after work started.

## Issue pages
- Filters (`IssueFilters`) persist per window (`StoredIssueFilters`); columns in `allIssuesColumns`. Both filter bars build on `FilterMenu`, `FilterSearchField`, `StoredSet` (`IssueFilterBar.swift`). Sub-issues fold under a listed parent (`IssueTableRow.tree`), flat while searching or filtering.
- `MarkdownText` only touches HTML tag names, never inside code; unknown tags are dropped keeping their text.
- Bulk add to a board goes through `BulkWriteSheet` (confirm, then each ticked off) and records locally (`IssueStore.recordAddedToBoard`).
- `IssueRecord.projectFields` holds board field values; "In progress now" can order by one, and issues not on the chosen board are labelled, not hidden.

## New Issue and images
- `PageStack` holds the sheet and hands out `NewIssueAction` (`NewIssueContext`: repo, board, field values, parent). Create writes in order: images, `createIssue`, `addSubIssue`, `addToBoard`, then each field with `setProjectField`. A draft item uses `addProjectV2DraftIssue`.
- GitHub's API has no issue-attachment upload, so images are committed to `harness(covering:)` in one commit per issue (`HarnessStore.commit`) at `attachments/issues/<owner>/<name>/<date>-<id>/<file>`, linked as `https://github.com/<harness>/blob/<commit>/<path>?raw=true` (inline only for people who can read the harness). Committed before the issue; the Create button naming them is the confirmation.
- `IssueImageSet` remembers what was committed so a retry after GitHub refuses the issue doesn't recommit, unless the repo (so maybe the harness) changed. `IssueImages.prepared`: PNG/JPEG/GIF/WebP kept, others to PNG, over 5 MB to JPEG if it fits. `IssueImages.body` rewrites `![name](attachment:name)` placeholders: points at the commit, appends images with none, drops removed ones. No harness means no images. `skills/create-issue.md` does the same with `gh api`.

## Projects
- Board items are fetched with the view's filter passed to GitHub (`items(query:)`, GitHub's syntax). `ProjectStore` caches each board's definition and each filter's items on disk. Changes in a board view are local, never saved back.
- `ProjectStore.allBoards` includes closed boards; `boardLists` and `boards` are the open ones everything else uses.
- Board writes (`BoardWrites.swift`: `createProjectV2`, `copyProjectV2`, `linkProjectV2ToRepository`, `unlinkProjectV2FromRepository`, `updateProjectV2`) are confirmed first.

## Views and Board Fields
- Writes are always confirmed (`FieldWriteSheet` over `BulkWriteSheet`). `FieldWriter` sets single-select and iteration values, adding the issue to the board first; the investments board write uses it too.
- `IssueSignals` (through `FieldContext`) derives time in status, time in progress (`IssueTiming`) and Attention flags.
- Board Fields (`BoardFieldsEditor`): each option is sent back with its ID so issues keep their values. Iterations are read-only (GitHub doesn't keep their identity from outside). Changes are reviewed first; `IssueStore.rewriteFieldValues` updates stored issues at once. Multi-select values are read (`IssueFieldValue.options`) but not written.

## Planning
- `PlanningWrites.swift` (`closeIssue`, `createIssue`, `addSubIssue`) are confirmed by their callers. The mutations are nullable, so an empty response must be treated as a refusal (no write access).
