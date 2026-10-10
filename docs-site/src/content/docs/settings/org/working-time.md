---
title: Working Time settings
description: Every option in Org settings › Working Time, covering the working week, the holiday allowance, and people's dates and time off.
sidebar:
  order: 4
---

Org settings › Working Time says when people work and how much holiday they get. Open it with the cog beside the account menu in the sidebar's footer, then pick Working Time in the toolbar. The work log and threads shade days off, the punchcards count what falls outside working hours, and the Time off pages use the allowance.

These are all org-wide team files. An org with a harness keeps them in the home project's harness (the file is named in each table), and changes wait in the sidebar ("N changes to commit") until you review and commit them. An org with no harness keeps them on this Mac.

## Working week

Hours are in each person's own time, taken from their commits. Bank holidays come from date.nager.at, and only the country and year are sent.

| Option | Default | What it changes | Kept |
| --- | --- | --- | --- |
| Working days | Mon to Fri ticked | One checkbox for each day, Monday first. Ticked days count as working days. | Harness (`.gannin/working-week.json`) |
| Day starts | 09:00 | The hour the working day begins. | Harness (`.gannin/working-week.json`) |
| Day ends | 17:00 | The hour the working day ends. It is always after the start, so moving the start past it pushes it along. | Harness (`.gannin/working-week.json`) |
| Bank holidays | None | The country whose bank holidays are shaded and never counted as time off. When the country has regions, a Region picker appears beside it, with National holidays only as its first choice. | Harness (`.gannin/working-week.json`) |
| Reset to Monday to Friday, 09:00 - 17:00 | Not applied | Puts the days and hours back to the defaults, keeping your bank holiday choice. Shown only once the week differs from the default. | Harness (`.gannin/working-week.json`) |

## Holiday allowance

Allowances are in working days, with bank holidays on top. Each person's is pro-rated by the share of the leave year between their start and end dates and, for their own pattern, by working days a week, then rounded up to a half day.

| Option | Default | What it changes | Kept |
| --- | --- | --- | --- |
| Leave year starts | January | The month each leave year begins. | Harness (`.gannin/leave.json`) |
| Allowance | 25 days a year | The days a full-time person gets, The stepper holds it between 0 and 100 in half days; a number you type is not limited. | Harness (`.gannin/leave.json`) |
| Pro-rate for part-time patterns | On | Scales the allowance by working days a week for people with a working pattern of their own. | Harness (`.gannin/leave.json`) |
| This leave year | The current leave year's dates | Shows the dates of the leave year now under way. Read only. | Harness (`.gannin/leave.json`) |

## Dates and time off

This lists everyone who has dates or time off recorded, with a summary under each name. Time off can also be added by right-clicking someone on the work log, threads or punchcards. Dates and time off are kept in the home project's harness as `.gannin/people/<login>.json`, one file for each person, or on this Mac for an org with no harness. The pane's footnote says which.

| Option | Default | What it changes | Kept |
| --- | --- | --- | --- |
| Edit | Not applied | Opens a person's dates and time off in an editor sheet (described below). | Harness (`.gannin/people/<login>.json`) |
| Add Someone | Not applied | A menu of people with nothing recorded yet. Picking one opens their editor. | Harness (`.gannin/people/<login>.json`) |

## A person's dates and time off

The editor sheet has these sections. Each change applies at once and waits as a pending change. Done closes the sheet, and Open Profile jumps to the person's time off page.

| Option | Default | What it changes | Kept |
| --- | --- | --- | --- |
| Open Profile | Not applied | Closes the sheet and opens the person's time off calendar and report. | This Mac |
| Done | Not applied | Closes the sheet. | This Mac |
| Start date | Off | Turns on a first day. Days before it are dimmed on the timelines. A date picker appears when it is on. | Harness (`.gannin/people/<login>.json`) |
| End date | Off | Turns on a last day. Days after it are dimmed. A date picker appears when it is on. | Harness (`.gannin/people/<login>.json`) |
| Bank holidays | The org's (or None, if the org has none) | The person's own bank holiday country, and region where there is one. | Harness (`.gannin/people/<login>.json`) |
| Own allowance | Off | Gives the person a full-year allowance of their own, pro-rated for their start and end dates only. | Harness (`.gannin/people/<login>.json`) |
| Days a year | The org's allowance | Their own allowance. The stepper holds it between 0 and 100 in half days; a number you type is only held at 0 or above. Shown when Own allowance is on. | Harness (`.gannin/people/<login>.json`) |
| Carried over into (the leave year) | 0 | Days carried over into the current leave year, from -50 to 50 in half days. | Harness (`.gannin/people/<login>.json`) |
| Own working pattern | Off | Gives the person days and hours of their own (part time, or other hours on some days), starting from the org's week. | Harness (`.gannin/people/<login>.json`) |
| Hours a week | Worked out | Shows their hours against the org's, with the full-time equivalent. Read only. | Harness (`.gannin/people/<login>.json`) |
| Time zone | From their commits | Sets a time zone when their commits do not say (or say wrongly) where they are. | Harness (`.gannin/people/<login>.json`) |
| Add Holiday | Not applied | Starts a holiday entry in the time off sheet. | Harness (`.gannin/people/<login>.json`) |
| Add Sick | Not applied | Starts a sick entry in the time off sheet. | Harness (`.gannin/people/<login>.json`) |
| Approve | Not applied | Books a requested holiday. Shown only on requested ones. | Harness (`.gannin/people/<login>.json`) |
| Edit | Not applied | Opens an existing entry in the time off sheet. Double-clicking the row does the same. |
| Remove | Not applied | The minus button on a time off row. Removes the entry at once, without asking. | Harness (`.gannin/people/<login>.json`) |

The other lines in the sheet (Summary, Sick this year, Next time off, Next bank holiday, Allowance (leave year), Used, Org's working week) are read only. While Own working pattern is on, each day has a checkbox and a pair of start and end hours.

## Adding and editing time off

| Option | Default | What it changes | Kept |
| --- | --- | --- | --- |
| Person | The person you started from | Who the time off is for. Shown only when you add from the calendar. | Harness (`.gannin/people/<login>.json`) |
| Kind | Holiday or Sick, as you started | Whether it is a holiday or sick day. | Harness (`.gannin/people/<login>.json`) |
| First day | Today | The first day off. | Harness (`.gannin/people/<login>.json`) |
| Length | Full day | Full day, Morning, Afternoon or Longer. A half day counts 0.5. | Harness (`.gannin/people/<login>.json`) |
| Working days | 5 | For Longer: how many working days, from 2 to 260. Weekends, days outside their pattern and bank holidays are skipped. | Harness (`.gannin/people/<login>.json`) |
| Last day | Worked out | For Longer: the last day off. Read only. | Harness (`.gannin/people/<login>.json`) |
| Back on | Worked out | For Longer: the first working day after. Read only. | Harness (`.gannin/people/<login>.json`) |
| Note | Empty | An optional note shown with the entry. | Harness (`.gannin/people/<login>.json`) |
| Requested, not yet approved | Off | For holidays: marks it as requested, drawn pale and dashed until someone approves it. | Harness (`.gannin/people/<login>.json`) |
| Cancel | Not applied | Closes the sheet without saving. | This Mac |
| Add | Not applied | Saves a new entry. This button reads Save when you are editing one. | Harness (`.gannin/people/<login>.json`) |
| Save | Not applied | Saves changes to an existing entry. | Harness (`.gannin/people/<login>.json`) |
