---
paths:
  - "Gannin/WorkLog/**"
---

# Work log, Standup, time off

- The work log's PRs are kept in `PullRequestStore` (see fetching), so a field added to `WorkLogPullRequest` must also go in `WorkLogExtras` or the core, or it's lost on reload.
- Must bump `WorkLogHistory.version` when adding a field to cached work-log models, or old caches keep decoding without it. Not for a field whose absence only means "fetch again" (`WorkLogPullRequest.updatedAt`, which the change feed compares): bumping would refetch every week for nothing.
- Keep the work log's issues step failing on its own: a failed issue search must still save the PRs and leave `coveredFrom` and `fetchedAt` where they were (a new log covers nothing), or those weeks never get their issues.
- The work log's issues are kept in `SharedIssueStore` (a `workLog` slot with the comments), so a field added to `WorkLogIssue` must also go in `WorkLogIssueExtras` or the core, or it's lost on reload. The log's file keeps only coverage and `storedIssueCount`.
- Keep reading an issue's assignees and labels (as names) in the work log fetch: `IssueCore.merged` lets a newer incoming core replace both lists, so a fetch without them would empty what the workload saved.
- Issues come from the change feed (`issueFeedPlan`) and fall back to `workLogIssueSearch` when it can't say. A weekly issue search whose count reaches `ParallelSearches.searchCap` is re-run a day at a time (`splittingCapped`), or the cap drops issues.
- Keep newly added fields optional (as `IssueRecord.author`) so older records still load.
- Fetch only once the People page has been opened for an org.
- Attribute commits to the GitHub author when the email is linked, else the PR author. GitHub doesn't say who moved or closed an issue, so those count for the assignees.
- Show authored PRs only in Threads: "Update branch" and merges from main add others' commits.
- Leave merges out of punchcards: merge queues land them whenever CI finishes.
- Always start weeks on Monday.
- Never let an outside repo through `OrgConfig.excludesForIssueHistoryPages`, or `outsideReposNotice` becomes wrong.
- Never count bank holidays as time off; count them as out of hours. Time-off counts and tints cover working days only (`WorkingCalendar`).
- Send only country and year to date.nager.at (`BankHolidayStore`).
- Keep people's dates in the home project's harness (`.gannin/people/<login>.json`), or on this device for an org with none.
- `Absence.half` is for single days only. `Absence.approval` applies to holiday only.

## Testing
- `OutsideRepoTests.swift` covers outside-repo exclusion; `WorkLogIssuesTests.swift` covers issue events, the work log filter and the grid; `WorkLogIssueStoreTests.swift` covers the issue slot, the version 5 migration, the issue feed plan and the capped-week split. Leave and calendar logic have no tests; check by hand, including a cache from before a field was added.
