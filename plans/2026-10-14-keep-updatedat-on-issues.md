---
type: plan
status: in-progress
summary: "Work out an issue's last-activity date from the local issue history so Triage can tell which bucketed issues have changed since the last pass. IssueRecord.updatedAt itself is already stored."
issues: [andrew-waters/gannin#159]
touches: [andrew-waters/gannin]
owner: dwrss
agreed_by: [dwrss]
agreed_at: 2026-10-14
requirement: requirements/keep-updatedat-on-issues.md
---

# Keep updatedAt on issues

Work out an issue's last-activity date from the local issue history so Triage can tell which bucketed issues have changed since the last pass. IssueRecord.updatedAt itself is already stored.

## Requirement

In full in [requirements/keep-updatedat-on-issues.md](../requirements/keep-updatedat-on-issues.md).

**Problem:** Triage's re-check (R5 of the Triage plan) needs to know which bucketed issues have had activity since the last pass, or it has to re-queue every one. IssueRecord already stores GitHub's updatedAt, but nothing combines it with board moves, reopenings, sub-issues and linked PR dates into one last-activity date, and nothing tests that older caches without it load.

**Goal:** One place answers 'when did this issue last have activity?' from the local issue history, using every dated source it holds, ready for the Triage queue (#160) to compare against the last pass.

**Who it's for:** The product lead running the weekly Triage pass (indirectly); engineers building the Triage queue (#160).

**Scope:**

1. Confirm IssueRecord.updatedAt is stored on every fetch and that older records without it still decode (already true; pin it with tests)
2. Work out an issue's last activity as the latest of updatedAt, board moves, reopenings, sub-issues added and linked PRs' dates

**Out of scope:**

- Showing the last-activity date anywhere in the UI (enabler only)
- The Triage queue that uses it, and how it treats an issue with no last activity (#160)
- Any change to docs-site: no user docs page changes, and no CHANGELOG line, as nothing a user sees changes

**Acceptance criteria:**

- **R1** When issues are fetched for the issue history, the system shall store each issue's GitHub updatedAt on its IssueRecord.
- **R2** When a cached IssueRecord saved without updatedAt is loaded, the system shall decode it without error and leave updatedAt unset until the issue is next fetched.
- **R3** When an issue's last activity is asked for, the system shall return the latest of its updatedAt, board moves, reopenings, sub-issues added and linked PRs' dates, ignoring any source with no date.
- **R4** When an issue has no dated source, the system shall report its last activity as none rather than a default date.

**Decisions:**

- Is #159 purely the enabler for Triage's re-check, or should the date show in the UI? **Enabler only: no new UI.**
- What counts as an issue's last activity? **The Triage plan's definition: the latest of updatedAt, board moves, reopenings, sub-issues added and linked PRs' dates.**
- Which user docs pages change? **None: internal data only.**
- updatedAt is already stored; what happens to R1 and R2? **Keep R1 to R4 as written; R1 and R2 become tests that pin the existing behaviour, R3 and R4 are the new code.**

## Design

No query, model or cache change: `IssueRecord.updatedAt` is already asked for in `RawIssueRecord.fields`, set in `model` and optional so old records decode (R1, R2 hold today).

Add `var lastActivity: Date?` to `IssueRecord` in `Gannin/Issues/IssueModels.swift`, beside `isOpen` and `fields(onProject:)`. It is the maximum of `updatedAt`, `statusChanges[].at`, `reopenedAt`, `subIssuesAddedAt` and the dates of `linkedPullRequests` (`createdAt`, `mergedAt`, `activityAt`) and `mentionedInPullRequests` (`createdAt`, `mergedAt`; that list is optional, so it counts as empty when nil), and nil when none of them has a date (R3, R4). It is computed on read, not stored, so it needs no `IssueHistory.currentVersion` bump and can't drift from the sources it reads.

Tests in `GanninTests`, building records the way `PrioritySchemeTests` does: R1 decodes a `RawIssueRecord`-shaped response (or `IssueRecord` JSON) with `updatedAt` and checks it lands on the record; R2 decodes an old record JSON without `updatedAt`; R3 checks each source on its own is picked up and the latest wins; R4 checks an empty record is nil.

Why a computed property: #160 only needs to compare it with `PriorityScheme.lastPass`, and it follows how IssueRecord already derives `isOpen` and friends.

Left to #160/#161: how a nil last activity is treated, and that a pass's own label and field writes bump `updatedAt`, so the comparison with `lastPass` needs to tolerate Gannin's own writes.

**Areas it touches:**

- `andrew-waters/gannin` `Gannin/Issues/IssueModels.swift#L40-L43`: IssueRecord already has `var updatedAt: Date? = nil`, optional so old records load, added with the shared change feed (9c85469). The Triage plan's risk saying IssueRecord keeps no updatedAt is out of date.
- `andrew-waters/gannin` `Gannin/Issues/IssueQueries.swift#L131-L233`: RawIssueRecord.fields already asks for updatedAt and model sets it. The timeline also gives statusChanges, reopenedAt, subIssuesAddedAt and assignedAt; linked PRs carry createdAt, mergedAt and activityAt (commits and reviews).

**Patterns to follow:**

- `andrew-waters/gannin` `Gannin/Issues/IssueModels.swift#L45-L51`: IssueRecord holds small derived properties (isOpen, isCompleted, fields(onProject:)); a lastActivity computed property belongs beside them and needs no stored state or cache version bump.
- `andrew-waters/gannin` `GanninTests/PrioritySchemeTests.swift#L12-L19`: A test helper that builds an IssueRecord through its memberwise initialiser with the dated arrays empty; the new tests follow it.

**Risks:**

- `andrew-waters/gannin` `Gannin/Issues/IssueModels.swift#L27-L31`: Only Status changes appear as board moves (statusChanges); other board field edits aren't dated anywhere, and GitHub's updatedAt ignores board moves. Open issues are refetched in full hourly for the same reason, so a field-only change is invisible to last activity.
- `andrew-waters/gannin` `Gannin/Issues/IssueQueries.swift#L141`: The timeline query takes the first 100 events, so a very busy issue could miss recent reopenings or status changes; updatedAt covers reopenings anyway.
- `andrew-waters/gannin` `Gannin/Issues/IssueModels.swift#L102-L113`: mentionedInPullRequests (cross-references) carry created and merged dates but not commit or review days, and the Triage plan's definition doesn't name them. The room chose to count them, which makes re-check queues more sensitive: any PR that references the issue brings it back up.

**Decisions:**

- Which PR dates count towards last activity? **Both closing PRs (linkedPullRequests) and mentioning PRs (mentionedInPullRequests).**
- Is the design right? **Yes: a computed IssueRecord.lastActivity with tests, no query, model or cache change.**

## Tasks

1. Keep updatedAt on issues: add IssueRecord.lastActivity and pin updatedAt with tests

**Decisions:**

- Are the tasks right? **Yes: one task satisfying R1 to R4.**
