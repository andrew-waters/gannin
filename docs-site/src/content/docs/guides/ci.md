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
- **Pull requests**: CI time per PR and what's behind it (below).
- **People**: who uses the most CI time, against their count of PRs.
- **CI and the size of change**: whether CI time grows in step with the change it checks.
- **Repositories**: each repo's runs, failures, time and share of run time.
- **Workflows**, and runs **By trigger**.

Right-click a repo or workflow to open it on GitHub or Exclude it from Stats.

## CI time per pull request

Each PR's CI time is the run time of every workflow run that ran for it: runs of the PR itself, and pushes to its branch. A PR counts in the window its latest run was in, with all its runs. PRs by bots are counted on their own, and authors you've excluded are left out.

The tiles show:

- **CI time per PR**: the median and p75, with the change on the period before.
- **Wasted**: the share of CI time spent on commits a later push replaced, and on failed or cancelled runs of the PR's last commit.
- **Waiting on CI**: for merged PRs, from the final push to its CI finishing, and that wait's share of the PR's cycle time.
- **Merged on CI**: merged PRs whose merge came within 15 minutes of CI finishing, so CI was the last thing they waited for.
- **Small, full CI**: PRs of up to 20 lines that took more CI than the median PR. These often point to a workflow that runs everything whatever changed.
- **CI per 1,000 lines**: PR CI time over the lines merged in the window.
- **Bots**: the share of PR CI time spent on bots' PRs, such as Dependabot's.

The **Pull requests** table lists each PR with its CI time, the split by workflow, runs, pushes, failed runs, re-runs, wasted time, lines changed and the wait on its final CI. Pick **All**, **Most wasted**, **Small, full CI** or **Bots** above it. Click a PR for its page: its time against the median PR, its time by workflow, and its runs grouped by commit, newest first.

**People** has each author's PRs and CI time, their share of everyone's CI time against their share of the PRs, and the **Weight** between them: over 1× means their PRs take more CI than their number suggests. The medians per PR of pushes, failed runs and re-runs, and their wasted time, show why. Click someone for their PRs.

**CI and the size of change** plots each merged PR's lines changed against its CI time, says how closely one follows the other (a rank correlation), and gives the median CI time and the CI time per 100 lines for each size band. If CI grew in step with size, the time per 100 lines would hold steady across the bands. **CI per 1,000 lines merged**, week by week, rises when CI time grows faster than the change it checks.

Runs are matched to a PR by the PR GitHub lists for them while it's open, or, once it's merged, by its branch. GitHub doesn't link runs to PRs from forks, so their time can't be matched; the page says how much there was.

**Superseded** under Needs attention flags a workflow whose runs keep going after a newer push to the same branch, instead of being cancelled. `concurrency` with `cancel-in-progress: true` in the workflow file stops them.

## Repo, workflow, run and job pages

- A **repo** page covers its workflows and the health of its default branch: runs outside PRs, red now and since when, and the time to get back to green.
- A **workflow** page shows p50, p75 and p90 duration by week, every run's duration (hover a run, click to open it; the dashed line is the median), recent runs and its jobs. Failed runs are drawn so they stand out by shape as well as colour.
- A **run** page lays its jobs on a timeline, with faint bars for the wait for a runner, and lists earlier attempts. Click a job for its steps.
- A **job** page shows the slowest steps.

Run time can be stacked by repo, workflow or job, showing the top seven and the rest as Others.

## What gets fetched

CI is only fetched once you've opened the page for an org. Refresh then includes it. Runs are kept for 190 days. The page also fetches merged PRs, as the PR metrics do, for each PR's title, author, size and branch. PRs fetched before branches were recorded have theirs fetched once ("Head branches" in the sync panel).

Jobs are fetched when you open a workflow, with a progress line ("Fetching jobs: N of M runs"). By default it covers every completed run in the window. Settings › Sync can limit it to the latest runs of each workflow. Fetching stops, with a notice, if the REST budget runs low. See [Sync settings](/docs/settings/app/sync/) and [GitHub budget](/docs/concepts/github-budget/).
