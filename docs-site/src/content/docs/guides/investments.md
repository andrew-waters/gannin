---
title: Investments
description: See how completed and in-progress work splits across your investment categories, and assign issues to categories.
sidebar:
  order: 12
---

Delivery › Investments shows where effort went, by category, such as new things, improving things and keeping the lights on. It is built on issues, not PRs. Categories, rules and how they're tracked are set in [Investments settings](/docs/settings/org/investments/).

## The bar

- **Show**: Completed, In progress, Backlog (open at the end of the range and not in progress) or All. Each issue is counted once.
- **Range**: Last 30 days, Last 90 days, This quarter, Last quarter, This year, All time (from the org's first issue), or Custom with From and To dates. The page has no Window menu, as its range covers that. The issue history is extended back as needed.
- **Per**: how the chart groups completed work: Week, Month or Quarter, and Year for All time.
- Above the chart, **Count** or **Share** switches between issues per category and each category's share of the period.

## Reading it

Completed work is charted per period. Hover a period for values and click it to see its breakdown above. Click a category to list its issues on the page.

A category with a target share shows against it, and the page calls out those more than ten points off. Uncategorised is grey. Each category keeps its colour even if you reorder them.

## Assigning categories

**Assign to Categories** goes through issues without one, a card at a time. Press a number key for a category, and use the arrows to skip or go back. Where the rules have a suggestion it says "Suggested by the rules".

You can also use Categorise in an issue's context menu or window.

How a choice is stored depends on how you track investments. In Gannin, nothing is written to GitHub. With GitHub labels or a board field, each choice is a change on GitHub. Choices collect until you press **Review and Write**, and nothing is written until you confirm. Missing labels are created in the repo.
