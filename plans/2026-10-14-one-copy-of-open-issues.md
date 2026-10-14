---
type: plan
status: proposed
summary: "One IssueStore-shared record per open issue (core fields plus a workload slot and a history slot) replaces OrgSnapshot.issues and IssueHistory's open records, and board field edits go through one write path; old caches migrate in place."
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

- `IssueStore`-shared `StoredIssue` keyed by node ID per org: core (repo, number, title, url, state, dates,
  author, assignees with avatars, labels with colours, `updatedAt`), a `workload` slot (linked PRs as `LinkedItem`)
  and a `history` slot (`IssueRecord`'s extras: status changes, assigned and reopened dates, sub-issues, mentions,
  project fields, type, milestone, parent, stateReason).
- Core fields are optional and merge one by one; each slot records the `updatedAt` it was fetched at and the change
  feed's skip check reads that, never the core's.
- `OrgSnapshot`'s file lists open issue IDs, hydrated on load through `OrgSnapshotCache` (a `Legacy` decode moves old
  issues across). `IssueHistory`'s file keeps closed records and coverage, with a stored count so a cleared store
  can't leave a history claiming a range it no longer has.
- Per-slot clear, so clearing the workload doesn't drop the history.
- One write path: a single `apply` on the shared store changes core, labels, status and board field values;
  `IssueStore.record*`, `rewriteFieldValues` and `ProjectStore.recordFieldValue/recordLabels/recordClosed` call it
  or are replaced by it. Callers: `FieldWrites.swift`, `ProjectFieldsSections.swift`, `BoardFields.swift`,
  `InvestmentWrites.swift`, `OffBoardIssuesView.swift`, `BoardHygieneView.swift`.
- Readers to check: `Workload.swift`, `PaletteItems.swift` (its dedupe may simplify), `OrgSettingsView`,
  `PlanningAgree`, `HiddenStore`, `DemoFixture`.

## Open points to confirm while building

- Whether `ProjectStore`'s `BoardItem.values` is read from the shared store or stays a view of its own fetch; the
  criterion is that an edit reaches every view through one path, which it can do with the board cache still saved.
- Open-set coverage: `OrgStore` and `IssueStore` scope outside repos differently (`repoExclusion` vs
  `excludesForIssueHistoryPages`), and `IssueStore` prunes open issues after a full fetch. The slots must keep
  their own membership so one store's prune doesn't remove the other's issues.
- `WorkLogStore` also keeps issues (`WorkLogHistory.issues`); out of scope here, moved to andrew-waters/gannin#359.

## Tasks

- [ ] Shared issue store: core, slots, merge, per-slot clear, tests
- [ ] `OrgSnapshotCache`: issue IDs in the file, hydrate, `Legacy` migration, tests
- [ ] `IssueStore`: history reads and writes open records through the store, migrating the old file
- [ ] One write path for board field, label, status and added-to-board edits; move callers
- [ ] Test: the workload built from the store equals the workload built from the old snapshot
- [ ] `.claude/rules/fetching.md` rule for issues, CHANGELOG `[Unreleased]` line, docs: none
