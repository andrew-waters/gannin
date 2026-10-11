---
title: Views
description: Make your own views of issues grouped by board fields, with Gannin's measures and confirmed writes.
sidebar:
  order: 33
---

Views is Gannin's own way of looking at issues, not a copy of GitHub's project views. Each view is kept per org and listed under Views in the sidebar. Use New View to make one and Edit View to change it.

## What a view is

A view looks at one board's issues (or every issue Gannin has stored) and has:

- A state: Open, Closed or All, plus filters.
- Any number of dimensions to Group by: board fields by name, issue attributes such as repository or parent issue, and the worked-out Attention and Time in status.
- A **Layout**: Outline, Board, Table, Grid or Aging.
- A **Measure**: Count, Time in status or Time in progress.
- Sort, for issues and for groups (Board order, Count or the measure).
- The fields shown on cards.

## Attention

Attention flags issues that look out of step with their board:

- Quiet in progress
- PR merged, not done
- In review, no open PR
- Done, still open
- Closed, not done

[Board Hygiene](/docs/guides/board-hygiene-and-epics/) lists these and can fix some.

## Changing issues

Everything here writes to GitHub, and every write is confirmed first: Gannin shows the changes and nothing is sent until you press Write.

- **Set Field** on selected issues.
- Dragging a card between columns or lanes.
- **Fill In**: a queue that steps through issues missing a field. You can fill one field or Several Fields. It shows a review before anything is written.

An issue not yet on the board is added to it first.

## Board Fields

Board Fields edits the board's own fields: rename them, and for single-select fields add, rename, recolour, describe, reorder and remove options. Gannin shows the changes for review, and Write Changes sends them to GitHub. Deleting a field is confirmed separately. Existing issues keep their values when you rename or reorder an option. Iteration fields are read-only, and multi-select values can be read but not changed.
