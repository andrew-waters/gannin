---
paths:
  - "Gannin/Meetings/**"
  - "Gannin/Triage/**"
---

# Meetings and Triage

- Committed date field: `OrgConfig.committedDateField` (team file `.gannin/prioritisation.json`) or the project's own `RepoProject.committedDateField`.
- From the field notes: `FieldNotesStore`, per project, team file `.gannin/field-notes.json`, read through the window's `FieldNotesStore.scoped`.
- Recap cadence (`RecapCadence`): `OrgConfig.recap`, team file `.gannin/recap.json` or the project's own. Notes commit as `recaps/<start>.md`. `recapPeople` is per window. Speech output is kept in memory only, per period, people and length.
- Triage priority scheme (`Triage/PriorityScheme.swift`): `PriorityScheme` is the project's ordered `PriorityBucket`s (name, colour slot, `githubValue`), tracked on GitHub as labels or a single-select field on one board (`PriorityTracking`), with `lastPass`. Team file `.gannin/triage.json` (`OrgConfig.priorityScheme`), read leniently. `reading(_:)` returns `PriorityReading`: none is untriaged, two buckets' labels conflict. Triage page, queue and editor don't exist yet.
- `WriteIssueSheet` (from field notes): `createIssue` then onto the board for triage. `TriageWithClaudeSheet` writes through `FieldWriteSheet`.
