---
title: Standup
description: The morning standup on a shared screen. Walk the board column by column, go person by person, read the day's changelog, or post it as written notes, in the style your team picks.
sidebar:
  order: 21
---

Rituals › Standup is built for the team's morning standup round a shared screen. It looks back on one day, which is the last working day by default (Friday, on a Monday). It reads the project's workflow board, and the same work log data as [Activity](/docs/guides/activity/).

## Styles

Teams run standup differently, so Standup has a style for each way. The **Style** menu in the toolbar picks one for today's standup. The style it opens on is the team's own, set in [Org settings › Issues](/docs/settings/org/issues/#standup) under Standup, and it starts as Walk the Board.

- **Walk the Board**: the workflow board, a column at a time, in this order:
  1. **Done and needs discussion**: anything to discuss first, then the open issues in a done status. Closed issues aren't shown, so closing an issue takes it off the standup.
  2. **In review**
  3. **In progress**
  4. **Triage**: open issues with no Status on the board, or not on it at all. These are the same issues as [Prioritisation](/docs/guides/prioritisation/)'s Triage list.

  Every column shows the board as it is now. In each one, the issues are grouped under each assignee, by name, with the unassigned last; an issue with two assignees is under both. Each issue is a tile with its title, then its repo and number, its status and when it last moved. In review and In progress keep board order, with whatever has been there longest at the top.
- **Person by Person**: a section for each person. It shows their tickets in the same four columns, then their day: their counts, a strip of when things happened on one hour axis shared by everyone (with their working hours shaded), and a timeline of what they did. People who were off, or who have nothing to show, are listed at the end.
- **Changelog**: the issues closed that day, from the issue history. Completed ones are grouped by investment category, followed by those closed as not planned.
- **Written**: everyone's day and tickets in flight as Markdown, followed by what's to discuss and how many issues wait for triage. It suits a team that posts its standup rather than meeting.

Which status falls in which column is set per project, under Standup columns in Org settings › Issues. Until a status is set there, Gannin guesses its column from its name: names like Done or Shipped go in Done, names with "review" go in In review, and the [Issue workflow](/docs/settings/org/issues/#issue-workflow)'s in-progress statuses, or names with "progress", go in In progress. Any other status isn't shown. Walk the Board needs the Issue workflow board to be picked.

Click an issue to open it in the drawer.

## Needs discussion

To raise an issue at standup, give it the team's discussion label on GitHub. The label is "needs discussion" unless your team has named another one. Open issues with the label are listed first under Done and needs discussion, under To discuss, with a speech-bubble mark. They're also kept in their own column, with the same mark.

Right-click an issue and choose **Needs Discussion** to add the label, or **Discussed** to take it off. Gannin asks you to confirm before it writes to GitHub, and it creates the label in the repo if the repo doesn't have one yet.

## Presenting

**Present** in the toolbar makes everything larger and shows one step at a time: a column of the board, or one person. The Left and Right Arrow keys step back and forward, as do the arrow buttons in the toolbar. Dots in the header show how far you've got, and you can click a dot to jump to that step. Esc, or Present again, goes back to the whole page.

Changelog and Written have no steps; presenting just makes them larger.

## Changing the day

The toolbar has arrows for the working day before and after, a button for the last working day (named Yesterday, or the weekday), and Today, which previews today so far. You can't go past today. Each person's day counts from the start of the day picked; the board's columns are as they are now, whatever the day.

## Commits

A run of commits on one PR is one item. Open it with its chevron, or turn on the **Commits** toggle in the toolbar to unfold them all. The toggle applies to Person by Person. A merge lists the issues it closes.

Some things are credited by assumption. An issue opened counts for its author. Issue moves and closes count for the assignees, because GitHub doesn't say who did them.

## Notes

**Notes** in the toolbar turns the day into Markdown, per person, the same as the Written style. You can copy it, have Claude rewrite it, or commit it to the project's harness as `standups/<date>.md`. It isn't available on the Changelog style.
