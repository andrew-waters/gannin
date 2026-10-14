---
type: plan
status: in-progress
summary: "One SharedIssueStore keeps each issue once per org (core fields plus a workload slot and a history slot), so OrgSnapshot and IssueHistory stop saving their own copies, board field and label edits go through IssueEdits, and old caches migrate in place."
issues: [andrew-waters/gannin#234]
touches: [andrew-waters/gannin]
owner: dwrss
---

# Sync: one copy of open issues

## Context

Stage 3d of `plans/2026-10-11-sync-overlap-and-cleanup.md` (parent andrew-waters/gannin#213). Open issues are saved
twice: `OrgSnapshot.issues` (`Issue`, fetched by `OrgStore`) and `IssueHistory.issues` (`IssueRecord`, fetched by
`IssueStore`). A board field edit is also applied by hand to `IssueStore.record*` and `ProjectStore.record*`.

#230 (Stage 0) has a first Spent reading only: issues don't appear in it, and it says 3d matters less for API cost.
This stage is built for disk and for one write path, as the acceptance criteria say, not to lower Spent.

## Decisions (from the owner)

- **Build it** despite the Stage 0 reading.
- **Shared store, core plus slots**, as `PullRequestStore` (#232). Deriving the workload from `IssueStore` was
  rejected: `Issue` has avatars, label colours and linked PR state that `IssueRecord` lacks, and the workload can't
  be switched off while `IssueStore` stops when Issues sync is off and fills only once its page opens.
- **Migrate old caches in place**: no backfill, so no release-note backfill callout.

## Design

- `SharedIssueStore` keeps one `StoredIssue` per issue per org, keyed by node ID, in `StoredIssues/<org>.json`:
  core (repo, number, title, url, author, dates, `closedAt`, `updatedAt`, assignees with avatars, labels with
  colours), a `workload` slot (linked PRs as `LinkedItem`) and a `history` slot (`IssueRecord`'s extras: status
  changes, assigned and reopened dates, sub-issues, mentions, project fields, type, milestone, parent,
  `stateReason`). Closed issues are in it too, as merged PRs are in `PullRequestStore`.
- Core scalars merge newer-over-older; people merge by login and labels by name, so a history fetch (names only)
  keeps the avatars and colours the workload fetch saved. When the held `updatedAt` is newer than an incoming
  fetch's, the held core wins.
- Each slot records the `updatedAt` it was fetched at and is replaced only by a slot fetched at least as recently.
  The change feed's skip check reads the history slot's, as `IssueStore.feedPlan` already did through
  `IssueRecord.updatedAt`.
- `OrgSnapshot`'s file lists `storedIssueIDs`; `OrgSnapshotCache.load` fills `issues` from the store. An issue the
  history has since seen closed is left out of the workload, not treated as missing. `IssueHistory`'s file keeps
  coverage and `storedIDs`, and `IssueStore.loadCached` drops it when the store no longer holds an ID it lists.
  The in-memory `OrgSnapshot.issues` and `IssueHistory.issues` stay full values, as the PR snapshot does, so no
  reader changes.
- Old `Snapshots/` and `Issues/` files are read once (`OrgSnapshot.LegacyIssues`, `IssueHistory.Legacy`), their
  issues moved into the store and the files rewritten without them.
- Per-slot clear, so clearing the workload doesn't drop the history. Settings › Storage gains an Issues row.
- One write path: `IssueEdits.setField` and `setLabels` change `IssueStore` (the stored issue) and `ProjectStore`
  (each cached board's item) together; `FieldWrites`, `ProjectFieldsSections` and `InvestmentWrites` call it
  instead of both stores. `IssueStore.record*` write the issue through to the shared store.

## Decisions made while building

- `ProjectStore`'s board cache stays its own file: its items cover drafts, PRs and per-filter lists the issue
  store doesn't hold. The edit reaches both through `IssueEdits`.
- Each store keeps its own membership by slot: `IssueStore`'s prune removes only the history slot, and the
  workload's save removes only the workload slot.
- `recordClosed` (Board Hygiene), `recordRemoved` and `recordAddedToBoard` still update one store each, as before;
  they aren't field or label edits.
- Writing the shared file rewrites every issue's JSON, closed history included, where the snapshot file alone was
  rewritten before. `PullRequestStore` already behaves this way.
- Going back to a build from before this one needs a full backfill: it requires `issues` in the old files.
- `WorkLogStore` also keeps issues (`WorkLogHistory.issues`); andrew-waters/gannin#359.

## Tasks

- [x] Shared issue store: core, slots, merge, per-slot clear, tests
- [x] `OrgSnapshotCache`: issue IDs in the file, hydrate, `Legacy` migration, tests
- [x] `IssueStore`: history reads and writes open records through the store, migrating the old file
- [x] One write path for board field, label, status and added-to-board edits; move callers
- [x] Test: the workload built from the store equals the workload built from the old snapshot
- [x] `.claude/rules/fetching.md` rule for issues, CHANGELOG `[Unreleased]` line, docs: none
