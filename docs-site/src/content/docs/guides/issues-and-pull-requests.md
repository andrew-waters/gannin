---
title: Issues and Pull Requests
description: The Issues and Pull Requests pages, their filters, and adding issues to a board in bulk.
sidebar:
  order: 30
---

Gannin lists issues and pull requests as tables you can search, filter and sort. Both come from what Gannin has already fetched, so they open quickly and follow your window's project.

## Issues

Under Issues in the sidebar:

- **Issues** is issue metrics: how many were opened and closed, cycle time, and an In progress now list with its own search. In progress now can be ordered by a field from a board. An issue that isn't on the board you picked says so rather than disappearing.
- **All** is a table of every open issue and those closed since the start of the metrics window: title, repository, number, author, assignees, labels, linked PRs, opened and closed. Click a column to sort. Sub-issues fold under their parent when both are listed. While you search or filter they show flat.
- **Not on a board** lists issues on no project board, or not on one you choose, open, closed or both.

How cycle time is worked out is set in [Issues settings](/docs/settings/org/issues/).

## Filters

The bar at the top of the page has a search and filter menus. The search needs every word you type to match the title, repository, number, a person's login or name, or a label.

- **Assignee**: Me, Anyone assigned, Unassigned, or a person.
- **Repository** and **Label**.
- **Field**: one submenu per board field, with its values in the board's order and No value. It appears once an issue is on a board.
- **Milestone**: No Milestone first. It appears once an issue has a milestone.
- **Open**, **Closed** or **All**.

Menus show counts, and you can pick several values in one. Not on a board puts its board picker first.

Pull Requests has its own bar: search, **Author**, **Reviewer** (Me first, then No Reviewer), **Status** (draft, needs review, changes requested, approved, merged), **Repository**, and Open, Merged or All. Open covers open PRs and Merged those merged within the lookback ([Sync settings](/docs/settings/app/sync/)). The Files and Size columns show files changed and lines added and removed.

Filters are kept per window, so two tabs can look at different slices.

### Reviewers

The Reviewers column on Pull Requests shows who has been asked to review and who already has. Each face has a badge:

- A clock: asked and hasn't reviewed yet, or asked again after reviewing. These come first, so it's easy to see who a PR is waiting on.
- A team icon with a clock: a team asked to review.
- A green tick: approved. An orange mark: changes requested. A speech bubble: commented.

Hover for each name and where their review stands. A PR nobody has been asked to review and nobody has reviewed shows None. Sorting by the column orders PRs by how many reviewers they're waiting on, then by how many reviewers they have. A PR only a team has been asked on isn't No Reviewer in the Reviewer filter, and in the Inbox its State reads Waiting on the team. The PR's drawer marks its reviewers the same way and lists any teams asked.

## Add issues to a board

On Not on a board, select issues and choose Add to Board, then pick the board. This writes to GitHub: Gannin lists what will be added and asks you to confirm. It then adds each one and ticks it off, and stays open until you press Done. Reading boards needs the `project` permission on your GitHub sign-in.

## Open an issue or PR

Click a row to open it in a drawer over the page. Right-click for Open in New Tab or Open in New Window. To write a new issue, see [New Issue](/docs/guides/new-issue/).

<figure class="screenshot">
  <img class="dark" src="/assets/screens/pull-request-dark.png" alt="A pull request in a drawer over the Dashboard: its status, checks, reviewers, linked issue and description" />
  <img class="light" src="/assets/screens/pull-request-light.png" alt="A pull request in a drawer over the Dashboard: its status, checks, reviewers, linked issue and description" />
</figure>
