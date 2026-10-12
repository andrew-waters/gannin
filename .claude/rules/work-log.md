---
paths:
  - "Gannin/WorkLog/**"
---

# Work log, Standup, time off

- Must bump `WorkLogHistory.version` when adding a field to cached work-log models, or old caches keep decoding without it. Not for a field whose absence only means "fetch again" (`WorkLogPullRequest.updatedAt`, which the change feed compares): bumping would refetch every week for nothing.
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
- `OutsideRepoTests.swift` covers outside-repo exclusion. Work log, leave and calendar logic have no tests; check by hand, including a cache from before a field was added.
