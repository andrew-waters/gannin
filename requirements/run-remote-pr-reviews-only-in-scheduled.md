---
type: requirement
status: in-progress
summary: "The person chooses when remote reviews may use their Mac: automatic reviews start only inside review windows they set, the rest wait in a queue they can manage, and one schedule view shows review windows, routines and the queue together."
issues: [andrew-waters/gannin#438]
plans: [plans/2026-10-21-run-remote-pr-reviews-only-in-scheduled.md]
---

# Review windows and one schedule view

## Problem

A remote review ask is picked up and run on the reviewer's machine as soon as it arrives. Reviews build and run code, so they slow down whatever else the person is doing, at times they didn't choose. Scheduling is also split: routines are set up in one place, remote review pickup has no schedule, and nothing shows everything Gannin will run on the machine and when. It happens several times a day: asks arrive throughout the day and the review's builds and tests slow the machine during the person's own work.

## Goal

The person chooses when remote reviews may use their Mac: automatic reviews start only inside review windows they set, the rest wait in a queue they can manage, and one schedule view shows review windows, routines and the queue together.

## Who it's for

Someone whose Gannin picks up remote PR review asks and runs them on their Mac. Review windows belong to that person and sync across their Macs; a Mac can override them with its own windows.

## Requirements

1. Recurring review windows (days, start, end, reviews at once), created, edited and deleted by the person.
2. Windows belong to the person and sync across their Macs; a Mac can override them with its own.
3. Auto review requests and automatic Look Again on watched reviews that come up outside a window are queued, not started.
4. Queued reviews start when a window opens, up to the window's reviews-at-once number, in queue order.
5. A review running when its window closes finishes; nothing new starts until the next window.
6. Queued reviews can be run now, removed or reordered from the schedule view.
7. When a queued review's turn comes, it is skipped if the PR is merged, closed, draft or no longer asks for the person.
8. One schedule view shows review windows and routines together: upcoming, running and recent runs, and the review queue.
9. With no review windows, behaviour is unchanged.
10. Docs: Auto review, Routines and the Settings reference.

## Out of scope

- Automatic queue-skipping rules (by label, repo or requester); a queued review is run early only by hand.
- Holding back routines, Work on This or other sessions: windows gate only remote PR reviews.
- Telling the requester their review is queued (PR comment, harness or otherwise); only the reviewer sees the queue.
- Pausing or stopping a running review when its window closes.
- Gating reviews the person starts by hand.

## Acceptance criteria

- **R1** When the person creates, edits or deletes a review window (days, start, end, reviews at once), the system shall save it and use the change for the next review that comes up.
- **R2** When the person sets review windows on one Mac, the system shall apply the same windows on their other Macs, unless that Mac has its own override, in which case the system shall use the override there.
- **R3** When Auto review would start a review of a requested PR outside every review window, the system shall add it to the review queue and not start it.
- **R4** When a watched review would look again outside every review window, the system shall add that Look Again to the review queue and not start it.
- **R5** When a review window opens, the system shall start queued reviews in queue order, never running more at once in that window than its reviews-at-once number.
- **R6** When a review window closes while a review it started is still running, the system shall let it finish and shall start no further queued review until a window is open.
- **R7** When a queued review's turn comes and its PR is merged, closed, a draft, or no longer requests the person's review, the system shall skip it, remove it from the queue and note why.
- **R8** When the person chooses Run Now on a queued review, the system shall start it straight away, whether or not a window is open.
- **R9** When the person removes or reorders queued reviews in the schedule view, the system shall drop them or run them in the new order.
- **R10** When the person opens the schedule view, the system shall show review windows and routines together, with upcoming, running and recent runs, and the review queue.
- **R11** When the person has no review windows, the system shall start automatic reviews and Look Agains as soon as they come up, as it does today.
- **R12** When the person starts a review by hand, the system shall start it straight away regardless of review windows.
- **R13** When this ships, the docs pages agents/auto-review.md, agents/routines.md and the Settings reference shall describe review windows, the review queue, the schedule view and the per-Mac override.

Planned in [plans/2026-10-21-run-remote-pr-reviews-only-in-scheduled.md](../plans/2026-10-21-run-remote-pr-reviews-only-in-scheduled.md).
