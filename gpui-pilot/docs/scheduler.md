# Scheduler: requirements

One screen to plan what Claude does unattended, in place of the Swift app's routines, queue, review
windows and overrides, each on screens of their own.

## What it schedules

1. **Review times.** Windows (say weekdays 9:00 to 11:00) when automatic reviews may start: reviews of
   pull requests where I'm a requested reviewer. They post by themselves. Each window says whether its
   reviews approve by themselves, and under which conditions: authors (picked from the org's members,
   and whether bots count), lines and files changed (from GitHub when the review posts), Claude's effort
   (1 to 5), no finding at or above a severity, and Claude's risk (low, medium, high: what the change
   could break if it's wrong). An unset condition doesn't restrict; one that can't be answered (no
   effort or risk given, size unknown) fails. An approve verdict that fails any condition posts as a
   comment and waits for me, and the review and the window's last runs say why. Your own pull
   requests only ever get a comment, and requesting changes posts as it is.
2. **Issue starts.** An issue pinned to an exact time: Work on This starts then, unattended.
3. **Sequences.** "This, then this, then this": a list of issues worked one after another, each to
   completion before the next starts.
4. **Recurring prompts.** A saved prompt on a cron-like schedule ("Monday 8:30", "Friday 16:00",
   "weekdays at 9"), for reports and chores.

## Rules

- **Runs only while the app is open.** Times missed while it was closed don't catch up on launch; they show
  as missed.
- **Completion** (for sequences): the issue's pull request is open, its checks pass, and the bots'
  comments on it (CodeRabbit and the like) are dealt with. Then the next item starts.
- **Spacing.** Unattended starts keep at least a set gap (say 30 minutes) between new pull requests, so
  bot reviewers aren't flooded and rate-limited. Work I start by hand isn't spaced or queued: it starts now.
- **How far a run goes:** up to a ready pull request. Never merges.
- **Mine, on this Mac.** Nothing is shared through the harness; the schedule is local.

## The screen

- A **week view** (days across, hours down) and a **calendar view** (a month), one page.
- On it, as blocks: review windows (shaded spans), pinned issue starts (at their time), sequences (one
  block per item, laid out from their start with each item's expected length), recurring prompts (at
  each time they recur), and what already ran (with how it went: done, failed, missed, running).
- Add any of the four from the page: click a time to add there, or drag an issue (from Issues or a
  picker) onto a time. Drag a block to move it; drag a sequence's items to reorder them.
- One place to pause everything, and each item pausable on its own.
- A block opens its detail: what it is, when, its last runs, and the session it started (as a tab).

## To consider, not build yet

- Where a recurring report lands: a tab waiting for me, a notification, a file, a Slack draft, or more
  than one.

## Open questions

- A sequence item that fails (checks won't pass, claude gives up): pause the sequence, or skip to the
  next?
- Limits per run (time, cost) and what happens at one: stop and keep the worktree, as the Swift app does?
- The gap between unattended pull requests: one setting for everything, or per repository?
- An issue pinned to a time that already has a session: carry on in it, or skip?
