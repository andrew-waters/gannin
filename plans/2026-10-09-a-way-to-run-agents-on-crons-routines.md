---
type: plan
status: in-progress
summary: "Run Claude Code agents on a schedule: issues allocated to agents at set times, recurring sessions on a timer or interval (reports and the like), and recurring maintenance, all through one scheduler."
issues: [andrew-waters/gannin#87, andrew-waters/gannin#88, andrew-waters/gannin#89, andrew-waters/gannin#90, andrew-waters/gannin#91, andrew-waters/gannin#92, andrew-waters/gannin#93, andrew-waters/gannin#94, andrew-waters/gannin#95, andrew-waters/gannin#96, andrew-waters/gannin#97]
touches: [andrew-waters/gannin]
owner: andrew-waters
agreed_by: [andrew-waters]
agreed_at: 2026-10-09
requirement: requirements/a-way-to-run-agents-on-crons-routines.md
---

# Agent routines

Run Claude Code agents on a schedule: issues allocated to agents at set times, recurring sessions on a timer or interval (reports and the like), and recurring maintenance, all through one scheduler.

## Requirement

In full in [requirements/a-way-to-run-agents-on-crons-routines.md](../requirements/a-way-to-run-agents-on-crons-routines.md).

**Problem:** Every agent session in Gannin starts because someone clicks something (Work on This, Review with Claude, New Ask); only auto review starts by itself. Reports, issues that could be worked while you're in meetings or asleep, and routine maintenance all wait for a person to start them, at a time that suits the person rather than the work, and each start costs a context switch.

**Goal:** One scheduler in Gannin that starts agent sessions by themselves while it's running: recurring routines (reports, maintenance) on a timer, interval or cron, and issues allocated to agents through a queue drained in time windows or pinned to a time, each within limits the user sets.

**Who it's for:** An engineer or lead using Gannin on their own Mac who wants agents doing work and reports while they're busy or away

**Scope:**

1. Recurring sessions that produce reports, with no code changes
2. Issues allocated to agents to work at designated times
3. Recurring maintenance sessions that touch code
4. Routines fire while Gannin is running; times missed while it was closed or the Mac was asleep are recorded as missed and skipped
5. A report run's files stay with the run in Gannin, as an Ask's do, with Commit to Harness as a choice
6. Scheduled code runs work unattended (auto mode); each routine says how far they may go: commit locally, push and open a draft PR, or open a PR ready for review
7. Issues are allocated two ways: an ordered agent queue that routines drain in time windows with a limit on how many run at once, and an issue pinned to a specific time
8. Routines and the agent queue are the user's own, kept on this Mac
9. Each routine has a maximum run time and a maximum cost per run; at either Gannin interrupts the run, keeps what's done and flags it
10. Schedules are set with pickers (every N minutes or hours, daily, weekdays, weekly) or a cron expression as an advanced option
11. Each routine and queued issue keeps a history of its runs, and a switch pauses everything

**Out of scope:**

- Running routines while Gannin is closed or the Mac is asleep (no launchd, server cron or cloud runner)
- Committing or posting a report's output automatically
- Sharing routines or the queue with the team through the harness, or coordinating runs between Macs
- Routines that start other kinds of session than report, code and issue runs (reviews already have auto review)

**Acceptance criteria:**

- **R1** When a routine's next scheduled time arrives while Gannin is running, the system shall start its session in the background (a tab added, not selected) in the routine's project harness, with the routine's prompt.
- **R2** When a routine's or pinned issue's time passed while Gannin was closed or the Mac was asleep, the system shall record that time as missed, not run it, and wait for the next scheduled time.
- **R3** When the user sets a routine's schedule, the system shall offer every N minutes or hours, daily at a time, weekdays at a time, weekly on a day and time, or a cron expression, and shall show the next five run times; an invalid cron expression shall be refused with the reason.
- **R4** When a report routine runs, the system shall run it with no code worktree, keep the files it writes with the run (as an Ask's Files are), notify when it finishes, and commit nothing unless the user chooses Commit to Harness.
- **R5** When a code routine runs (maintenance), the system shall give it worktrees of the repos the routine names, laid out as Work on This lays them out, on a new branch per run.
- **R6** When the user adds issues to the agent queue, the system shall keep them in order, and let the user reorder and remove them.
- **R7** When a queue window is open and fewer queued runs are running than its concurrency limit, the system shall start a Work on This session on the next issue in the queue and take it off the queue.
- **R8** When an issue is pinned to a time and that time arrives while Gannin is running, the system shall start its Work on This session.
- **R9** When a scheduled code or issue run's limit is Local only, the system shall tell the session and disallow pushing and opening PRs; with Draft PR it may push and open a draft PR; with Ready PR it may open a PR ready for review.
- **R10** When the user creates a routine, queue window or pinned issue, its limit shall start as Local only.
- **R11** When a scheduled run passes its routine's maximum run time or maximum cost (from the transcript's cost records), the system shall interrupt claude, keep its worktree and files, mark the run Stopped at limit and notify.
- **R12** When a scheduled run asks a question or a permission prompt, the system shall flag it as Needs you as other sessions are, and its time and cost shall keep counting toward its limits.
- **R13** When the user opens a routine, the system shall list its runs: scheduled time, start, outcome (finished, stopped at limit, missed, failed, needs you), duration, cost and PRs, each opening its session.
- **R14** When the user pauses all routines, the system shall start no scheduled run until resumed, recording the times passed as skipped while paused.
- **R15** The system shall keep routines, the queue, pinned issues and run history on this Mac only; the only harness writes are session records (R16) and commits the user chooses.
- **R16** When a scheduled issue run starts (from the queue or a pin), the system shall commit its session record to the harness as Work on This does, without asking: scheduling the issue is the consent.

**Decisions:**

- Which job should scheduled agents do first? **All equally: reports, issues worked at set times, and recurring maintenance share one scheduler from the start.**
- Where do routines run? **In Gannin, while it's running. Missed runs are handled on next launch.**
- What happens to a run missed while Gannin was closed or the Mac asleep? **Skip it, record it as missed, and wait for the next scheduled time.**
- Where does a report routine's output go? **Kept with the run in Gannin, as an Ask's files are, with a notification; committing to the harness is a choice made by hand.**
- How far may a scheduled code run go unattended? **A choice made when creating the routine: local commits only, a draft PR, or a PR ready for review. (Revised from the room: first answered 'ready PR' for all.)**
- Which limit does a new routine start on? **Local only: commits in its worktree, never pushes, until someone chooses otherwise.**
- How are issues allocated to agents? **Both: an ordered queue drained in time windows (with a concurrency limit), and pinning an issue to a time.**
- Whose are routines and the agent queue? **The user's own, kept on this Mac, like auto review's settings. (Revisited at the room's request and confirmed.)**
- What stops a scheduled run that's stuck or running away? **A time limit and a cost limit per routine; reaching either interrupts the run and flags it.**
- How is a schedule set? **Pickers (every N minutes or hours, daily, weekdays, weekly), with a cron expression as the advanced option and the next run times shown.**
- Does a scheduled issue run commit its session record to the harness, given it can't ask? **Always: scheduling the issue counts as consent to record it.**
- Are the requirements right? **Yes, approved as R1-R16.**

## Design

**Shape.** A new `Gannin/Routines/` folder with a `RoutineStore` (on this Mac, Application Support/<bundle>/Routines: `routines.json`, `queue.json`, `runs.json`, newest 500 runs) and a `RoutineScheduler` loop started from `GanninApp` beside `EngineerWatch`, ticking every 30 seconds.

**Model.**
- `Routine`: name, org, project harness, kind (`report`, `code`, `issueQueue`), prompt (or a team prompt by name), repos (code), schedule, limit (`localOnly` default, `draftPR`, `readyPR`), max run time, max cost, concurrency (queue windows), enabled.
- `RoutineSchedule`: `every(minutes)`, `daily(time)`, `workingDays(time)` (the org's `WorkWeek` days less its bank holidays from `BankHolidayStore`; your own time off ignored), `weekly(day, time)`, `cron(String)`. One `nextTimes(after:count:)` for all; a small five-field cron parser of our own (no new dependency), unit tested. The editor shows the next five times (R3).
- An issue queue routine's schedule is a window (start and end times, days) rather than instants; the queue itself is one ordered list of issue references per org. A pinned issue is a one-off `Routine` of kind issue with `at(Date)`.
- `RoutineRun`: routine, scheduled time, started, ended, outcome (`finished`, `stoppedAtLimit`, `missed`, `skippedPaused`, `failed`, `needsYou`), session ID, cost, PRs.

**Firing.** Each tick works out the times due since the last tick. A time fires only if it's within a grace of two minutes; older ones (Gannin was closed, or the Mac slept, seen as a gap between ticks or `NSWorkspace.didWakeNotification`) are recorded `missed` (R2); while paused, `skippedPaused` (R14). Queue windows start the next issue whenever a slot is free inside the window (R7).

**Starting.** As `startAutomaticReview` does: make the session without revealing it, add its tab unselected, `open` it, then `switchMode(.auto)` once claude's prompt shows (R1). If it can't reach auto mode, claude is ended before its first prompt is sent, the run is `failed` with "auto mode unavailable", a notification says so, and the routine editor warns while the box is in `autoUnavailableBoxes`.
- Report: an Ask-shaped session (`CodeSession.routine`, an `AskInfo`-like folder with `files/` and `context/`), so the Files pane and Commit to Harness are reused, nothing committed (R4); a notification on finishing.
- Code: a harness session with a branch `routine-<slug>-<date>` and a brief naming its repos, worktrees laid out as Work on This's (R5).
- Issue (queue or pin): `SessionStore.start(issue)` with the normal brief, then `record` without asking (R8, R16).
- Limits (R9): `SessionScript.options` adds `--disallowedTools` for `git push`, `gh pr create`, `gh pr ready` as the limit needs, and the brief says what's allowed (`--draft` for Draft PR).

**Watching.** Each poll checks running scheduled sessions: past max time or `transcript.costUSD` past max cost, interrupt (Esc), end claude, keep the worktree, mark `stoppedAtLimit`, notify (R11). A Needs you state marks the run `needsYou` and flags it as today; the clock runs on (R12). Exit marks `finished`.

**UI.** Agents › Routines in the sidebar: a list of routines (next run, last outcome, enabled), Pause All in the toolbar (R14), New Routine, and each routine's page with its run history (R13). Agents › Queue: the issue queue, reorder and remove (R6). Issues get Schedule for Agent… (Add to Queue, or Pin to a Time) beside Work on This in the context menu and issue toolbar.

**Why this way.** It reuses the session machinery end to end (tabs, terminals, briefs, Files, pair review, PR watching), so a scheduled run is an ordinary session that started by itself and can be opened, taken over or finished like any other. Nothing new talks to GitHub except the session record.

**Areas it touches:**

- `andrew-waters/gannin` `Gannin/Sessions/AskSession.swift#L50-L76`: startAsk makes a session not tied to an issue (synthetic IssueReference, AskInfo, files/ folder, brief). Report routines are an Ask-shaped session with the routine's prompt, so the Files pane and Commit to Harness come for free (R4).
- `andrew-waters/gannin` `Gannin/Sessions/SessionStore.swift#L581-L631`: start(issue:) builds an issue session and its brief; record(_:startedBy:) commits brief.md and session.json. Queue and pinned runs call both, record without asking (R16).
- `andrew-waters/gannin` `Gannin/Sessions/SessionMode.swift#L163-L215`: Unattended is reached by Shift+Tab cycling after claude starts (switchMode(.auto)); a box without auto mode is marked autoUnavailable. A scheduled run must switch after launch and fail clearly when it can't.
- `andrew-waters/gannin` `Gannin/Sessions/SessionTranscript.swift#L146`: costUSD is summed from cost-state records as the transcript grows: the cost limit (R11) reads it on each poll.

**Patterns to follow:**

- `andrew-waters/gannin` `Gannin/Sessions/AutoReview.swift#L146-L163`: startAutomaticReview is the one session Gannin starts by itself today: startReview(reveals: false), then open(session) launches claude with no tab, capped by maxRunning, tracked in automaticRuns. Scheduled runs should start the same way.
- `andrew-waters/gannin` `Gannin/Sessions/EngineerWatch.swift#L106-L128`: A 30-second Task loop with isDue checks and holdsOff, started from GanninApp. The scheduler can be its own loop of the same shape (no GitHub budget needed to fire, but issue runs fetch briefs).
- `andrew-waters/gannin` `Gannin/Sessions/SessionScript.swift#L24-L30`: options() adds --model and, for reviewers, --disallowedTools. Push limits (R9) add Bash(git push:*), Bash(gh pr create:*) and Bash(gh pr ready:*) the same way, plus a line in the brief.
- `andrew-waters/gannin` `Gannin/Sessions/SessionActions.swift#L61-L63`: interrupt sends Esc. Stopping at a limit is interrupt, then ending claude, leaving the worktree as Finish doesn't.
- `andrew-waters/gannin` `Gannin/Sessions/AutoReview.swift#L78-L140`: ReviewActivity: a capped JSON log in Application Support/<bundle>/Sessions, loaded at init, written atomically. Routine run history follows it (R13, R15).
- `andrew-waters/gannin` `Gannin/WorkLog/BankHolidays.swift`: WorkWeek and BankHolidayStore give the org's working days and bank holidays; the scheduler's working-days schedule and queue windows read them.

**Risks:**

- `andrew-waters/gannin` `Gannin/Sessions/SessionMode.swift`: If auto mode isn't available on the Mac (account or Claude Code version), an unattended run stops at its first permission prompt. The run must record Needs you and the routine editor should warn.
- `andrew-waters/gannin` `Gannin/Sessions/SessionScript.swift`: --disallowedTools patterns stop the obvious commands, not every way to push (a script could). Local only is a guard, not a sandbox; the sandboxed sessions plan (andrew-waters/gannin#8) is the stronger fence later.
- `andrew-waters/gannin` `Gannin/Sessions/QuitGuard.swift`: Quitting asks first when sessions run; scheduled runs count as running, and the guard should name them as scheduled.

**Decisions:**

- What does a scheduled run do when Gannin can't switch it into auto mode? **Stop before doing anything, record it failed (auto mode unavailable), notify, and warn in the routine editor.**
- Do working-day schedules and queue windows follow the org's calendar? **Yes: the org's working week less its bank holidays. Your own time off doesn't stop them.**
- Is the design right? **Yes, approved.**

## Tasks

1. [andrew-waters/gannin#88](https://github.com/andrew-waters/gannin/issues/88) Routine schedules: pickers, cron and next times (satisfies R3)
2. [andrew-waters/gannin#89](https://github.com/andrew-waters/gannin/issues/89) RoutineStore: routines, queue and run history on this Mac (satisfies R6, R10, R15)
3. [andrew-waters/gannin#90](https://github.com/andrew-waters/gannin/issues/90) RoutineScheduler: fire due times, record missed and paused (satisfies R1, R2, R14)
4. [andrew-waters/gannin#91](https://github.com/andrew-waters/gannin/issues/91) Start scheduled runs unattended, with push limits (satisfies R1, R9)
5. [andrew-waters/gannin#92](https://github.com/andrew-waters/gannin/issues/92) Report and code routines (satisfies R4, R5)
6. [andrew-waters/gannin#93](https://github.com/andrew-waters/gannin/issues/93) Watch scheduled runs: limits, Needs you and outcomes (satisfies R11, R12)
7. [andrew-waters/gannin#94](https://github.com/andrew-waters/gannin/issues/94) Issue runs: queue windows and pinned issues (satisfies R7, R8, R16)
8. [andrew-waters/gannin#95](https://github.com/andrew-waters/gannin/issues/95) Agents › Routines: list, editor, Pause All and run history (satisfies R3, R10, R13, R14)
9. [andrew-waters/gannin#96](https://github.com/andrew-waters/gannin/issues/96) Agents › Queue and Schedule for Agent on issues (satisfies R6, R8)
10. [andrew-waters/gannin#97](https://github.com/andrew-waters/gannin/issues/97) Document routines in CLAUDE.md

**Decisions:**

- Are the tasks right? **Yes, approved as ten tasks.**

## From the room

- I said ready PR previously, but should this not be a choice the user has creating a routine? (requirements)
- We want to revisit "Whose are routines and the agent queue?". We said "The user's own, kept on this Mac, like auto review's settings.". Ask it again as a question, with that answer marked as what we said before, and update everything that depended on it once we've answered. (requirements)
