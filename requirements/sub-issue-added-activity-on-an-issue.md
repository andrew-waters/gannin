---
type: requirement
status: in-progress
summary: "The entry names the sub-issue that was added and lets the reader open it in Gannin."
issues: [andrew-waters/gannin#431]
plans: [plans/2026-10-20-sub-issue-added-activity-on-an-issue.md]
---

# Sub-issue added activity shows the wrong title

## Problem

On the parent issue's page, the 'sub-issue added' activity entry shows the parent issue's title, so a reader can't tell which issue was added. Clicking the title does nothing, so there is no route to the sub-issue from the activity.

## Goal

The entry names the sub-issue that was added and lets the reader open it in Gannin.

## Who it's for

Anyone reading an issue's activity in Gannin.

## Requirements

1. Sub-issue added entry on the parent issue's page shows the sub-issue's title
2. Clicking that title opens the sub-issue's page in Gannin

## Out of scope

- The child issue's own page (followed up separately)
- Making titles clickable on other activity entries (follow-up if they share the cause)
- Sub-issue removed entries: the issue timeline doesn't fetch or show them today; showing them is a new feature for a follow-up issue

## Acceptance criteria

- **R1** When a sub-issue added entry is shown on the parent issue's page, the system shall show the sub-issue's title, not the parent's.
- **R2** When the user clicks the title in that entry, the system shall open the sub-issue's page in Gannin.
- **R3** When this change ships, no page under docs-site/src/content/docs/ changes, and CHANGELOG.md gains a line under [Unreleased].

Planned in [plans/2026-10-20-sub-issue-added-activity-on-an-issue.md](../plans/2026-10-20-sub-issue-added-activity-on-an-issue.md).
