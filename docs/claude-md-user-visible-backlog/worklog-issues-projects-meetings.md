# User-visible backlog: work log, issues, projects, views, planning, meetings

Source: CLAUDE.md lines 592-788 and 1603-1672. The docs site (`docs-site/src/content/docs/`) has no page for any of these features; the only overlap is `settings/org/working-time.md` (working week, bank holidays, allowance, people's dates and time off, where they're kept), noted below.

## Activity (People > Activity)
- Tabs: Work log, Threads, Punchcards, sharing one scale and page.
- Work log: people by day (14 per page) or week (12 per page), paging back up to a year. Each cell is a packed cluster of dots (commits, reviews, PRs opened, PRs merged); commit dots grow with lines changed. Starts with 28 days.
- Threads: each person's authored PRs as bars from first commit to merge (or now while open), packed into rows, with their reviews of others' PRs on a line beneath.
- Punchcards: weekday by hour per person in their own time, also by a single Day. Work log and Threads offer Days and Weeks only.
- Work log and threads shade days off, tint time off and dim days before a start or after an end. Punchcards shade working hours and count what falls outside, plus working days off and activity on them. Right-click a person to add time off. (Working week shading: already in settings/org/working-time.md.)

## Standup (People > Standup)
- Everyone's activity on one day: the last working day by default (Friday on a Monday). Today previews today so far; arrows step through working days up to today.
- Toolbar control: By Person, Team or Changelog.
- By Person: a row each with counts and icon legend, a day strip on one hour axis for everyone (6:00 to 22:00 at most, working hours shaded), then a timeline (time, icon on a rail, title with context). Runs of commits on one PR are one item, unfolded with a chevron or the Commits toggle; a merge lists the issues it closes.
- Team: everyone's items on one timeline with avatars, under the team's counts and one strip. People off or with nothing recorded are listed at the end.
- Changelog: issues closed that day, completed ones by investment category, then those closed as not planned.

## Time off and holiday allowance
- Already in settings/org/working-time.md: org working week, bank holiday country and region, per-person overrides, where it's stored. Check that page also covers the rest below.
- Person view Time off part (Work or Time off): Calendar, Report (allowance tiles, holiday and sick by month, the year's entries, past leave years) and Details (where they're edited).
- Time off (under People): calendar of everyone's booked time off or one person's, by Year (mini months tinted by how many are off; click a day for its week), Month (names on each day) or Week (people by day). Month and Week draw time off as continuous bars (weekends included, stacked; click one to edit) under the bank holidays of regions ticked in the Bank Holidays menu. Click picks a day, Shift-click a run (in week view within one person's row); Add Time Off or right-click opens the sheet. Esc clears days (already in keyboard-shortcuts.md).
- Add/edit sheet: kind (holiday or sick), first day, then Full day, Morning, Afternoon or Longer (a number of working days; the last day is worked out). Half days are single days and count 0.5, tinting half the cell. Only working days count.
- Holiday allowance: org policy (leave year start month, days a year, part-time pro-rating) plus a person's own allowance and carry-over per leave year. Pro-rated by the share of the leave year between start and end dates, and by working days a week over the org's for an own pattern; rounded up to half a day; counts holiday taken (to today), booked, sick days and spells. Allowance tab of Time off tables it by leave year.
- Holiday requests: drawn pale and dashed, Approve in the row and context menu; committed like any other change.
- A person can have their own working pattern (hours per day, shown as FTE against the org's) and time zone, set in their Time off; punchcards then use their hours and zone instead of commit offsets.
- Bank holidays are shaded and labelled but never counted as time off, and are out of hours on punchcards.

## Issues pages and filters
- Issues page: issue metrics, with a search over its In progress now list. In progress now can order by a board field (remembered per org); issues not on the chosen board say so rather than being hidden.
- Issues > All: a table of every open issue and those closed since the window's start (title, repository, number, author, assignees, labels, linked PRs, opened, closed), sortable columns remembered; sub-issues fold under their parent when listed, flat while searching or filtering. Issues > Not on a board: issues on no board (or not on a chosen one, starting from the investments board), open, closed or all.
- Filter bar (also on Pull Requests, with its own set): search (every word must match title, repo, number, a person's login or name, or a label); Assignee (Me, Anyone assigned, Unassigned, people), Repository, Label, Field (submenu per board field, values in board order, plus No value; only once an issue is on a board), Milestone (No Milestone first; only once an issue has one), with counts; Open, Closed or All. Not on a board puts its board picker first. Filters are kept per window.
- Pull Requests filter bar: search, Author and Reviewer (Me first, No Reviewer), Status (draft, needs review, changes requested, approved, merged), Repository, Open/Merged/All. Files and Size columns show changed files and lines added/removed.
- Not on a board: select issues and add them to a board in bulk (confirm, each ticked off, open until Done).
- Issue workflow (Settings): picks the board and which statuses count as in progress, and whether to fall back to the first linked PR. Cycle time is time in those statuses (clock stops on other status or close, restarts on return); lead time is created to closed as completed; flow efficiency is the share of in-progress days with linked PR activity; scope creep is the share of sub-issues added after work started.
- Outside repos named by a project join the issue history; pages that include them vs. not (Issue flow, Investments, Recap, Scorecards, Standup, Weekly Digest Shipped list show a notice instead).
- Markdown in issues and PRs: blockquotes and GitHub alerts as callouts, `<details>` folds, basic HTML tags rendered, others dropped keeping their text, `---` a rule.

## New Issue
- Opens with Cmd-N (File > New Issue; New Window is Option-Cmd-N), New Issue in the toolbar of issue pages, Inbox, Epics, Prioritisation, Board Hygiene, Views and Boards, a + on each board column (column value preset), and New Sub-issue in an issue's context menu and drawer. The new issue opens in a drawer.
- Two columns: left an issue in a repo or a draft item on the board, the repo (the project's first), issue templates (`.github/ISSUE_TEMPLATE`), title, description, Draft with Claude (conversation revising the draft, harness skills about issues ticked to start); right the board (workflow board by default) and its settable fields, assignees, labels, parent, Images. Create Another keeps the sheet open.
- Images: GitHub has no attachment upload, so they're committed to the harness covering the repo and linked; visible inline only to people who can read the harness (the sheet warns about sensitive data). PNG, JPEG, GIF, WebP kept; others become PNG; over 5 MB becomes JPEG when that fits. Drop, paste (Cmd-V with only pictures on the clipboard) or add. Each adds a placeholder to the end of the description that you can move. The Create button names them ("Commit 2 Images and Create Issue"), which is the confirmation. A retry after GitHub refuses the issue doesn't recommit. No harness means no images.

## Boards (Projects)
- Sidebar lists the org's open boards. A board page shows its saved views as tabs, each with its own filter, layout, grouping (table sections or board swimlanes), columns, sort, visible fields. Changes there are local, never saved back. Layouts: Table, Board (columns in option order with GitHub's colours), Insights (time in each status), Roadmap shows as a table.
- Boards landing page (before a board is picked) stands in for a repo's Projects tab: the org's boards, or those linked to the repo if the project sets one; search and Open/Closed tabs. New Board (new, or copy fields and views of another, and link to a repo); Link Board, Unlink, Close, Reopen are confirmed first.
- Refreshed after the boards' interval (Settings > Sync).

## Views (Planning)
- Gannin's own views of issues, not a copy of GitHub's: a board (or every stored issue), a state, filters, any number of dimensions (board fields, issue attributes, Attention, Time in status), layout (Outline, Board, Table, Grid, Aging), measure (count, median time in status or in progress), order, fields on cards.
- Attention flags: quiet in progress, PR merged not done, in review with no open PR, done but open, closed not done.
- Writes always confirmed: Set Field on a selection, dragging cards between columns and lanes, Fill In (a queue through issues missing a field).
- Board Fields editor: change a board's fields (names; select options added, renamed, recoloured, described, reordered, removed). Iterations are read-only. Changes reviewed first. Multi-select values can be read but not written.

## Board Hygiene and Epics
- Board Hygiene lists issues by Attention flag with fixes ticked and written together: Done on the workflow board for "PR merged, not done" and "Closed, not done"; close the issue for "Done, still open".
- Epics: issues with sub-issues: progress, in progress, plans, PRs, last movement (quiet after two weeks).
- Draft Issues (on a plan or requirement): Claude breaks it into issues to edit, then makes them as sub-issues of the issue it's about (or a new parent) on the workflow board. Plan with Claude starts a planning session.

## Prioritisation (Meetings)
- Bar: search and which of the board's date fields is the committed date (`Committed` by default). Sections: Triage (open issues with no Status on the workflow board or not on it, newest first); From the field (points raised in the meeting, ticked off when dealt with, open ones carry over); open issues with the committed date set, soonest first, red once overdue, orange within the week. Issues open in the drawer.
- Capture panel: text, who (remembered), customer, kind, urgency; Cmd-Return to add. Notes link to an issue or are raised as one (Write Issue: Claude drafts repo, title, description, labels, images to attach, then creates it and puts it on the board for triage).

## Recap (Rituals > Recap)
- Issues closed over the team's period (default two weeks from Monday 5 January 2026), cadence set from the toolbar's popover. Opens on the last whole period; arrows, Last, This.
- Groups completed issues by investment category, person, repository or parent; then closed as not planned; header compares to the period before. Person menu (Me, Unassigned, whoever closed something) narrows list, counts and notes.
- Speech: Claude writes the notes as a casual spoken update (themes, first names, no numbers; first person when one person is picked; about a minute or two to three), with anything to work in. Notes: the period as Markdown, committed as `recaps/<start>.md`.

## Triage
- Triage with Claude: suggests board fields, investment category and whether an issue suits an agent, for ticking and writing.
- Priority scheme (project's ordered buckets, kept on GitHub as labels or a single-select field): defined, but the Triage page, queue and editor are not built yet.

## Dropped
- Issue/plan references (#122, #156, #154, #205, plans/...): history.
- `StandupChangelog` name: type doesn't exist (it's `StandupLayout.changelog`); described only.
- "Standup (`StandupView`, as before)" and Meetings intro wording: narration.
- Lists of sidebar placement, toolbar vs bar placement, legend/icon types (`StandupLegend`, `StandupItem`, `StandupTimelineList`, `TimelineMark`, `PersonColumn`, `TimeOffPage`, `PersonLeaveReport` etc.): derivable by grep.
- Exhaustive filter/column lists in code form: kept only in the user notes above.
- "all share `PersonDatesSections`" kept in rule; `WorkPatternSection`, `LeaveReportView` names dropped as greppable.
- `isEmbedded`-style and menu wiring detail for New Issue entry points (`HideableRow`, `NewIssueAction` context kept): partly dropped as greppable.
