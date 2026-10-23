---
type: plan
status: Done
summary: Show each PR's CI time on the CI page, with the median per PR, who uses it, what drives it and how it follows the size of change, plus a Scorecard goal for it.
issues: [andrew-waters/gannin#476]
domains: [metrics, ci]
touches: [andrew-waters/gannin]
owner: andrew-waters
---

# CI time per pull request

## Context

The CI page summed run time by repo, workflow and trigger, but never by PR, so nobody could see what a
typical PR costs in CI, who uses the most, or why. Runs carry no PR once it merges: GitHub lists a run's
PRs only while they're open and only from the same repo (checked against this repo's runs), so merged
PRs need their head branch to be matched.

## Decisions

- CI time is wall-clock run time, as the rest of the CI page counts it, not billable minutes. GitHub
  Actions only. Earlier attempts of a re-run aren't listed, so their time isn't counted.
- A PR's runs are its own and pushes to its branch, never the default branch. A PR counts in the window
  of its latest run, with all its runs, so each PR counts once.
- Median and p75 per PR, against the period before, as the metrics rule asks.
- What drives it: time by workflow, pushes, failed runs, re-runs, wasted time (replaced commits and
  failures on the last commit) and size.
- Who: by author, share of CI time against share of PRs (Weight). Bots apart, excluded authors out.
- Scaling: Spearman rank correlation of lines and CI time, CI time per 100 lines by size band, and CI
  minutes per 1,000 lines merged by week.
- Also from the discussion: workflows that let overtaken runs finish (Needs attention), the wait on a
  PR's final CI and whether it merged on CI, small PRs running the full suite, bots' share, and a
  Scorecard goal. Estimated billable minutes, post-merge runs and queue time per PR are left for later
  issues: they need jobs or merge SHAs fetched.

## Tasks

- [x] Keep the PR numbers GitHub lists on runs, and keep them when a run is fetched again after merge
- [x] Fetch merged PRs' head branch, and fill it in once for PRs stored before
- [x] `PullRequestCI` and `PullRequestCIMetrics`: matching, per PR numbers, people, scaling
- [x] Pull requests, People and CI and the size of change on the CI page, with PR and person pages
- [x] Superseded runs in Needs attention
- [x] CI time per PR as a Scorecard goal
- [x] Tests, docs (CI guide, glossary, Scorecards), rule, CHANGELOG
- [x] Try it in the app against a real org
