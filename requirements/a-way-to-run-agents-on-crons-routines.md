---
type: requirement
status: in-progress
summary: "One scheduler in Gannin that starts agent sessions by themselves while it's running: recurring routines (reports, maintenance) on a timer, interval or cron, and issues allocated to agents through a queue drained in time windows or pinned to a time, each within limits the user sets."
issues: [andrew-waters/gannin#87]
plans: [plans/2026-10-09-a-way-to-run-agents-on-crons-routines.md]
---

# Agent routines

## Problem

Every agent session in Gannin starts because someone clicks something (Work on This, Review with Claude, New Ask); only auto review starts by itself. Reports, issues that could be worked while you're in meetings or asleep, and routine maintenance all wait for a person to start them, at a time that suits the person rather than the work, and each start costs a context switch.

## Goal

One scheduler in Gannin that starts agent sessions by themselves while it's running: recurring routines (reports, maintenance) on a timer, interval or cron, and issues allocated to agents through a queue drained in time windows or pinned to a time, each within limits the user sets.

## Who it's for

An engineer or lead using Gannin on their own Mac who wants agents doing work and reports while they're busy or away

## Requirements

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

## Out of scope

- Running routines while Gannin is closed or the Mac is asleep (no launchd, server cron or cloud runner)
- Committing or posting a report's output automatically
- Sharing routines or the queue with the team through the harness, or coordinating runs between Macs
- Routines that start other kinds of session than report, code and issue runs (reviews already have auto review)

## Acceptance criteria

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

Planned in [plans/2026-10-09-a-way-to-run-agents-on-crons-routines.md](../plans/2026-10-09-a-way-to-run-agents-on-crons-routines.md).
