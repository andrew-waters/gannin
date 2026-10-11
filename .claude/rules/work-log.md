---
paths:
  - "Gannin/WorkLog/**"
---

# Work log, Standup, time off

- `WorkLogStore` fetches only once the People page (Activity or Standup) has been opened for an org; Refresh includes it from then on. Missing weeks are week-long "last updated" searches, four at a time, then a changes search. Commits are capped at the last 100 per PR.
- `WorkLogHistory.version` (`WorkLogModels.swift`): bump it when a field is added (as for `closedAt` and commit offsets) so old caches are discarded and refetched.
- Attribution: commits count for their GitHub author when the email is linked, else the PR author. Issue opened counts for `IssueRecord.author` (optional so older records load). Issue moves and closes count for the assignees, since GitHub doesn't say who did them.
- Threads show authored PRs only: "Update branch" and merges from main put others' commits on a PR.
- Commit time uses the offset from its git timestamp (`GitTimestamp`); other events use the person's most common commit offset. A person's time zone (`PersonDates.timeZone`) overrides both for every event. Merges are left out of punchcards (merge queues land them whenever CI finishes).
- Weeks always start on Monday.
- Standup needs `WorkLogCommit.message` and `WorkLogPullRequest.closingIssues`. Its Changelog layout (`StandupLayout.changelog`) comes from the issue history alone, categorised by `InvestmentConfig.categorise`, and shares `ClosedIssuesList` with Recap.
- Standup excludes outside-repo issues via `OrgConfig.excludesForIssueHistoryPages`, which never lets an outside repo through, so `outsideReposNotice` stays accurate.
- People's dates (`PeopleDatesStore`, per org and login) live in the home project's harness (`.gannin/people/<login>.json`), or on this device for an org with none. All the views share `PersonDatesSections`.
- `WorkingCalendar` = a person's working week (`PersonDates.workWeek`, `WorkWeek.dayHours`) less bank holidays, combined in `PeopleDatesStore.workingCalendar`. Bank holidays are shaded and labelled but never counted as time off, and count as out of hours on punchcards. Time-off counts and tints cover working days only.
- `BankHolidayStore` fetches from date.nager.at; only country and year are sent. Cached in Application Support. Org region is `WorkWeek.holidays`; a person overrides with `PersonDates.holidayRegion`.
- `Absence.half` (morning or afternoon) is for single days only and counts 0.5. `AbsenceSheet` works out the last day of a "Longer" absence from the person's `WorkingCalendar`.
- `Absence.approval` (holiday only): requested time off is drawn pale and dashed; approving commits like any other change.
- `LeaveSummary` (`Leave.swift`) pro-rates by the share of the leave year between start and end dates, and for an own pattern scales by working days over the org's; rounds up to a half day, adds carry-over (`carryOver` by leave year), and counts holiday taken (to today), booked, and sick days and spells.
- Time-off calendar (`TimeOffCalendarView`): bars come from `TimeOffSpans` (weekends included, stacked in lanes). Hidden holiday regions are in `timeOffHiddenHolidayRegions`.
