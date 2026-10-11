---
title: Activity
description: See who did what, and when, with the work log, threads and punchcards.
sidebar:
  order: 20
---

Team › Activity shows what people did on GitHub: commits, reviews, PRs opened and PRs merged. It has three tabs, Work log, Threads and Punchcards, which share one page and one scale.

Activity is read from the PRs Gannin has fetched. It starts with the last 28 days and fetches further back as you page, up to a year. It's only fetched once you've opened People pages for the org, and Refresh includes it from then on.

## Work log

Everyone by day or week (Days or Weeks), with a cluster of dots in each cell: commits, reviews, PRs opened and PRs merged. Commit dots grow with the lines changed. A page holds 14 days or 12 weeks, and you can page back up to a year.

A commit counts for its GitHub author when the commit's email is linked to an account, otherwise for the PR's author.

## Threads

Each person's own PRs as bars from first commit to merge (or to now while open), packed into rows. Their reviews of other people's PRs sit on a line beneath. Only PRs a person authored are drawn as bars, because "Update branch" and merges from main put other people's commits on a PR.

Threads offers Days and Weeks only.

## Punchcards

Weekday by hour for each person, in their own time. Punchcards also offer a single Day, which shows that day's hours.

Hours come from the commit's own timestamp. Other events use the person's most common commit offset. If you've set a time zone for someone, it's used for every event instead. Merges are left out, since merge queues land them whenever CI finishes.

## Days off

The work log and threads shade the org's days off and tint each person's time off, and dim the days before someone's start date or after their end date. Punchcards shade working hours and count the activity that falls outside them, including on days off.

The working week and bank holidays are set in [Working Time settings](/docs/settings/org/working-time/). To add time off for someone, right-click their name on any of the three tabs; see [Time off](/docs/guides/time-off/).
