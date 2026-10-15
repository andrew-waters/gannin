---
type: plan
status: In Review
summary: The sub-issue count on an agreed plan reads the parent's current sub-issues from the issue history, so one added after Agree is counted.
issues: [andrew-waters/gannin#182]
domains: [planning]
touches: [andrew-waters/gannin]
owner: andrew-waters
---

# Live sub-issue count on an agreed plan

## Context

`PlanningWorkspaceView.agreedStatus` showed `agreed.issues.count`, the URLs recorded when Agree wrote
the plan. A sub-issue added to the parent afterwards never appeared in "N sub-issues".

## Decisions

- Count the parent's children in `IssueStore`'s history (`IssueRecord.parentID` equal to the parent's
  node ID), the same source as Planning › Epics.
- Never show fewer than the recorded `agreed.issues.count`: the history may not be loaded, may not
  hold the parent, or may not yet hold the children Agree just made.
- Hold the count in `@State` and recompute it when the history's `syncedAt` changes, not in the
  view body, which would scan every issue on each render.

## Tasks

- [x] `PlanningWorkspaceView` reads the live count, with the recorded one as the fallback
- [x] Test for the count helper
- [x] Changelog line under Fixed
