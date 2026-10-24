---
type: plan
status: Done
summary: Standup becomes a ritual run on a shared screen, in the style each team picks. Walk the Board goes through the workflow board column by column (Done and needs discussion, In review, In progress, Triage), Person by Person shows each person's tickets by stage with their day, Changelog stays, and Written posts it as Markdown. Present steps through one column or person at a time.
issues: [andrew-waters/gannin#504]
domains: [standup, rituals, harness]
touches: [andrew-waters/gannin]
owner: andrew-waters
---

# Standup: shareable morning views, a style per team

## Context

Rituals › Standup (`Gannin/WorkLog/StandupView.swift`) showed what each person did on one day,
in three layouts (By Person, Team, Changelog), with Notes to copy or commit. It answered "what
happened yesterday", but not the standup many teams run each morning round a shared screen, where
they walk the board: what's done and needs discussing, what's in review, what's in progress, and
what needs triage. Teams don't all run standup the same way, so it needs more than one style.

Prioritisation (`Meetings/PrioritisationView.swift`) already has a Present toggle and a Triage
list (open, on the workflow board or not, with no Status), and each project keeps its ritual
settings in its harness (`.gannin/prioritisation.json`, `recap.json`, `triage.json`).

## Decisions

These came from questions answered on 24 October 2026.

- **A team is a project.** Its standup settings are a team file in its harness,
  `.gannin/standup.json` (`StandupConfig`): the style it opens on, a stage per board Status, and
  the discussion label. Read leniently, so an unknown style or stage reads as the default.
- **"Needs discussion" is a GitHub label**, "needs discussion" unless the team names another.
  Everyone sees it on GitHub too. Open issues with it are listed first under Done and needs
  discussion, and stay in their own column with a mark, so Triage still matches Prioritisation.
  Needs Discussion and Discussed in an issue's menu add or remove it, after a confirmation, like
  every GitHub write; the label is created in the repo if it's missing.
- **Columns are mapped per project, in Settings.** Org settings › Issues › Standup columns has a
  stage for each Status option on the Issue workflow board: Done, In review, In progress or Not
  shown. Until picked, each is guessed from its name (done-like names, then "review", then the
  issue workflow's in-progress statuses or "progress"). No Status is always Triage.
- **Date range.** In review, In progress and Triage are the board as it is now. Done is what was
  completed, or moved to a done status, since the start of the day picked (the last working day
  by default).
- **Triage is shared.** `TriageQueue` (`Meetings/TriageQueue.swift`) is the one place the triage
  issues are worked out, for Prioritisation's list and count and Standup's column.
- **Shareable means Present plus stepping.** Present makes the page larger and shows one board
  column, or one person, at a time; the arrow keys and toolbar buttons step, the header's dots
  jump, Esc stops. Notes (copy, rewrite with Claude, commit as `standups/<date>.md`) stays the
  written export. No links or file exports.
- **Style is per project, switchable on the day.** Settings sets the style Standup opens on; the
  toolbar's Style menu picks another for that standup without saving it.

### Styles and what carried over

| Style | What it is | From the old view |
| --- | --- | --- |
| Walk the Board | The workflow board's four columns, side by side, or one at a time presenting | New |
| Person by Person | Each person's tickets by stage, then their day strip and timeline | By Person, with tickets added |
| Changelog | Issues closed that day by investment category | Changelog, unchanged |
| Written | Each person's day and tickets in flight as Markdown, then to discuss and the triage count | Notes, shown on the page |

The **Team** layout (everyone on one timeline) is dropped: Person by Person covers it, and a
single merged timeline doesn't suit walking through the team. **Notes** stays in the toolbar on
every style but Changelog, and now includes tickets in flight.

### Later

- **Blockers first**: only items that are blocked, stale, or waiting long on review, for a short
  standup. Needs a definition of blocked (a label or field per team, like the discussion label)
  and of stale.
- **Goal or sprint progress**: items grouped by the current iteration, milestone or initiative,
  showing what moved towards it. The board's iteration field is the likely source.

## Tasks

- [x] `StandupConfig` and `standup.json` as a project team file, read leniently
- [x] `StandupBoard`: stage guessing, the four columns, discussion, narrowing to a person
- [x] `TriageQueue`, shared by Prioritisation's Triage list and count and Standup
- [x] Walk the Board, Person by Person and Written styles; Team layout dropped
- [x] Present with stepping, keys, toolbar buttons and dots
- [x] Needs Discussion and Discussed, confirmed before writing the label
- [x] Org settings › Issues › Standup and Standup columns
- [x] Tests: `StandupStagesTests.swift`
- [x] Docs: `guides/standup` rewritten; `guides/app-tour`, `guides/prioritisation`, `guides/weekly-digest`, `settings/org/issues`, `settings/org/harness`, `concepts/where-things-are-kept`
- [x] CHANGELOG and rules
