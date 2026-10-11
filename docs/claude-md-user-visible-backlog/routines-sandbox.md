# Routines and Sandboxes: user-visible material from CLAUDE.md

No docs page exists for Routines (only passing mentions in `sessions/index.md` and `sessions/this-mac.md`). Sandbox setup and behaviour is already in `docs-site/src/content/docs/sessions/sandboxes.md`.

## Routines (needs a new page, e.g. sessions/routines.md)
- Routines start Claude Code sessions by themselves while Gannin is running; never while it is closed or the Mac sleeps. Everything is yours, on this Mac.
- Kinds: report (an Ask session answering the routine's question, files in the Files pane, Commit to Harness; tab says Report), maintenance (no issue, a new branch each run, tab short reference Maintenance, runs on the repos you pick), queue window, pinned issue.
- A routine has: name, project, prompt, the team's prompts (none ticked takes the defaults), repos (maintenance), schedule, how far it may go, a time and cost limit, a queue window's concurrency, a pin's issue, and an on switch.
- How far it may go: Local only (default for new routines: commit and stop; no push, no PR), Draft PR, Ready PR. Never merges.
- Schedules: every N minutes (hourly is on the hour), daily, working days (org's working week less bank holidays), weekly, cron expression (five fields, lists, ranges, steps, names, `@daily`; a bad one is refused with the reason), once (a pin), or a window (hours, may cross midnight, on working days or chosen days). The editor shows the next five times or the problem.
- Missed and skipped: if Gannin was closed or asleep, the latest time within two minutes still runs; older times show as one Missed row (first, last, count). While Pause All is on, a Skipped row appears instead.
- Queue windows: while the window is open the next queued issue starts, up to its concurrency. A failed start puts the issue back at the front; the window waits five minutes, doubling per failure, and stops after four until it next opens or you Run Now (shown on the row). Runs started from a queue or pin write the session record to the harness without asking; scheduling is the consent.
- A routine run needs auto mode (Unattended); if claude can't reach it the run fails with a reason and a notification, and the editor warns.
- Limits: a run past its minutes or cost is interrupted, shows Stopped at limit with a notification; worktree and files are kept. A question or permission prompt shows Needs you. A finished turn shows Finished (Report ready for a report). Notifications follow Settings › General › Agent and open the session.
- Agents › Routines: list of reports and maintenance, queue windows, pinned issues, each with schedule, limit, next run (or Open now), last outcome, on switch; badge is runs going. Toolbar: Pause All (banner while paused), New Routine. Row menu: Run Now, Edit, Turn Off, Delete. A routine's page shows settings, next times and runs (scheduled, started, outcome with note, duration, cost, PRs, Open Session).
- Agents › Queue: the org's queue in order (drag, Move to Top or Bottom, Remove), which windows drain it and when they next open, and issues pinned to a time. Schedule for Agent (beside Work on This in the issue drawer and window, and in Issues › All's menu) adds or removes an issue; Pin to a Time opens the editor. Pills: Queued for Agent (with place) and Pinned for Agent (with time), after the title in Issues › All and by the state in the drawer and issue window.
- Storage: runs kept are the newest 500; routines data is local to this Mac (could go in where-things-are-kept.md).

## Sandbox
- Already in sessions/sandboxes.md: what a sandbox sees, credentials, signing key, GitHub token per org, setup steps, House rules, Work on This placement (A sandbox or This Mac), activity log, Needs the Mac, repo images, server sessions, turning off, limits of protection.
- Possibly missing there: CPUs and memory per sandbox is mentioned but not its setting labels; Sign Out of Claude in Sandboxes is covered; session location banner and chip, and an icon on the tab when not on this Mac (not mentioned); Work on This always shows its sheet with Run in once sandboxing is on (partly covered); a Connect with command that isn't ssh can't be sandboxed and says so; sessions that began before sandboxing was turned on stay on the Mac (covered).
- Settings > Sandbox "Remote machines" and Settings > Harness org GitHub token: covered.

## Dropped
- Issue and plan references (#87, #8, #127, #152, `plans/...`, `requirements/...`): history.
- Routine file names (`routines.json`, `queue.json`, `runs.json`, `state.json`) beyond the folder: derivable from `RoutineStore`.
- Exhaustive `RoutineRunInfo` field list, `ScheduleDraft`, `RoutineEditor` field order, `RunOutcomeLabel`, `DetailSelection.routine`, `WorkloadTab.routines`/`agentQueue`: grep finds them.
- `SandboxSetup` steps and `SandboxSettingsSection` layout narration: derivable.
- Sandbox image contents list (Debian, Node 22, Python...): user guide covers, Containerfile is the source.
- `SessionLocationBadge`/`SandboxStatus` UI placement: moved to the user notes above.
- Stripped "Gannin's and Orchard's label rationale (andrew-waters/orchard#122)": history; the label itself kept.
