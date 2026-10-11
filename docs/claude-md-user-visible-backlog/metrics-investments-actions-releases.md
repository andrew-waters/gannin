# User-visible material from CLAUDE.md (Metrics, Investments, Actions, Milestones and Releases)

Plain-language notes for the docs site. "Already in" means a page states it.

## Metrics windows and definitions
- Window picker, period before, medians and p75, bots, exclusions, stage definitions, reviewer stats, size/rushed PRs: already in concepts/metrics-glossary.md.
- Window options (days, this or last month, quarter, year) and that the Investments page has its own range instead: window part in glossary; Investments range is not documented (see Investments).

## Dashboard
- Needs attention (Act now, Today, Keep an eye on) and its item types: already in concepts/metrics-glossary.md.
- Sections: Needs attention (two columns, each item opens what it's about), Scorecards (a tile per goal, judged on last whole period, sparkline over the window), Team (tiles for who's in and off, reviews owed, who's free, open, awaiting review, stale, unassigned; a card per person with today's status, in flight against the busiest, PRs, reviews owed, issues, merged and reviewed in the window), Flow (open PRs by stage: draft, waiting for review, in review, changes asked, approved, with counts, median time there and oldest; then what merged). Not documented yet.
- Dashboard follows the window picked on the metrics pages; tiles show change on the period before; clicking a tile, legend entry, chart week or table row shows the PRs behind the number. Not documented.
- "What changed" (which stages, repos and people moved cycle time and throughput) and the PR size / rushed large PRs by repo section. Not documented.
- People page's Size and Files columns: already in glossary (Size and Files).
- Goals (Settings > Goals): org and per-team targets (PRs merged a week, cycle time, first review, rework, unreviewed, PR size, files changed, requests answered), shown on the Dashboard as on track or not. Partly in settings/org/goals.md.

## Scorecards (Delivery > Scorecards)
- Judging rules (last whole period, shaded current period, count targets scaled to column length, Hit, hand-entered numbers, source metrics): already in concepts/metrics-glossary.md (Scorecards).
- Not documented: goal editor fields (cadence, source, team, owner, target at least/at most, notes; the Measures menu greys metrics another goal already has at that cadence and team); units for hand-entered numbers (number, money, percentage, hours, days); until edited, weekly goals are seeded from Goals.
- Not documented: the page bar (search, Team and Owner filters, Goals cadence picker, View by day to year, range such as Yesterday / The last week / All time, grouping, Add Goal); tiles (last whole period's value, change on the one before, target, sparkline of a dozen periods, red only when off target); table (newest period first, green/red cells, N/A with nothing, dash before history, Hit column, name/target/hit columns stay fixed when scrolling sideways); hand-entered cells edited in a popover; expanding a metric into a row per person or per repo for flaky runs; editing from the row's context menu. All time syncs history back to the org's first issue.

## Weekly Digest and Standup notes
- Weekly Digest is the week as Markdown: delivery against the week before and goals, what shipped by investment category, notable PRs, CI, who's off next week; copy it, rewrite with Claude, or commit to the harness as digests/<date>.md. Standup notes commit as standups/<date>.md. Not documented.

## Investments
- Investments page: balance of effort by category, based on issues only. Controls in a bar: completed, in progress, Backlog (open at the range's end and not in progress) or All, each issue counted once; range (Last 30 or 90 days, this or last quarter, this year, all time from the org's first issue, custom dates); chart buckets (week, month, quarter, year for all time); clicking a bucket shows its breakdown; a category's issues list on the page. Not documented.
- Categories: rules over label, title, repository, issue type, milestone and a named board field; categorise by hand; Categorise in an issue's context menu and window; Assign to Categories queue (number keys for categories, arrows skip or go back, rule suggestion marked, GitHub-tracked choices collected until Review and Write). Partly in settings/org/investments.md.
- Tracking modes (In Gannin vs GitHub labels vs a single-select field on one board), the confirm-before-write step, missing labels created in the repo: check settings/org/investments.md covers it.
- Target share per category; the page flags categories more than ten points off target. Category colours are fixed per category; uncategorised is grey. Check settings/org/investments.md.

## CI (Delivery > CI)
- Metric definitions (success/failure, duration p50/p75/p90, run time, re-runs, flaky, default-branch health, needs attention): already in concepts/metrics-glossary.md (CI).
- Not documented: page structure (dashboard with tiles and changes, needs attention, run time by repo, runs and duration trends, repositories table, workflows by repository and by trigger; then repo, workflow, run and job pages); workflow page (p50/p75/p90 by week, every run's duration, example runs, default branch, jobs); run page (job timeline with wait for a runner, steps, earlier attempts); duration histogram buckets (60s, 5, 10, 20, 60 minutes, longer); run time stacked by repo, workflow or job (top seven and Others); failures drawn tall and as crosses, not colour alone.
- Only fetched once the page has been opened; Refresh then includes it. Jobs are fetched when a workflow is opened, all runs in the window or the latest N (Settings > Sync); a notice appears when the REST budget runs low. Check settings/app/sync.md.
- Runs older than 190 days are dropped; change figures show only when every repo's runs reach back far enough.

## Releases and milestones (Delivery > Releases)
- Read-only. Releases (first) and Milestones are picked in the toolbar. Not documented.
- Releases part: Repository menu (or click a repo in the table; click again for all), tiles (downloads with last 30 days once snapshots are that old, stars with last 30 days, releases, latest), Downloads over time, Downloads by release month, Stars (cumulative, releases marked as dashed rules), New stars by week (month once history passes six months), Repositories, Releases (downloads cell lists assets) and Stargazers tables (search, first 500, opens GitHub profile). Not documented.
- Download counts: GitHub only keeps running totals, so Gannin records one snapshot a day and history starts from first sync; Clear and sign-out keep it, only Erase Everything removes it. The website Download button and app updates count. Check concepts/where-things-are-kept.md and settings/app/storage.md.
- Covers non-archived repos pushed to in the last year; first star backfill stops at 10,000 stars. Fetched only once the page has been opened; interval in Settings > Sync.
- Milestones: same-title milestones across repos are grouped (counts added, soonest open due date); progress is closed of all issues and PRs; adds in progress and merged-PR counts; open first by due date (red overdue, orange within the week); Closed shown too on request. Milestone page: state, due date, progress, matched release (tag or name equals title, ignoring case and leading v), each repo's milestone, description, issues (in progress, open, closed with board status; may be fewer than GitHub's count). Release page: tag, dates, author, downloads, Latest / Pre-release / Draft, milestone shipped, assets with downloads, notes. Not documented.

## Dropped
- "In the spirit of Swarmia/Strety/Blacksmith/CodeRabbit" asides: history/inspiration, no code value.
- Plan and issue references (#69, #25, plans/...): history.
- Exhaustive lists of Dashboard overview view types and Scorecard tile layout code names (`ScorecardStanding`, `ScorecardHeadline.latest`, `TeamOverview`, `FlowOverview`, `AttentionOverview`, `PeopleStatsView`, `PullRequestSizes`, `SizeRiskSection`, `DeliveryExplanation`, `ScorecardResolution`, `ScorecardTiles`, `DueLabel`, `ReleaseUsage.StarBucket`, `InvestmentCategoriesSection`, `PercentileStat`, `RepoStats`, `DurationHistogram`, `WorkflowPage` etc.): findable by grep.
- "Chart colours are palette slots": kept briefly; Investments category colour detail compressed.
- Restatements of the Needs-attention list, stage definitions and Actions flags: duplicate of the glossary and of the rule's kept definitions.
- Reviewer-stats "Waiting now" explanation: kept only the `reviewRequestedAt` wiring.
- `MetricsWindowPicker`, `WorkloadTab.scorecard`, `WorkloadTab.releases`: trivially greppable.
