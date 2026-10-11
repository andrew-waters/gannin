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

## Markdown
- `MarkdownText` rewrites HTML tag names only, never inside code.

## Testing
- Covered: `IssueHistoryOutsideRepoTests`, `OutsideRepo*Tests`, `UnreadableReposTests`, `IssueImagesTests`, `PrioritySchemeTests`.
- Not covered: filters, FieldViews, board writes, `IssueWorkflow`; check by hand in the app.
