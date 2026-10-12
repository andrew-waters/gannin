---
title: Activity
description: See who did what, and when, with the work log, threads and punchcards.
sidebar:
  order: 20
---

Team › Activity shows what people did on GitHub: commits, reviews, PRs opened and merged, issues opened and comments on issues. It has three tabs, Work log, Threads and Punchcards, which share one page and one scale.

Activity is read from the PRs and issues Gannin has fetched (each issue with its last 30 comments). It starts with the last 28 days and fetches further back as you page, up to a year. It's only fetched once you've opened People pages for the org, and Refresh includes it from then on.

## Work log

Everyone by day or week (Days or Weeks), with a cluster of dots in each cell: commits, reviews, PRs opened, PRs merged, issues opened and issue comments. Commit dots grow with the lines changed. A page holds 14 days or 12 weeks, and you can page back up to a year. Hover a dot for what it was, and click it to open the PR or issue.

A commit counts for its GitHub author when the commit's email is linked to an account, otherwise for the PR's author. An issue opened counts for its author, and a comment for whoever left it. Only comments on issues are shown, not comments on pull requests.

### Filtering

The **Filter** menu in the toolbar (on the Work log tab) narrows the log:

- **Show** ticks which kinds of dot are drawn. What you untick stays hidden on this Mac until you tick it again.
- **Repository** shows only one repo's activity, or All Repositories. It goes back to All when you switch org, or when the repo is no longer in the project.
- **Show Everything** clears both.

The menu's icon fills in while a filter is on, and the legend under the log lists only the kinds being shown.

## Threads

Each person's own PRs as bars from first commit to merge (or to now while open), packed into rows. Their reviews of other people's PRs sit on a line beneath. Only PRs a person authored are drawn as bars, because "Update branch" and merges from main put other people's commits on a PR.

Threads offers Days and Weeks only, and draws PR activity only.

## Punchcards

Weekday by hour for each person, in their own time. Punchcards also offer a single Day, which shows that day's hours.

Hours come from the commit's own timestamp. Other events use the person's most common commit offset. If you've set a time zone for someone, it's used for every event instead. Merges are left out, since merge queues land them whenever CI finishes. Like Threads, punchcards count PR activity only.

## Days off

The work log and threads shade the org's days off and tint each person's time off, and dim the days before someone's start date or after their end date. Punchcards shade working hours and count the activity that falls outside them, including on days off.

The working week and bank holidays are set in [Working Time settings](/docs/settings/org/working-time/). To add time off for someone, right-click their name on any of the three tabs; see [Time off](/docs/guides/time-off/).
