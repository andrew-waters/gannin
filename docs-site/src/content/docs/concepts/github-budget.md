---
title: The GitHub budget
description: How Gannin spends GitHub's rate limit, the reserve, and what happens when it runs out.
sidebar:
  order: 3
---

GitHub gives each signed-in token a budget for its API: **5,000 points an hour** for GraphQL, which almost everything in Gannin uses, and a separate allowance for REST, which the GitHub Actions pages use. The budget belongs to your token, so it's shared by every org you look at and every Mac signed in as you, and by other apps using the same login.

## Where to see it

- The **sync row** at the foot of the sidebar shows the budget left and when it resets.
- **Settings › Sync** shows the budget, a warning once you've spent more than half the hour's, and **Spent**: what each kind of fetch has cost over the last hour or day, most first. Fetches made because you opened a page or did something count too.

## What spends it

Each row in [Settings › Sync](/docs/settings/app/sync/) is something Gannin fetches, with how often. Pages fetch what they show when you open them and it's older than its interval; background checks (your review requests, watched reviews, sessions' pull requests) run on their own timers. A refresh only fetches what changed since the last one, with a full fetch once a day.

To spend less, make rows less frequent or turn off the ones you don't use. Off means not fetched at all, Refresh included. A few rows can't be turned off (the workload and the harness, which hold what every page needs); they can only be spaced out.

## The reserve

The **reserve** (500 points by default, in Settings › Sync) is what automatic fetches leave for what you do by hand. When the budget drops under it, automatic refreshes and background checks hold off, and pages show what's cached. Refresh (⌘R) and the things you click still work.

## When it runs out

If GitHub refuses a request because the budget's gone, Gannin pauses every request of that kind until GitHub says it may try again. The sync row shows **Paused to** and the time, in orange. Cached pages keep working meanwhile, and fetching picks up by itself after the reset.
