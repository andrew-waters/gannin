---
paths:
  - "Gannin/Meetings/**"
  - "Gannin/Triage/**"
---

# Meetings and Triage

- Keep team-file paths stable, others read them: `.gannin/prioritisation.json` (committed date field), `.gannin/field-notes.json`, `.gannin/recap.json`, `.gannin/triage.json`; recaps commit as `recaps/<start>.md`.
- Read `PriorityScheme` leniently: a bad entry must not lose the file.
- Treat two buckets' labels on one issue as a conflict (`PriorityReading`), not as the first bucket.
- Write every GitHub change through a confirmation sheet (`FieldWriteSheet`).
- Keep Recap speech in memory only.

## Testing
- `PrioritySchemeTests.swift` covers `PriorityScheme`. Prioritisation, Recap and field notes have no tests; check by hand.
