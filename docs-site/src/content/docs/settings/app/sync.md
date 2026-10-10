---
title: Sync settings
description: Every option in Settings › Sync, with its default interval and whether it can be turned off.
sidebar:
  order: 2
---

Settings › Sync decides what Gannin fetches from GitHub and how often. It also shows how much of GitHub's hourly budget you have spent, and where it went. These settings are for the whole app, not one org, because the budget belongs to your token. Every option here is kept on this Mac only.

## GitHub's budget

GitHub gives your token a fixed number of points an hour. This section shows what is left, so you can see whether to slow anything down.

| Option | Default | What it changes | Kept |
| --- | --- | --- | --- |
| GraphQL | Not known until the next request | Shows the GraphQL points left and when they reset. Read only. | This Mac |
| REST | Shown once known | Shows the REST requests left and when they reset. Read only. | This Mac |
| Spent in the last hour | 0 points | Shows the points used in the last hour, and the REST requests too when there are some. A warning appears above half the hourly budget. Read only. | This Mac |
| Keep in reserve | 500 points | The reserve: points held back for what you open or Refresh by hand. Once fewer are left, automatic fetches and background checks wait for the reset. Choose 250, 500, 1000, 1500 or 2500. | This Mac |

If GitHub refuses a request for its rate limit, Gannin pauses and says when it will ask again.

## Spent

The Spent list shows what each source used, most first. Sources that used nothing are left out, and an empty list says "Nothing yet." Use the picker to switch between Last hour and Last day. Most sources are charged in points. GitHub Actions is charged in REST requests.

| Option | Default | What it changes | Kept |
| --- | --- | --- | --- |
| Spent | Last hour | Chooses the window for the list: Last hour or Last day. | This Mac |

Some work is charged in the list but has no setting, because it happens when you do something: Items you open, Changes you make, Account and settings, and Other.

## Workload

Open PRs and issues, and what changed since the last fetch. This group is always on. Rows are fetched when a page needs them and the data is older than the interval, so their choices read "After" followed by a time.

| Option | Default | What it changes | Kept |
| --- | --- | --- | --- |
| Workload | After 5 minutes. Cannot be turned off. | Open PRs and issues, and PRs merged in the lookback. | This Mac |
| Members and teams | After 1 hour. Cannot be turned off. | The org's members and teams. Refresh fetches them too. | This Mac |
| Full search | After 1 day. Cannot be turned off. | Searches everything again rather than only what changed. | This Mac |

## Issues

| Option | Default | What it changes | Kept |
| --- | --- | --- | --- |
| Issue history | After 10 minutes. Can be turned Off. | Issues closed in the window and open ones, with board moves, for the issue pages, Inbox, Views and meetings. | This Mac |
| Every open issue | After 1 hour. Cannot be turned off on its own. | Fetches every open issue again, as board moves do not count as updates. It goes off with Issue history. | This Mac |
| Issue descriptions and comments | After 10 minutes. Can be turned Off. | Fetches text for searching in descriptions, after each issue sync. It goes off with Issue history. | This Mac |

## Pages

These are fetched when a page that shows them opens and they are older than the interval. Off means not fetched at all, Refresh included: pages show what was fetched before. The choices read "After" followed by a time.

| Option | Default | What it changes | Kept |
| --- | --- | --- | --- |
| PR metrics | After 10 minutes. Can be turned Off. | Merged PRs for the Dashboard, PR flow and Scorecard. | This Mac |
| Work log | After 10 minutes. Can be turned Off. | Commits, reviews, issues opened and issue comments for Activity and Standup, once one has been opened. | This Mac |
| Project boards | After 10 minutes. Can be turned Off. | Board lists, fields and items. | This Mac |
| Milestones and releases | After 10 minutes. Can be turned Off. | Milestones, releases, downloads and stars, once the Releases page has been opened. | This Mac |
| GitHub Actions | After 10 minutes. Can be turned Off. | Workflow runs for the CI page, once it has been opened. Uses the REST budget. | This Mac |
| Harness | After 10 minutes. Cannot be turned off. | Plans, requirements, skills and the team's shared settings. It stays on, as your team's settings are kept there. | This Mac |

## In the background

These are checked while Gannin runs, and held off when the budget is low. The choices read "Every" followed by a time.

| Option | Default | What it changes | Kept |
| --- | --- | --- | --- |
| Your reviews and PRs | Every 5 minutes. Can be turned Off. | PRs your review is asked on, your own PRs and your issues, for the menu bar, Agents and notifications. | This Mac |
| Watched reviews | Every 5 minutes. Can be turned Off. | Reviewed PRs that Claude watches for new commits and comments. | This Mac |
| Session pull requests | Every 2 minutes. Can be turned Off. | Each running session's PRs: checks, reviews and threads. The PRs pane still looks when you open it. | This Mac |
| While checks run | Every 1 minute. Cannot be turned off on its own. | How often to look while a session's PR has checks running. It goes off with Session pull requests. | This Mac |

## How much

| Option | Default | What it changes | Kept |
| --- | --- | --- | --- |
| Merged work from the last | 14 days | How far back merged work is fetched, from 1 to 90 days. It applies on the next refresh. | This Mac |
| Actions jobs per workflow | Every run in the window | How many runs per workflow have their jobs fetched when you open a workflow: Every run in the window, or the latest 500, 200, 100, 50 or 20. Each run's jobs cost a REST request. Jobs already fetched are kept. | This Mac |

When a source is turned off, the page that shows it tells you, with a link back to Sync Settings, so old data is not mistaken for current.
