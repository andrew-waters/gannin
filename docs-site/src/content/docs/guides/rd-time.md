---
title: R&D time
description: See how much of the team's working time went to R&D work, by issue and by person, and export it for a tax credit claim.
sidebar:
  order: 16
---

Delivery › R&D Time shows how much of each person's working time went to issues that count as research and development, over an accounting period, so a claim for an R&D tax credit can be prepared from the issues themselves. What counts, how time is found and when your accounting year starts are set in [R&D settings](/docs/settings/org/rd-time/).

It records and reports time only. Gannin never asks for or keeps salaries, rates or costs: turning hours into a claim value stays with you or your adviser. Nothing in it follows one country's scheme, and the name "R&D" can be changed to the term your scheme uses. Which work qualifies is for you and your adviser to decide; this is not tax advice.

## How time is found

Time comes from activity Gannin already sees. For each person and each working day in the range:

1. The day's hours are their working hours: their own pattern or the org's working week, less bank holidays and time off (a half day of leave halves it). Days before they started or after they left, weekends and other days off have none. Activity on those days adds no hours.
2. The hours are split across the issues they worked on that day: commits on (and opening) a PR that closes an issue, reviews of one, and comments on an issue. A PR that closes no issue keeps its own share, so the time is still accounted for, though only issues can count as R&D.
3. A working day with no activity goes to the issues behind the PRs they had open, or stays unallocated, as set.

The activity is the same as the [Activity](/docs/guides/activity/) page's, fetched back to the start of the range when you open the page. A whole accounting year can take a while the first time.

## The toolbar

- **By issue** or **By person** in the middle.
- **Show**, on By issue: only work that counts as R&D, or Everything with time on it.
- **Range**: This accounting year, Last accounting year, This quarter, Last quarter (quarters of the accounting year), or Custom with From and To dates. Hover it for the dates.
- **Export**: Issues (CSV), People (CSV), Daily lines (CSV) or Report (Markdown), saved where you choose.

## Reading it

The top of the page shows R&D hours and their share of working hours, working hours and how many people, hours allocated, and Unallocated (working days with nothing to show).

By issue lists each issue with whether it counts (and its share and why: Marked by hand, Matched, or From its parent), its hours, its R&D hours (hours times share), who the hours are from and the rationale. Click a row to open the issue.

By person lists each person's working hours, hours allocated, unallocated hours, R&D hours and R&D's share of their working hours.

## Marking issues

Right-click an issue (under Everything to see those that don't count yet):

- **Count as R&D** or **Don't Count as R&D** overrides What counts for that issue.
- **Edit R&D Mark** sets whether it counts, the share of it that's R&D (in steps of 5%, for work that's only partly R&D), and a rationale saying why, which goes into the exports.
- **Clear Mark** goes back to What counts.

Marks are kept with the settings in the project's harness, so the team shares them. Settings › R&D lists every marked issue.

## The exports

Every line links back to its issue, and the issue export lists the PRs behind its time, so each line can be checked against the work.

- **Issues (CSV)**: reference, title, link, whether it counts, share, basis, rationale, hours, R&D hours, hours per person, first and last day, and its PRs.
- **People (CSV)**: login, name, working hours, allocated, unallocated, R&D hours and share.
- **Daily lines (CSV)**: a row per person, day and issue with its hours, R&D hours, source and basis (the events that day, or an open PR).
- **Report (Markdown)**: totals, how the numbers were found, the R&D issues and the people.
