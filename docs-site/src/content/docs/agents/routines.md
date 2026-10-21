---
title: Routines
description: Start Claude Code sessions on a schedule, drain a queue of issues, or hold automatic reviews to review windows, while Gannin is open.
sidebar:
  order: 14
---

A routine starts a Claude Code session by itself. Routines only run while Gannin is open and your Mac is awake. If it's closed or asleep, nothing starts. Routines are yours alone, kept on this Mac.

They're under Agents › Routines.

## Kinds

- **Report**: an [Ask](/docs/agents/ask/) session that answers the routine's question. Its files are in the Files pane, ready to commit to the harness. The tab says Report.
- **Maintenance**: work with no issue, on a new branch each run, on the repos you name. The tab says Maintenance.
- **Queue window**: while it's open, starts the next issue in the [queue](#the-queue), up to a number at once.
- **Pinned issue**: starts one issue at a set time, then turns itself off.
- **Review window**: while it's open, automatic PR reviews may start, up to its Reviews at once; outside every window they wait in the [review queue](#the-review-queue). See [Review windows](/docs/agents/auto-review/#review-windows).

Issues from a queue window or pin run as [Work on This](/docs/agents/work-on-this/) would. Their session record is committed to the harness without asking, since scheduling the routine is the consent. To stop that, switch off Record queued sessions for the project in Settings › Harness: the run then starts without committing its brief or `session.json`.

## Making one

New Routine in the toolbar opens the editor: Name, Kind, Project, the prompt, the team's prompts (none ticked takes the defaults), Repos for maintenance, When, how far it goes, and Limits.

**When** is one of:

- Every, a number of minutes or hours. Hourly is on the hour.
- Daily, at a time.
- Working days, at a time: your org's working week, less bank holidays.
- Weekly, on a day.
- Cron expression, five fields (minute, hour, day, month, weekday) with lists, ranges, steps, names and `@daily` and the like. A bad one is refused with the reason.
- Once, for a pin.
- A window, for a queue: opens and closes, which may cross midnight, on working days or days you pick.

The editor shows the next five times, or what's wrong.

**How far it goes** is Local only, Draft PR or Ready PR. Local only is the default for new routines: Claude commits and stops, with no push and no PR. Draft PR may open a draft. Ready PR may mark it ready. No routine ever merges. This is a guard that takes away commands, not a sandbox. For one, see [Sandboxes](/docs/sessions/sandboxes/).

**Limits** are minutes (Stop after) and cost (Stop after spending). At either, Claude is interrupted, its worktree and files are kept, and the run shows Stopped at limit with a notification.

## What runs need

Runs work in auto mode (see [Attended and Unattended](/docs/agents/attended-and-unattended/)) since nobody is watching. If Claude can't reach auto mode, the run fails with the reason and a notification, and the editor warns you. A question or permission prompt shows Needs you and the clock keeps running. A finished turn shows Finished (Report ready for a report). Notifications follow Settings › General › Agent and open the session.

## Missed and skipped

When a routine's time passes while Gannin was closed or asleep, the latest time within two minutes still runs. Older ones are one Missed row, giving the first, last and how many. While Pause All is on, a Skipped row is recorded instead.

A queue window that fails to start an issue puts it back at the front and waits five minutes, doubling each time. After four failures in a row it stops until it next opens or you use Run Now. A review window does the same with a review it couldn't start.

## The list

Each row shows its schedule, limit, next run (or Open now), last outcome and an on switch. Pause All in the toolbar stops every routine, with a banner while it's on. A row's menu has Run Now, Edit, Turn Off and Delete. A routine's page shows its settings, next times and its runs: when scheduled, started, outcome, how long, cost, PRs and Open Session. The newest 500 runs are kept.

Review windows have a section of their own, with Override on This Mac. A review window's row shows its days and hours, Reviews at once, Open now or when it next opens, and its last outcome, with no on switch. Click it or use Edit to change it, or Delete to remove it. Reviews it started show on Agents › Queue. Deleting a window leaves its reviews in the queue: with no windows left they start as automatic reviews always have, unless Pause All is on.

## The queue

Agents › Queue is the org's queue of issues in order. Drag to reorder, or use Move to Top, Move to Bottom or Remove. It also shows which windows drain it, when they next open, and the issues pinned to a time.

Schedule for Agent, beside Work on This in an issue's drawer and window and in Issues › All's menu, adds an issue to the queue or takes it off. Pin to a Time opens the editor for a pinned issue. Issues show Queued for Agent (with their place) or Pinned for Agent (with their time).

## The review queue

Agents › Queue also holds the reviews waiting for a [review window](/docs/agents/auto-review/#review-windows), each org's in order, under the windows' line saying how many wait and when the next window opens.

- **Board** puts each review window's lanes (one per review at once) beside the queue windows, with the reviews running and the queued ones laid into the windows' open hours. Each review is drawn half an hour long, and reviews from your other orgs share the windows' places, so a time is a guide.
- **List** has Reviews waiting for a review window, in order: drag to reorder, or right-click for Run Now, Move to Top, Move to Bottom and Remove from Queue. Run Now starts it straight away, whether or not a window is open. Below it, Reviews review windows started lists the latest runs with their outcome: Running, Finished, Failed, or Skipped with why.
