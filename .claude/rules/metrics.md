---
paths:
  - "Gannin/Metrics/**"
  - "Gannin/Investments/**"
  - "Gannin/Actions/**"
---

# Metrics, Investments, Actions

User-facing definitions are in `docs-site/src/content/docs/concepts/metrics-glossary.md`; keep code and glossary in step.

## Metrics
- `MetricsStore`: merged-PR history, backfilled to the window's starting Monday, topped up from the last sync with a day of overlap. Searches run a week at a time (GitHub caps a search at 1000 results), 25 PRs a page (GitHub's timeout). PRs opened per week are search counts only, so they ignore `OrgConfig` exclusions.
- `OrgMetrics` definitions (must match the glossary): cycle time = first commit (or creation, if earlier) to merge; TTFR = ready-for-review (or creation) to first non-author, non-bot review; stages are coding, waiting for review, rework (first review to the *last* approval before merge), merging (last approval to merge). Medians and p75, never means. Stages most PRs skip (`StageSummary.isOccasional`) show their share and median-when-it-happens.
- Bot-authored PRs and logins ending `-bot` or `[bot]` are excluded unless in the org's `includedAuthors`.
- `OrgConfigStore` (in `Metrics/`, `UserDefaults`) excludes repos and people from both `Workload` and `OrgMetrics`. Excluded authors lose their PRs and reviews, so `MetricPullRequest` stores raw `reviews` and derives first review and approval from them; don't cache derived values. `reposWithoutReview` repos aren't counted as merged without review. `reposNeedingMac` keeps sessions out of sandboxes.
- Reviewer stats: `ReviewRequestedEvent` / `ReviewRequestRemovedEvent` timeline items (`MetricPullRequest.reviewRequests`). Each request matches that reviewer's first review between request and merge (or withdrawal); withdrawn unanswered requests are dropped; the clock starts at the request or ready-for-review, whichever is later. "Waiting now" uses `PullRequest.reviewRequestedAt`. The team filter applies to the reviewer, not the author.
- `MetricsWindow` is stored in scene storage as a number: days when positive, -1 to -6 for this or last month, quarter, year. It is a range plus the period before it. `OrgMetrics`, `ActionsMetrics`, `IssueMetrics` take it and drop what's after a closed period's end; stores sync `syncDays()` back so the previous period is covered. `OrgMetrics.previous` (`DeliverySummary`) exists only when the history reaches back.
- Dashboard tiles, stage legend, chart weeks and table rows set `DetailSelection.metric(MetricDrill)`, rendered by `MetricColumn`. Opening the Dashboard starts the issue-history and Actions syncs, which Refresh then includes. Chart colours are `ChartPalette` categorical slots 1-4 in order.
- Goals: `MetricGoals`, in `OrgConfig.goals` and `.gannin/goals.json`.
- Scorecards (`Scorecard.swift`, `ScorecardCharts.swift`): `Measurable`s live in `OrgConfig.scorecard` / `.gannin/scorecard.json`; until edited, `OrgConfig.measurables` seeds weekly ones from the Goals. Sources are a `ScorecardMetric` or a hand-entered number (`Measurable.values`, keyed by the period's first day).
  - A count's target is scaled to the column length (`Cell.share`, `Measurable.goal(share:)`: 20 a week is 2 a day) and to the share of an unfinished period. Hand-entered numbers are judged only in their own periods, summed (unjudged) in longer ones.
  - Issue cycle time (`IssueTiming`) and flaky CI runs are synced only when such a goal exists. All time syncs the metrics history back to `IssueStore.earliestIssue`.
  - Per-person rows come from `Scorecard.Data.people` (author, reviewer for requests, assignee for issues, within the team); counts such as PRs merged aren't per person (`Measurable.personal`). Flaky runs expand per repo.
  - `StickyScroll` columns are read only by their modifiers so scrolling doesn't redraw the page. Tiles use `EvenGrid`. Controls sit in the page's bar, not the toolbar.
- `WeeklyDigest` / `DigestSheet` and `StandupNotes` write `digests/<date>.md` / `standups/<date>.md` to the harness.

## Investments
- Built on issues (the issue history), never PRs. `InvestmentConfig` (`OrgConfig.investments`; nil = Balance preset): ordered categories with rules (all conditions in a rule, any rule in a category), plus `manual` assignments by issue node ID. Branch and author stay in the field enum only so older saved rules decode.
- `InvestmentConfig.tracking` governs every read and write:
  - In Gannin: `manual`, else top-most matching category, else the parent's, else uncategorised. Nothing written to GitHub.
  - GitHub labels or one board's single-select field: each category has a `githubValue`; the category is what GitHub says, else the parent's; rules only suggest.
- GitHub writes: choosing a category plans an `InvestmentChange` (labels add/remove, or set option and add to the board if needed). Every write is confirmed first (`InvestmentConfirmation` via `InvestmentPrompt`, `.investmentPrompt()` on main and issue windows). Missing labels are created in the repo. Writes update the local issue history at once.
- Board and Field pickers: `ProjectStore.boardLists` and `loadDefinition`; `ProjectStore.refresh` includes both for the tracked board.
- `InvestmentTriage` collects GitHub-tracked choices until Review and Write.
- `InvestmentBalance.shares` counts each issue once. The issue history is extended back to the range's start as needed. The page has no metrics window picker.
- Category colours are palette slots 1-8 stored on the category so reordering never repaints; uncategorised is neutral grey.

## Actions
- REST only (`ActionsQueries.swift`, the one REST client `GitHubAPI.rest`), budget on `AuthStore.restRateLimit`. No org-wide runs API, so it goes repo by repo, four at once.
- `ActionsStore`: repos listed are non-archived and pushed to since 60 days before the stored range (scheduled workflows run without pushes). Runs are fetched from `coverageStart` (Monday before twice the window, so the previous period is comparable), topped up with a day of overlap or from the oldest unfinished run. A filtered runs query caps at 1000, so a range is halved until it fits. Excluded repos aren't fetched. Fetched only once the page has been opened; Refresh then includes it. Runs older than 190 days are dropped (`keptDays`).
- Jobs (`filter=all`, every attempt) are fetched when a workflow is opened: all completed runs in the window, or the latest N (`jobRunLimitKey`, 0 = all). 40 runs a batch, saved every few batches and on leaving, refetched when a run is re-run, and stopped under 300 REST budget (`jobBudgetFloor`, `jobNotices`).
- `ActionsMetrics`: failure includes timed out and startup failure; cancelled and skipped stay out of rates; duration is latest attempt's start to its last update; flaky = passed only on a re-run, or a commit with both a failed and passing run; `BranchHealth` is default-branch runs outside PRs. `PeriodSummary` changes show only when every repo's runs reach back (`hasPrevious`). Failures on PRs alone aren't flagged. Only a run's latest attempt is listed. `StackedRunTime` shows the top seven and Others.
- Outcomes use `ChartPalette.good`/`critical` plus shape (`OutcomeStrip` tall failures, scatter crosses), never colour alone.
