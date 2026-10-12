---
title: Time off
description: Book holiday and sick days, see everyone's calendar, and track holiday allowance.
sidebar:
  order: 22
---

Team › Time off is a calendar of everyone's booked time off. A person's own page has the same under its Time off part, with Calendar, Report and Details.

## Where it's kept

Dates and time off are entered by hand. With a harness they're kept in the home project's harness, one file for each person, and appear in the sidebar as "N changes to commit" until you review and commit them. An org with no harness keeps them on this device only. See [Projects and harnesses](/docs/concepts/projects-and-harnesses/).

## The calendar

Pick one person with the Person menu, or leave it on everyone. Views are Year, Month and Week.

- **Year**: small months tinted by how many people are off. Click a day to see its week.
- **Month**: names on each day. Time off is drawn as continuous bars, weekends included, and clicking one edits it.
- **Week**: people by day, marked as the work log marks them.

Bank holidays show under the bars for the regions ticked in the Bank Holidays menu, which lists the org's region and anyone's own. They're shaded and labelled but never counted as time off.

Click a day to pick it, or Shift-click to pick a run of days (in Week, within one person's row). Add Time Off, or right-click, opens the time off sheet for those days.

## Adding time off

The sheet asks for the person (when you add from the calendar), the Kind (Holiday or Sick), the First day, and the Length.

- **Full day**, **Morning** or **Afternoon**: a single day. A half day counts 0.5 and tints half the cell.
- **Longer**: a number of working days. Gannin works out the last day, and the day they're back, skipping weekends, days off in their pattern and bank holidays.

Add a Note if you want one. For a holiday, tick Requested, not yet approved to make it a request: it's drawn pale and dashed until someone chooses Approve in its row or context menu. Approving is committed like any other change.

Only working days count towards totals and tints.

## Holiday allowance

The org sets the leave year's start month, the days a year and whether part-time patterns are pro-rated in [Working Time settings](/docs/settings/org/working-time/). A person can have an allowance of their own and days carried over into a leave year, set in their Details (Dates and Time Off).

A person's allowance is pro-rated by the share of the leave year between their start and end dates, and, if they have their own working pattern, by working days a week against the org's. It's rounded up to a half day, and any carry-over is added.

The Allowance tab beside the calendar has a table by leave year: holiday taken (to today), holiday booked, sick days and spells. A person's Report shows allowance tiles, holiday and sick by month, the year's entries and past leave years.

## Working pattern and time zone

In a person's Details you can give them their own working pattern (days and hours, for part time or other hours) and a time zone. The pattern is shown against the org's week as a full-time equivalent. The work log and threads use it for shading, and punchcards use their hours and time zone.
