---
type: plan
status: in-progress
summary: "The work log's issues move into SharedIssueStore as a workLog slot holding the comments, its file keeps only coverage and a count, issue changes come from the change feed, and a capped weekly issue search is split into days."
issues: [andrew-waters/gannin#359]
touches: [andrew-waters/gannin]
owner: dwrss
---

# Sync: stop the work log keeping its own copy of issues

## Context

Stage 3d of `plans/2026-10-11-sync-overlap-and-cleanup.md` (parent andrew-waters/gannin#213), after
`plans/2026-10-14-one-copy-of-open-issues.md` (andrew-waters/gannin#234). `WorkLogHistory.issues` saved a title, URL, repo,
author and creation date that `SharedIssueStore` already holds, and `WorkLogStore` searched for changed issues itself.

## Decisions (from the owner)

- **Comments go in a new `workLog` slot in `SharedIssueStore`**, as the PRs' `WorkLogExtras` do in `PullRequestStore`.
- **A capped weekly issue search is split into days, issues only.** The PR search is #236.

## Design

- `WorkLogIssueExtras` (`updatedAt`, `comments`) is a third slot on `StoredIssue`; `Slot`, `merged`, `has`, `remove` and
  `isEmpty` cover it. `StoredIssue(workLog:)` and `workLogIssue` convert to and from `WorkLogIssue`.
- `WorkLogHistory.issues` stays an in-memory dictionary, filled from the store in `WorkLogStore.loadCached`, so no
  reader changes. The file keeps coverage and `storedIssueCount`; a log whose store holds fewer issues is dropped.
- `WorkLogIssue` gains `closedAt`, `updatedAt`, `assignees` and `labels` (all optional): the core needs them so that
  saving a work log issue neither reopens a closed one nor empties the lists the workload saved.
- Version 6. A version 4 or 5 file's issues are read once (`WorkLogHistory.LegacyIssues`), merged into the store with no
  `updatedAt`, and the file is rewritten without them. No backfill.
- `issueFeedPlan` mirrors `feedPlan` for `.issue` entries in the account's own repos, skipping an issue whose slot
  `updatedAt` is held. `workLogIssues(ids:)` fetches them. `workLogIssueSearch` since the cursor runs only on fallback.
- After the counts preflight, an issue search whose count reaches `ParallelSearches.searchCap` is replaced by day-long
  searches (`splittingCapped`) and counted again for the progress total.

## Tasks

- [x] `workLog` slot in `SharedIssueStore`, conversions, merge
- [x] `WorkLogHistory` version 6, file keeps coverage and count, version 4 and 5 migration
- [x] Issue change feed plan and fetch by ID; search is the fallback
- [x] Capped weekly issue search split into days
- [x] Tests: `WorkLogIssueStoreTests`
- [x] Rules, CHANGELOG `[Unreleased]`, docs: none
- [ ] Full build and test run (blocked locally: the Metal Toolchain isn't installed, which SwiftTerm needs)
