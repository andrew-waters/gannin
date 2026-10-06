---
type: plan
status: Done
summary: One Sync pane in Settings turns each GitHub data source on or off and sets how often it's fetched again, with what each spent in the last hour, and Gannin stops fetching when GitHub says it's over its limit.
issues: [andrew-waters/gannin#28]
domains: [sync]
touches: [andrew-waters/gannin]
owner: andrew-waters
---

# Keeping under GitHub's rate limit

## Context

With regular use Gannin could use up GitHub's hourly budget, and then nothing it showed was
updated until the reset. The budget that runs out is GraphQL's, 5,000 points an hour per token;
only the Actions sync uses REST, which has its own 5,000 requests. Gannin already read both after
every request and held automatic syncs back under 500 points left, but:

- What was fetched, and how often, was fixed in code: the workload snapshot after 5 minutes,
  metrics, issues, work log, boards, harness, Actions and Releases after 10, open issues and
  members hourly. The only settings were the lookback, the Actions job limit and the review
  request check, in two places.
- The two background pollers, session PRs (every 90 seconds, 30 while checks ran) and review
  requests, never held back. The session PR query searched 10 PRs with 60 review threads of 20
  comments each and looked up the session's known PRs a second time: around 7 to 13 points a
  call, so one session with checks running could spend 800 to 1,500 points an hour.
- Nothing knew which feature spent what: sync steps counted their cost, the pollers didn't.
- A request GitHub refused for its rate limit was just an error, and the timers kept asking.

## Decisions

- One Settings pane, Sync (`SyncSettingsView`), app-wide rather than per org, as the budget is
  the token's. Each data source (`SyncSource`) has a row: on or off, how long before it's fetched
  again, and the points (or REST requests) it spent in the last hour or day.
- Off means not fetched at all, Refresh included; pages show what's cached and say it's off. The
  workload snapshot, its members and full search, and the harness (it holds the team's settings)
  can't be turned off, only spaced out.
- An interval is how old data may get before a page that shows it, or a poller, fetches it again.
  Pages still fetch when opened, not on a timer, so nothing new runs in the background.
- A ledger (`APIUsage`) records every GraphQL query's cost and every REST request by source, from
  a task-local set by each fetcher, else the sync run's kind. It keeps a day, on disk.
- The reserve kept for what you do by hand (500 points) is a setting.
- When GitHub says the budget is spent (403 or 429 with no requests left, `Retry-After`, or
  GraphQL's `RATE_LIMITED`), Gannin pauses every request until it says, and the sidebar's footer
  says so.
- The pollers hold back when the budget is low. Session PRs: 5 PRs and 50 threads a query, known
  PRs the search already finds aren't looked up again, and every 2 minutes (1 while checks run)
  by default.
- Target: with the defaults, a day's normal use (one org, a few sessions) stays under half the
  hourly budget. The ledger shows whether it does.

## Tasks

- [x] `SyncSource` and `SyncSettings`: on, interval and reserve, the old review check setting moved across
- [x] `APIUsage` ledger, fed from both transports
- [x] Pause on GitHub's rate limit responses
- [x] Stores read their intervals and on switch from `SyncSettings`
- [x] Pollers: their own intervals, hold back when low, a cheaper session PR query
- [x] Settings › Sync pane, and the footer and pages saying when something's off or paused
- [x] CLAUDE.md
- [ ] Measured with the defaults against the target
