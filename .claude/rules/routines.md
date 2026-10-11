---
paths:
  - "Gannin/Routines/**"
---
# Routines

Scheduled Claude Code sessions, started while Gannin runs (never while closed or asleep). All user-local: `RoutineStore` in Application Support/<bundle ID>/Routines (`routines.json`, `queue.json`, `runs.json`, `state.json`). The only harness writes are an issue run's session record and what the user commits.

## Schedule and scheduler
- `RoutineSchedule.nextTimes(after:count:)` serves the scheduler, the editor's next five and the list; keep them on it.
- Every-N-minutes schedules anchor at midnight on the day set (hourly lands on the hour). Working days = the org's `WorkWeek` less bank holidays. `CronExpression` is our own five-field parser (cron's either-day rule, Sunday 0 or 7, `@daily`), refusing bad input with a reason.
- `RoutineScheduler` ticks every 15 s and at once on `didWakeNotification`; never two looks at once. Each look watches running runs, then takes each routine's times since `RoutineStore.checkedAt` (so a relaunch learns what passed) through `plan`.
- `plan`: the latest time within `grace` (120 s) runs; older ones collapse to one Missed row (`recordGap`: first, last, count); while paused, one Skipped row. Times before the routine was made or its schedule last changed don't count. A pin is turned off once its time passes.
- Queue windows have no times: while `isOpen`, start the next queued issue until `concurrency` runs are going (`freeSlots`), dequeuing as each starts.
- A look never awaits a start (can take minutes): the run is recorded as going and started in its own task (`starting`), so limits keep being watched.
- Failed queued start: issue returns to the queue front; the window holds off (`heldUntil`) 5 min, doubling per consecutive failure (`failures`); after four it stops until the window next opens or Run Now. `RoutineStart.failed(_:retry:)` skips this when the issue itself was the problem. `queueNote` shows it on the row.
- At launch, runs still marked going are failed (terminals don't outlive Gannin). Deleting a routine keeps its going runs so limits are still watched. `RoutineStore.maxRuns` (500) never drops a going run.

## Starting a run
- `SessionStore.startRoutine` (`RoutineRuns.swift`): session carries `CodeSession.routineRun` (`RoutineRunInfo`). Tab is added, not shown; claude starts with no prompt (`SessionScript.claudeSteps` omits it).
- `startUnattended` waits for `SessionStart` idle (`unattendedStartTimeout`, 15 min, for a sandbox's first image build), calls `switchMode` to auto (twice), then pastes `SessionScript.openingPrompt`. If auto mode is unreachable the session is ended before doing anything and the run fails with a notification; the editor warns while the box is in `autoUnavailableBoxes`.
- Limits are enforced by `--disallowedTools` (`RoutineRunInfo.disallowedTools`): Local only blocks `git push`, `gh pr create`, `gh pr ready`; Draft PR blocks `gh pr ready`; never `gh pr merge`; a report also blocks `git commit`. The brief's Scheduled run section (`briefSection`) and PR/plan lines tell claude nobody is watching and how far it may go.
- Report (`startReportRun`): an Ask session on this Mac. Maintenance (`startMaintenanceRun`): no issue (`hasNoIssue`, `isMaintenance`), new branch per run (`routineBranchName`: `routine-<name>-<date>-<4 hex>`), task and repos in `maintenanceSections`; sandbox clones its repos via `SandboxLaunch.cloneRepos`.
- Issue run (`startIssueRun`, queue window or pin): the issue's Work on This session in the harness covering its repos (the queue is org-wide; the routine's project only when none covers), record committed without asking (scheduling is the consent), first prompt `scheduledIssuePrompt`. An issue that already has a session fails the run.

## Watching
- `watchRoutineRuns` each tick, `RoutineVerdict.judge`: cost is the session's plus helpers' transcript `costUSD`. Over minutes or cost: interrupt (Esc), end helpers and claude, keep worktree and files, `stopAtLimit` with notification.
- A question or permission prompt is Needs you (clock keeps running). A turn ending after being seen working, and not during pair review, is Finished. `notifyRoutine` follows Settings > General > Agent.
