---
title: Boards
description: Browse your GitHub project boards in Gannin, create and link them, and see time in each status.
sidebar:
  order: 32
---

Projects in the sidebar lists the org's open GitHub project boards. Picking one opens it; before you pick one, the Projects page lists them all.

## The Projects page

It stands in for a repo's Projects tab on GitHub. It shows the org's boards, or, if your project names a repo whose boards it lists, the boards linked to that repo. Search them, and switch between Open and Closed.

These write to GitHub, and each asks you to confirm first:

- **New Board**: a blank board, or a copy of another board's fields and views (optionally with its draft items), linked to a repo if you choose.
- **Link Board** to a repo, and Unlink from it.
- **Close Board** and **Reopen Board**.

## A board

A board's saved views from GitHub show as tabs. Each opens with its own filter, layout, grouping, columns, sort and visible fields. Changes you make here are yours only: they're never saved back to GitHub.

Layouts:

- **Table**: items in sections if the view groups them, under one column header that stays at the top as you scroll. Click a column header to sort by it, within each section; click again to reverse.
- **Board**: columns in the board's option order, with GitHub's colours. A + on a column starts a [New Issue](/docs/guides/new-issue/) with that column's value.
- **Insights**: how long items spent in each status, from the issue history's board changes.

A Roadmap view shows as a table. Reset puts a view's filter back as GitHub has it.

Boards and their items are fetched again after the interval set in Settings › Sync. Reading boards needs the `project` permission on your GitHub sign-in.

To see issues across boards in your own way, use [Views](/docs/guides/views/).
