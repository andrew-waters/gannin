---
paths:
  - "Gannin/Routines/**"
---
# Routines

Scheduled Claude Code sessions, run only while Gannin is open and awake. All user-local (`RoutineStore`, Application Support/<bundle ID>/Routines: `routines.json`, `queue.json`, `reviews.json`, `runs.json`, `state.json`), except review windows synced through the person's file.

## Harness and storage
- Never write to a harness except an issue run's session record (scheduling is the consent) and what the user commits. Skip the record when Record queued sessions is off for that harness (`SessionStore.recordsQueuedSessions`): the brief then travels with the start script, as for any unrecorded session.
- Never drop a run that is going when trimming `runs.json` (`RoutineStore.maxRuns`). Deleting a routine must keep its going runs so their limits stay watched.
- At launch, fail every run still marked going: terminals don't outlive Gannin.

## Scheduler
- Compute every next time through `RoutineSchedule.nextTimes(after:count:)`; the scheduler, editor and list must agree.
- Never run two looks at once, and never await a start inside a look (a start can take minutes): record the run as going, start it in its own task, so limits keep being watched.
- Per routine, `plan` takes times since `RoutineStore.checkedAt`: the latest within `grace` (two minutes) runs; older ones become one Missed row; while paused, one Skipped row.
- Times before a routine was made or its schedule last changed must not count.
- A failed queue start returns the issue to the queue front and holds the window off with doubling backoff; after `maxFailures` it stays held until the window reopens or Run Now. Skip this when the issue itself was the problem (`RoutineStart.failed(_:retry:)`).

## Runs
- Never let a run past auto mode failing do anything: end the session and fail the run with the reason (`startUnattended`).
- Enforce the limit with `--disallowedTools` (`RoutineRunInfo.disallowedTools`): Local only blocks `git push`, `gh pr create`, `gh pr ready`; Draft PR blocks `gh pr ready`; a report also blocks `git commit`; always block `gh pr merge`. The brief must tell claude nobody is watching.
- An issue that already has a session carries on in it (`resumeIssueRun`), never a second session: leave it while it's mid-turn or asking and try later. Mark the run `resumed` so replies from before don't count, and hand the session back (`handBack`, `routineRun` cleared) when the run finishes, stops at its limit or is lost.
- Over its time or cost limit, interrupt, end claude and helpers, and keep the worktree and files (`stopAtLimit`). Cost is the session's plus its helpers' transcripts.

## Review windows
- Read review windows only through `ReviewWindowBook` (`windows`, or the app's `reviewWindows` closure): synced ones live in `people/<login>.json` (`PersonDates.reviewWindows`) and aren't in `RoutineStore`, so `routines.routine(id)` misses them. This Mac's override is `reviewQueue` routines plus `state.json`'s `reviewOverrides`; keep both lists out of the other kinds' sections.
- Decide every automatic start through `ReviewGate.decide`, with `running` counted across all orgs (`automaticReviewsRunning` plus `reviewsStarting`): the issue asks that overlapping windows and orgs never add up.
- Never stop a running review when its window closes, and never catch a missed window up on launch: only starts are gated.
- Re-check a queued review just before starting it (`startQueuedReview`); its PR may have changed in the hours it waited. Return `.skipped` for one no longer wanted, so it isn't put back, and `.notYet` for one that can't start through no fault of the window (a busy review, a start in flight), so it goes back with no hold and no run row. Drain passes over a review that's busy or still being started (`reviewReady`) rather than stopping at it or trying it every tick.
- Pause All holds the review queue even with no windows; only new requests with no windows start ungated (R11).
- A review run has no limits of its own; `watchRoutineRuns` hands it to `watchReviewRun`, which ends it when the review leaves `automaticRuns`. Don't let it reach `RoutineVerdict`, which would fail it for having no `routineRun`.

## Queue and board
- `ScheduleProjection` gives every run its window's whole limit, so projected times are the latest, not the likeliest.
- Review lanes take no dropped issues (`ScheduleProjection.reviewWindows`).
- `ScheduledForAgentPill` and `QueuedReviewMenu` take their stores as parameters: a table's cells are rebuilt without the page's environment objects, so reading it from the environment crashes Issues › All.

## Testing
- `RoutineScheduleTests` (includes `CronExpression`), `RoutineSchedulerTests`, `RoutineRunsTests`, `RoutineStoreTests`, `ScheduleBoardTests`, `ReviewWindowsTests`, `ReviewGateTests`.
- Starting a real run needs claude (and a sandbox for sandboxed runs); the tests cover planning and verdicts only.
