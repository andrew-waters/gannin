---
paths:
  - "Gannin/Issues/**"
  - "Gannin/Projects/**"
  - "Gannin/FieldViews/**"
  - "Gannin/Planning/**"
---

# Issues, boards, views, planning

## Writes
- Every GitHub write (board, field, issue, bulk) must be confirmed by the user first, through `BulkWriteSheet`/`FieldWriteSheet` or the caller's sheet.
- Never save board view changes back to GitHub; they are local.
- Treat an empty response from `PlanningWrites.swift` mutations as a refusal (no write access).
- Board Fields: send each option back with its ID so issues keep their values; never write iterations (GitHub drops their identity) or multi-select values.
- New Issue create order: images, `createIssue`, `addSubIssue`, `addToBoard`, then each `setProjectField`.

## Issue history (`IssueStore`)
- Refetch open issues in full hourly or on Full Refresh only (`refetchOpen`): board moves don't touch `updatedAt`. Reading boards needs the `project` scope.
- Unreadable outside repos come from the workload snapshot (`unreadableRepos`), never a fresh GitHub call. Until it has loaded, treat readability as unknown and skip the repo that round (`outsideRepoPlan`), so nothing is pruned on a guess.
- Pages that let outside repos through use `repoExclusion`; Issue flow, Investments, Recap, Scorecards, Standup and the Weekly Digest call `excludesForIssueHistoryPages` so `outsideReposNotice` stays accurate. Keep new pages on the right side of that split.
- `PullRequest.changedFiles` stays optional so old caches load (`lacksFileCounts`, `filledChangedFiles` backfill them).

## Images on issues
- GitHub has no attachment upload, so images are committed to `harness(covering:)` at `attachments/issues/<owner>/<name>/<date>-<id>/<file>` and linked `?raw=true`. Commit them before creating the issue, in one commit; the Create button naming them is the confirmation.
- Never recommit on a retry (`IssueImageSet`) unless the repo changed. With no harness, images can't be attached.
- Keep `skills/create-issue.md` in step with this flow.

## Project boards
- Never draw `BoardTableView`'s rows with `StatsTable`: it builds every row at once, which froze the app for seconds on a board of thousands of items. Rows stay in the one lazy stack, flattened by `BoardTableModel`. Its header, cell framing and row look are a copy of `StatsTable`'s, so change both when one changes.
- Keep `BoardTableView`'s rows and headers as their own `Equatable` views applied with `.equatable()`, with only plain values in `==` and the closures left out: a row drawn by a method in `body`, or compared through a closure, re-runs on every table change. Cells are concrete views, never `AnyView`.
- Read and write the board cache through `ProjectStore.loadCached` and `save` only: they decode and encode off the main actor, one write per board at a time. `clear` goes through `BoardCacheFiles.reset`, which stops a write started before it landing after it; a write still waiting is flushed at quit. The `BoardCache` types are `nonisolated` so they can encode there.

## Markdown
- `MarkdownText` rewrites HTML tag names only, never inside code.

## Testing
- Covered: `BoardTableModelTests` (the table's flattening, grouping and sort), `BoardTableColumnTests` (the table's columns, their widths and sort keys), `IssueHistoryOutsideRepoTests`, `OutsideRepo*Tests`, `UnreadableReposTests`, `IssueImagesTests`, `PrioritySchemeTests`.
- Not covered: filters, FieldViews, board writes, `IssueWorkflow`; check by hand in the app.
