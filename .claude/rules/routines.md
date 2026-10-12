---
paths:
  - "Gannin/Routines/**"
---
# Routines

Scheduled Claude Code sessions, run only while Gannin is open and awake. All user-local (`RoutineStore`, Application Support/<bundle ID>/Routines: `routines.json`, `queue.json`, `runs.json`, `state.json`).

## Harness and storage
- Never write to a harness except an issue run's session record (scheduling is the consent) and what the user commits.
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

## Queue and board
- `ScheduleProjection` gives every run its window's whole limit, so projected times are the latest, not the likeliest.
- `ScheduledForAgentPill` takes `RoutineStore` as a parameter: a table's cells are rebuilt without the page's environment objects, so reading it from the environment crashes Issues › All.

## Testing
- `RoutineScheduleTests` (includes `CronExpression`), `RoutineSchedulerTests`, `RoutineRunsTests`, `RoutineStoreTests`, `ScheduleBoardTests`.
- Starting a real run needs claude (and a sandbox for sandboxed runs); the tests cover planning and verdicts only.
