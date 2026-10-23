---
paths:
  - "Gannin/Metrics/**"
  - "Gannin/Investments/**"
  - "Gannin/Actions/**"
---

# Metrics, Investments, Actions

## Metrics
- Must match `docs-site/src/content/docs/concepts/metrics-glossary.md` whenever a metric's definition changes; update both.
- Never cache values derived from `MetricPullRequest.reviews`; store the raw reviews. Excluded authors lose their reviews, so first review and approval must be recomputed under the current `OrgConfig`.
- Keep merged-PR searches to a week at a time and small pages: GitHub caps a search at 1000 results and times out on large pages.
- Never apply `OrgConfig` exclusions to "PRs opened" (a search count); everything else in `OrgMetrics` and `Workload` must apply them.
- Report medians and p75, never means.
- Take the team filter from the reviewer, not the PR author, for reviewer stats.
- Treat `MetricsWindow` as a range plus the period before it; new metrics must take it, drop what's after a closed period's end, and keep `syncDays()` covering the previous period.
- Scorecard count targets must be scaled to the column length and to the share of an unfinished period (`Measurable.goal(share:)`); never judge hand-entered numbers outside their own periods.
- Sync issue cycle time and flaky-run data only when a goal needs them.

## Investments
- Build only on issues, never PRs.
- Never write to GitHub without confirming first (`InvestmentConfirmation`); update the local issue history in the same step.
- Follow `InvestmentConfig.tracking` for every read and write: when tracked on GitHub, GitHub's value wins over the rules (rules only suggest).
- Keep branch and author in the rule field enum: older saved rules must still decode.
- Store category colours on the category so reordering never repaints.

## Actions
- Use REST only (`GitHubAPI.rest`) with its own budget (`AuthStore.restRateLimit`); there is no org-wide runs API, so fetch repo by repo.
- Halve a runs range until it returns under 1000 results (GitHub's cap on a filtered query).
- Include repos with no recent pushes up to 60 days before the range: scheduled workflows run without pushes.
- Fetch runs back to `coverageStart` so the previous period is comparable; show changes only when every repo reaches back (`hasPrevious`).
- Stop job fetching under the REST budget floor (`jobBudgetFloor`).
- Never flag failures on PRs alone: that is CI doing its job. Never use colour alone for outcomes.
- Match runs to PRs with `PullRequestCI.match` only: GitHub lists a run's PRs only while they're open and from the same repo, so merged PRs are matched by `MetricPullRequest.headRef`, and a refetched run keeps the numbers it was first listed with (`ActionsStore.sync`).

## Testing
- `PullRequestCITests` covers run matching, a PR's time split, the rank correlation, size bands and overtaken runs. No tests cover `OrgMetrics`, `Scorecard`, the rest of `ActionsMetrics` or `InvestmentConfig` (only `SessionBriefGoalsTests.swift` touches goals). Check by hand against the glossary after changing a definition.
