---
title: Activity
description: The work log, threads and punchcards under Team › Activity, what each dot means, and how to filter it.
sidebar:
  order: 1
---

Team › Activity shows what people have been doing, as three tabs over the same page of days or weeks: **Work log**, **Threads** and **Punchcards**. Pick Days or Weeks in the toolbar and page back with the arrows, up to a year.

## Work log

The work log is people down the side and days (or weeks) across the top, with a cluster of dots in each cell. Each dot is one thing someone did:

| Dot | Counts for |
| --- | --- |
| Commit | The commit's GitHub author when its email is linked to an account, else the PR's author. Commit dots grow with the lines changed. |
| Review | The reviewer, on someone else's PR. |
| PR opened | The PR's author. |
| PR merged | Whoever merged it. |
| Issue opened | The issue's author. |
| Issue comment | Whoever left the comment, on an issue (comments on pull requests aren't counted). |

Hover a dot for what it was, and click it to open the PR or issue. Right-click a person for their dates and time off.

### Filtering

The **Filter** menu in the toolbar narrows the work log:

- **Show** ticks which kinds of dot are drawn. What you leave unticked stays hidden on this Mac until you tick it again.
- **Repository** shows only one repo's activity, or All Repositories. It goes back to All when you switch org.
- **Show Everything** clears both.

The menu's icon fills in while a filter is on, and the legend under the log lists only the kinds being shown.

## Threads and Punchcards

Threads draws each person's PRs as bars from first commit to merge, with their reviews of others' PRs beneath. Punchcards show when in the week people work, by weekday and hour in their own time. Both draw PR activity only; issues and comments are on the work log.

## Where it comes from

The work log is fetched once Activity or Standup has been opened for an org, and Refresh includes it from then on. It searches GitHub a week at a time for PRs updated in that week, with their commits and reviews, and for issues updated in that week, with their last 30 comments. Settings › Sync › Work log sets how often it's fetched again, or turns it off. See [The GitHub budget](/docs/concepts/github-budget/) for what that costs.
