---
title: Scorecards
description: Track goals week by week, month by month, with a table of results, tiles and per-person breakdowns.
sidebar:
  order: 11
---

Delivery › Scorecards lists your goals against their targets, one column per period. How a goal is judged is in the [Metrics glossary](/docs/concepts/metrics-glossary/). Until you add or edit a goal, weekly goals start from the targets in [Goals settings](/docs/settings/org/goals/).

## The bar

Along the top of the page:

- A search field.
- **Team** and **Owner** menus, when there's a choice.
- **Goals**: which cadence to show (Weekly, Monthly, Quarterly or Annual).
- **View by**: Day, Week, Month, Quarter or Year. It sets the columns, tiles and ranges.
- **Range**: how far back to look. Yesterday or The last week and similar, or All time, which fetches history back to the org's first issue and may take a while.
- **Group by**: Team, Owner or None.
- **Add Goal**.

## Tiles

Each goal has a tile showing its last whole period's value, the change on the one before, the target, and a sparkline of a dozen periods coloured green and red against the target. The change is red only when off target.

## The table

Periods run newest first, with the one under way shaded. Cells are green on target and red off it. N/A means nothing to measure, and a dash means before the history starts. **HIT** counts whole periods on target. The name, target and hit columns stay put when you scroll sideways.

Click a metric's name to expand it into a row per person (the author, the reviewer for review requests, the assignee for issues). Counts such as PRs merged aren't judged per person. Flaky CI runs expand per repo instead, opening its CI page. CI time per PR expands per author. Clicking a person opens their PRs and reviews.

## Adding and editing goals

Right-click a goal for Edit, Duplicate and Delete Goal. The editor sets:

- **Name** and **Every** (the cadence).
- Where the number comes from: a measure from your PRs, reviews, issues or CI, or **A number entered by hand** with a **Unit**.
- **Team** and **Owner**.
- **Target**, At least or At most.
- **Notes**: where the number comes from, what good looks like.

The measure menu greys out measures another goal already uses at that cadence and team.

Hand-entered numbers are typed into a popover on the cell for that period. They are judged only in their own period, and added up without judgement in longer ones.
