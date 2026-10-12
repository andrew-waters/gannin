---
title: Standup
description: Everyone's activity on one day, by person, as a team timeline, or as a changelog of closed issues.
sidebar:
  order: 21
---

Rituals › Standup shows what the team did on one day. It opens on the last working day (Friday, on a Monday), and it reads the same work log data as [Activity](/docs/guides/activity/).

## Changing the day

The toolbar has arrows for the working day before and after, a button for the last working day (named Yesterday, or the weekday), and Today, which previews today so far. You can't go past today.

## Layouts

A toolbar control picks the layout.

- **By Person**: a row for each person. On the left are their counts, with icons that double as a legend. Next is a strip along a single hour axis shared by everyone (6:00 to 22:00 at most, with working hours shaded). Then comes a timeline: the time, an icon, and the title with its context.
- **Team**: everyone's items on one timeline with avatars before the times, under the team's counts and one strip. People who are off, or who have nothing recorded, are listed at the end.
- **Changelog**: the issues closed that day, from the issue history. Completed ones are grouped by investment category, followed by those closed as not planned.

A run of commits on one PR is one item. Open it with its chevron, or turn on the Commits toggle in the toolbar to unfold them all. A merge lists the issues it closes.

Some things are credited by assumption. An issue opened counts for its author. Issue moves and closes count for the assignees, because GitHub doesn't say who did them.

## Notes

Notes in the toolbar turns the day into Markdown, per person. You can copy it, have Claude rewrite it, or commit it to the project's harness as `standups/<date>.md`. It isn't available on the Changelog layout.
