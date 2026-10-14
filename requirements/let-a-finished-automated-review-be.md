---
type: requirement
status: in-progress
summary: "After making more changes to ongoing work, the user can launch the background reviewer again from the session panel, sees it start, and it reviews the work as it is now."
issues: [andrew-waters/gannin#350]
plans: [plans/2026-10-14-let-a-finished-automated-review-be.md]
---

# Relaunch a finished automated review

## Problem

The background reviewer on ongoing work finishes (settled, round limit or stopped) and its session is ended. When the user makes more changes and clicks Review Now in the session panel, nothing visibly happens, so they can't launch the reviewer again.

## Goal

After making more changes to ongoing work, the user can launch the background reviewer again from the session panel, sees it start, and it reviews the work as it is now.

## Who it's for

People working on an issue in a Gannin session with pair review on.

## Requirements

1. Make Review Now start the reviewer again after its loop has finished, and show that it has
2. Say why when it can't start, instead of doing nothing

## Out of scope

- Watched reviews of pull requests (AutoReview)
- Starting the reviewer automatically when changes appear
- Posting anything to GitHub from the loop
- Changing the 3-round limit

## Acceptance criteria

- **R1** When the loop is over (settled, at the round limit or stopped) and the user clicks Review Now, the system shall start a new round, and the panel's status shall show the reviewer is looking.
- **R2** When Review Now starts the reviewer, the system shall make that visible to the user (the reviewer's tab shows it working).
- **R3** When a new round starts after more changes, the reviewer shall look at every change in the worktree as it is now, committed or not, and leave out findings already dealt with.
- **R4** When Review Now can't start the reviewer, the system shall tell the user why instead of doing nothing.
- **R5** When the work ships, the pair review page under docs-site/src/content/docs/agents/ shall describe how to launch the reviewer again, and CHANGELOG.md shall have an Unreleased line.

Planned in [plans/2026-10-14-let-a-finished-automated-review-be.md](../plans/2026-10-14-let-a-finished-automated-review-be.md).
