---
title: Goals settings
description: Every option in Org settings › Goals, the delivery targets shown on the Dashboard as on track or not.
sidebar:
  order: 7
---

Org settings › Goals sets delivery targets for the whole org, and for any team that wants its own. Open it with the cog beside the account menu in the sidebar's footer, then pick Goals in the toolbar. The Dashboard shows each goal as on track or not, for the window picked, with where it was in the period before. The Scorecard keeps its own measurables and targets for each cadence, starting from these as weekly ones.

Goals belong to the project your window is working in. A project's harness keeps them as `.gannin/goals.json`, and changes wait in the sidebar ("N changes to commit") until you review and commit them. An org with no harness keeps them on this Mac.

Every goal starts empty, which means no goal. Type a number into the box to set one. The cross at the end of a row clears it (its help text says "No goal"). Zero also clears it. A team's empty goals use the org's, shown greyed in the box.

## Goals for

| Option | Default | What it changes | Kept |
| --- | --- | --- | --- |
| Goals for | The whole org | Chooses whose goals you are editing: The whole org, or one of the org's teams. | Not kept, it only picks what you edit |

## Velocity

| Option | Default | What it changes | Kept |
| --- | --- | --- | --- |
| PRs merged | None | At least this many a week. A longer window is held to as many weeks' worth. | Harness (`.gannin/goals.json`) |
| Cycle time | None | At most this many hours, as a median from first commit to merge. | Harness (`.gannin/goals.json`) |
| First review | None | At most this many hours, as the median wait for the first review once a PR is ready. | Harness (`.gannin/goals.json`) |

## Quality

| Option | Default | What it changes | Kept |
| --- | --- | --- | --- |
| PRs with rework | None | At most this percentage of PRs having changes asked for after the first review. | Harness (`.gannin/goals.json`) |
| Merged without review | None | At most this percentage of PRs merged without a review, counting only repos that need one. | Harness (`.gannin/goals.json`) |
| PR size | None | At most this many lines changed, as a median. | Harness (`.gannin/goals.json`) |
| Files changed | None | At most this many files changed per PR, as a median. | Harness (`.gannin/goals.json`) |

## Reviewing

| Option | Default | What it changes | Kept |
| --- | --- | --- | --- |
| Review requests answered | None | At least this percentage of review requests answered before the PR merged, or the request was withdrawn. | Harness (`.gannin/goals.json`) |
