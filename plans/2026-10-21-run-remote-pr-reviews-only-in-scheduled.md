---
type: plan
status: in-progress
summary: "Hold remote PR review asks until a scheduled review window, and show review windows, routines and the review queue together in one schedule view."
issues: [andrew-waters/gannin#438, andrew-waters/gannin#445, andrew-waters/gannin#446, andrew-waters/gannin#447, andrew-waters/gannin#448, andrew-waters/gannin#449]
touches: [andrew-waters/gannin]
owner: andrew-waters
agreed_by: [andrew-waters]
agreed_at: 2026-10-21
requirement: requirements/run-remote-pr-reviews-only-in-scheduled.md
---

# Review windows and one schedule view

Hold remote PR review asks until a scheduled review window, and show review windows, routines and the review queue together in one schedule view.

## Requirement

In full in [requirements/run-remote-pr-reviews-only-in-scheduled.md](../requirements/run-remote-pr-reviews-only-in-scheduled.md).

**Problem:** A remote review ask is picked up and run on the reviewer's machine as soon as it arrives. Reviews build and run code, so they slow down whatever else the person is doing, at times they didn't choose. Scheduling is also split: routines are set up in one place, remote review pickup has no schedule, and nothing shows everything Gannin will run on the machine and when. It happens several times a day: asks arrive throughout the day and the review's builds and tests slow the machine during the person's own work.

**Goal:** The person chooses when remote reviews may use their Mac: automatic reviews start only inside review windows they set, the rest wait in a queue they can manage, and one schedule view shows review windows, routines and the queue together.

**Who it's for:** Someone whose Gannin picks up remote PR review asks and runs them on their Mac. Review windows belong to that person and sync across their Macs; a Mac can override them with its own windows.

**Scope:**

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

**Out of scope:**

- Automatic queue-skipping rules (by label, repo or requester); a queued review is run early only by hand.
- Holding back routines, Work on This or other sessions: windows gate only remote PR reviews.
- Telling the requester their review is queued (PR comment, harness or otherwise); only the reviewer sees the queue.
- Pausing or stopping a running review when its window closes.
- Gating reviews the person starts by hand.

**Acceptance criteria:**

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

**Decisions:**

- Which standard does the plan follow? **STANDARDS.md and plans/_template.md don't exist in the repo; the plan follows the shape of recent plans in plans/ (frontmatter, Requirement, Design, Tasks).**
- How often does a remote review land at a bad moment, and what does it cost? **Several times a day; the review's builds and tests slow the machine while the person is working.**
- Whose setting is a review window? **The person's, synced across their Macs, with an optional per-Mac override for a machine that should behave differently. (Revisited: replaces 'the person's, synced' with no override.)**
- What happens to a review still running when its window ends? **It finishes. A window only gates starting a review; nothing new starts until the next window.**
- Inside a window, how many queued reviews run at once? **Set per window: each window has a 'reviews at once' number, default 1.**
- Can some asks skip the queue? **Only by hand, with Run now on a queued review. No automatic rules in this version.**
- Should a window also hold back other heavy work? **No, only remote PR reviews.**
- Does the requester see that their review is queued? **Not in this version: only the reviewer sees the queue, in Gannin. No GitHub write. (Revisited: replaces offering a confirmed 'queued' PR comment.)**
- What is a 'remote review ask' that windows gate? **GitHub review requests that Auto review would start by itself, plus the automatic Look Again a watched review triggers. Reviews the person starts by hand run as today.**
- What can the person do with a queued review from the schedule view? **Run it now, remove it from the queue, and reorder the queue.**
- What happens to a queued review whose PR changes while it waits? **It stays queued; when its turn comes Gannin checks it and skips it if the PR is merged, closed, draft or no longer asks for the person.**
- Which user docs pages change? **agents/auto-review.md, agents/routines.md, and the Settings reference page for where review windows and the per-Mac override are set.**
- Are the requirements right? **Yes, approved as R1-R13.**

## Design

**Review windows are routines.** Add a `reviewQueue` kind to `RoutineKind`, scheduled with the existing `RoutineSchedule.window` case, so days, start, end, crossing midnight, `concurrency` (reviews at once) and `maxMinutes` all come from what issue-queue windows already have. The editor, `nextTimes`, `isOpen` and `openIntervals` are reused unchanged (R1).

**Where windows are kept.** The person's windows go in their home harness file `people/<login>.json` (a `reviewWindows` list), committed through `HarnessStore.commit` after the usual confirmation, so every Mac with that harness reads the same windows (R2). A Mac override is kept locally in `RoutineStore` as `reviewQueue` routines with an "Override on this Mac" switch: when it's on, this Mac's windows win; when it's off, the harness copy is used. The scheduler only ever sees the resolved list.

**Orgs.** Windows are per org, from each org's home harness. Reviews at once is counted across all orgs on this Mac: a window starts a review only while every automatic review running on the Mac, whatever its org, is under that window's number, so overlapping windows never add up.

**The gate.** `EngineerWatch`'s `autoReview` closure (GanninApp) and the Look Again path in `checkWatchedReviews` ask a pure `ReviewGate.decide(now:windows:running:)` (with `running` counted across all orgs): no windows means start now as today (R11); a window open with room means start (R5); otherwise enqueue (R3, R4). Reviews started by hand never pass through it (R12).

**The queue.** A `QueuedReview` list in `RoutineStore` (`reviews.json` beside `queue.json`): PR reference, kind (request or Look Again with its session and reasons), queued at. Enqueue once per PR; a Look Again for a PR already queued merges its reasons.

**Draining.** `RoutineScheduler`'s tick works review windows like queue windows: while a `reviewQueue` window is open and its running reviews are under `concurrency`, take the front item, re-check the PR (merged, closed, draft, request withdrawn) and skip it with a note if it no longer applies (R7), else start it with `startAutomaticReview` or `reviewAgain`, recorded as a `RoutineRun` (R5). Closing a window only stops new starts (R6). The queue is kept on disk; a window Gannin was closed or asleep through is simply missed, and the queue waits for the next one, with no catch-up on launch. Run Now starts an item whatever the time (R8).

**One schedule view.** Extend `ScheduleProjection` and `ScheduleBoard` with review-window lanes and queued-review bars, and show the review queue beside the agent queue with Run Now, Remove and drag to reorder (R9, R10). Routine runs and review runs share the board's upcoming, running and recent rows.

**Why this way.** It follows the issue's 'one scheduler' ask by reusing the routine scheduler, window schedule and board instead of a second system, and keeps the decision logic pure so it can be tested where auto review has no tests today.

**Docs.** `agents/auto-review.md`, `agents/routines.md` and the Settings reference page (R13).

**Areas it touches:**

- `andrew-waters/gannin` `Gannin/Routines/RoutineSchedule.swift#L29-L122`: Routines already have queue windows: RoutineSchedule.window(RoutineWindow) with days, start and end, crossing midnight, and isOpen/openIntervals. Review windows can be the same schedule case rather than a new scheduler.
- `andrew-waters/gannin` `Gannin/Routines/ScheduleBoard.swift`: ScheduleProjection and the board already lay queued issues into queue windows' open hours, one lane per run at once (window.concurrency) with each window's time limit. The one schedule view largely exists for issue queues.
- `andrew-waters/gannin` `Gannin/Sessions/AutoReview.swift#L9-L185`: Remote review asks are GitHub review requests picked up by Auto review (autoReviewRequests per org) and started at once by startAutomaticReview, capped at AutoReview.maxRunning (2). This is the gate a review window must sit in front of.
- `andrew-waters/gannin` `Gannin/Routines/RoutineStore.swift#L37-L120`: RoutineKind has report, code, issueQueue and pinned; a Routine carries schedule, concurrency and maxMinutes. The agent queue (QueuedIssue) is per org with enqueue, insert, dequeue and reorder. A reviewQueue kind and a queued-review list can follow the same shape.
- `andrew-waters/gannin` `Gannin/App/GanninApp.swift#L138-L148`: EngineerWatch's autoReview closure decides whether to start an automatic review (org on, harness found, config skips) and calls startAutomaticReview; checkWatched drives Look Again. The window gate goes here: outside a window, enqueue instead of start.

**Patterns to follow:**

- `andrew-waters/gannin` `Gannin/Routines/RoutineScheduler.swift`: One 15-second tick (and on wake) plans routine times and drains queue windows; starts run in their own task, failures back off. Review windows should be drained by this same loop, not a second timer.
- `andrew-waters/gannin` `Gannin/Sessions/AutoReview.swift#L170-L183`: startAutomaticReview returns false to mean 'try later' and caps runs at AutoReview.maxRunning. Inside a window, the window's reviews-at-once replaces that cap.
- `andrew-waters/gannin` `.claude/rules/harness.md#L16`: The home harness already holds per-person team files (people/<login>.json), committed through HarnessStore.commit with the user's confirmation. That is how a person's review windows can reach all their Macs.

**Risks:**

- `andrew-waters/gannin` `.claude/rules/routines.md`: Routines and their queue are user-local, per Mac (Application Support Routines/*.json). Review windows synced across the person's Macs, with a per-Mac override, don't fit that storage as is.
- `andrew-waters/gannin` `Gannin/Sync/UserDatabase.swift#L11-L15`: Nothing syncs across a person's Macs today: the user database's CloudKit sync was removed. Synced windows depend on the harness (a confirmed commit per change) or on bringing iCloud back.
- `andrew-waters/gannin` `.claude/rules/sessions-review.md`: Nothing tests auto review or watched reviews. The gate and queue logic should be pure functions with their own tests, as RoutineSchedulerTests and ScheduleBoardTests do for routines.

**Decisions:**

- Where do a person's synced review windows live? **In their home harness file people/<login>.json, committed after confirmation like other team data. Teammates can see them; each edit is a commit.**
- How do review windows apply for someone in more than one org? **Per org: each org's people file has its own windows, and an org with none starts reviews at once. Reviews at once is counted across every org on this Mac, so a window starts a review only while all automatic reviews running on the Mac are under its number.**
- What happens to the queue if Gannin is closed or the Mac asleep for a whole window? **The queue is kept on disk and waits for the next window Gannin is open in; no catch-up on launch.**
- Is the design right? **Yes, approved.**

## Tasks

1. [andrew-waters/gannin#445](https://github.com/andrew-waters/gannin/issues/445) Review windows: model, synced storage and editor (satisfies R1, R2)
2. [andrew-waters/gannin#446](https://github.com/andrew-waters/gannin/issues/446) Queue automatic reviews and Look Agains outside a window (satisfies R3, R4, R11, R12)
3. [andrew-waters/gannin#447](https://github.com/andrew-waters/gannin/issues/447) Drain the review queue in its windows (satisfies R5, R6, R7, R8)
4. [andrew-waters/gannin#448](https://github.com/andrew-waters/gannin/issues/448) Show review windows and the review queue in the schedule view (satisfies R9, R10)
5. [andrew-waters/gannin#449](https://github.com/andrew-waters/gannin/issues/449) Docs, changelog and rules for review windows (satisfies R13)

**Decisions:**

- Are the tasks right? **Yes, five tasks approved, covering R1-R13.**

## From the room

- We want to revisit "Whose setting is a review window?". We said "The person's, synced so the same windows apply on each of their Macs.". Ask it again as a question, with that answer marked as what we said before, and update everything that depended on it once we've answered. (requirements)
- We want to revisit "Does the requester see that their review is queued?". We said "Yes: when an ask is queued, Gannin offers to post a PR comment saying it's queued and roughly when it will run, posted only once the reviewer confirms.". Ask it again as a question, with that answer marked as what we said before, and update everything that depended on it once we've answered. (requirements)
