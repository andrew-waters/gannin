---
type: plan
status: In Review
summary: An org with a harness always keeps its team data there, the scorecard included, with the committed date field and field notes added; Move to Harness is gone.
issues: [andrew-waters/gannin#39]
domains: [harness, metrics, meetings]
touches: [andrew-waters/gannin]
owner: andrew-waters
---

# Team data in the harness by default

## Context

The scorecard already had a team file (`.gannin/scorecard.json`), as did goals, recap cadence,
projects, views, investments, the workflow, working week, leave, exclusions, authoring prompts and
people's dates. But an org only read them from the harness after someone clicked Settings >
Harness > Move to Harness. Until then everything stayed on the Mac it was entered on, and nothing
in the app said so. So one person's scorecard edits never reached anyone else.

## Decisions

- No option and no migration: an org with a harness keeps its team data there from the start
  (`HarnessTeamStore.keepsData` is just "has a harness"). A missing file is the default, and so is
  an index that hasn't loaded yet. What was entered on this Mac before is left where it is and no
  longer read. Move to Harness, `moveIn`, `allFiles` and `PeopleDatesStore.own(in:)` are gone.
- Changes flow as before: applied at once, pending in the sidebar, committed together after
  review, merged three ways onto the harness's copy (lists by `id`, objects by key, ours winning a
  clash). Scorecard values are keyed by period, so two people entering different weeks both
  survive. Others see a change when their harness index is next fetched.
- The committed date field (Prioritisation) was a per-Mac `UserDefaults` key. It's now
  `OrgConfig.committedDateField` in `.gannin/prioritisation.json`; a project's own is unchanged.
- Field notes (Prioritisation's From the field) are `.gannin/field-notes.json`, a list by `id`,
  so notes several people add in the same meeting merge.
- Kept on each Mac on purpose: stars, hidden items, Inbox sections, auto review, saved prompt
  snippets (the team's prompts are already in the harness), sort and view preferences, caches.

## Tasks

- [x] Team data is the harness's whenever the org has one, with no index needed to edit
- [x] Remove Move to Harness; Settings > Harness says what's kept there
- [x] Committed date field as team data
- [x] Field notes as team data
- [x] CLAUDE.md
