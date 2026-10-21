---
title: R&D settings
description: Every option in Org settings › R&D, where you choose what counts as R&D work and how its time is found.
sidebar:
  order: 7
---

Org settings › R&D sets up the [R&D Time](/docs/guides/rd-time/) page. Open it with the cog beside the account menu in the sidebar's footer, then pick R&D in the toolbar.

Everything here belongs to the project your window is working in. A project's harness keeps it as `.gannin/rnd.json`, along with the issues marked by hand, and changes wait in the sidebar ("N changes to commit") until you review and commit them. An org with no harness keeps it on this Mac. No salaries, rates or other costs are asked for or kept anywhere. The page's ranges follow the org's accounting year and periods, set in [Working Time](/docs/settings/org/working-time/#accounting-periods).

## What counts

| Option | Default | What it changes | Kept |
| --- | --- | --- | --- |
| Name | R&D | What the work is called on the page and in exports, for schemes that use another term. | Harness (`.gannin/rnd.json`) |
| What counts | Marked by hand | Which issues count. Marked by hand counts only the issues you mark on the R&D Time page. Investment categories counts issues in the categories you tick, so the categories' rules (see [Investments settings](/docs/settings/org/investments/)) decide. GitHub labels counts issues with any of the labels you list. A board field counts issues with any of the options you tick of a single-select field. | Harness (`.gannin/rnd.json`) |
| Labels | Empty | Shown for GitHub labels. The labels, separated by commas. Case doesn't matter. | Harness (`.gannin/rnd.json`) |
| Board | Choose a board | Shown for A board field. The project board that holds the field. | Harness (`.gannin/rnd.json`) |
| Field | Choose a field | Shown once a board is picked. The board's single-select field. Its options are then listed to tick. | Harness (`.gannin/rnd.json`) |

A sub-issue counts when its parent does, unless it is marked itself. An issue marked by hand always follows its mark.

## How time is found

| Option | Default | What it changes | Kept |
| --- | --- | --- | --- |
| Source | From activity | Where time comes from. From activity takes each person's working hours and places them on the issues they worked on. | Harness (`.gannin/rnd.json`) |
| Split each day | Evenly | Evenly gives each issue touched that day the same share of the day. By activity shares the day by how many commits, reviews and comments each issue got. | Harness (`.gannin/rnd.json`) |
| Days with no activity | Their open pull requests | What happens to a working day with no activity. Their open pull requests gives it to the issues behind the person's PRs open that day. Unallocated leaves it unplaced, shown as Unallocated. | Harness (`.gannin/rnd.json`) |
| Count reviews | On | Whether reviewing a PR counts as working on the issues it closes. | Harness (`.gannin/rnd.json`) |
| Count issue comments | On | Whether commenting on (or opening) an issue counts as working on it. | Harness (`.gannin/rnd.json`) |

Working hours come from [Working Time](/docs/settings/org/working-time/): the org's working week or a person's own pattern, less bank holidays and time off. Commits and opening a PR always count.

## Marked issues

Every issue marked by hand, with whether it counts, its share and its rationale.

| Option | Default | What it changes | Kept |
| --- | --- | --- | --- |
| Clear | Not applied | Forgets the mark, so the issue goes back to What counts. | Harness (`.gannin/rnd.json`) |
