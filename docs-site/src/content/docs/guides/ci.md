---
title: CI
description: GitHub Actions insights, from the org's run time down to a single job.
sidebar:
  order: 13
---

Delivery › CI shows how your GitHub Actions workflows are doing: how often they fail, how long they take and where the time goes. How each number is worked out is in the [Metrics glossary](/docs/concepts/metrics-glossary/).

It follows the window picked in the toolbar and compares with the period before when every repo's runs reach back that far. Repos you've excluded from stats aren't included.

## The CI page

- Tiles for the window, with changes on the period before.
- **Needs attention**: red default branches, often-failing and flaky workflows, and ones that slowed down.
- **Trends**: runs and duration over time, and run time by repo.
- **Repositories**: each repo's runs, failures, time and share of run time.
- **Workflows**, and runs **By trigger**.

Right-click a repo or workflow to open it on GitHub or Exclude it from Stats.

## Repo, workflow, run and job pages

- A **repo** page covers its workflows and the health of its default branch: runs outside PRs, red now and since when, and the time to get back to green.
- A **workflow** page shows p50, p75 and p90 duration by week, every run's duration (hover a run, click to open it; the dashed line is the median), recent runs and its jobs. Failed runs are drawn so they stand out by shape as well as colour.
- A **run** page lays its jobs on a timeline, with faint bars for the wait for a runner, and lists earlier attempts. Click a job for its steps.
- A **job** page shows the slowest steps.

Run time can be stacked by repo, workflow or job, showing the top seven and the rest as Others.

## What gets fetched

CI is only fetched once you've opened the page for an org. Refresh then includes it. Runs are kept for 190 days.

Jobs are fetched when you open a workflow, with a progress line ("Fetching jobs: N of M runs"). By default it covers every completed run in the window. Settings › Sync can limit it to the latest runs of each workflow. Fetching stops, with a notice, if the REST budget runs low. See [Sync settings](/docs/settings/app/sync/) and [GitHub budget](/docs/concepts/github-budget/).
