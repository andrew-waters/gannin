---
type: plan
status: In progress
summary: First slice of Triage in Rituals, the priority scheme model and its team file (task andrew-waters/gannin#156), done on a scheduled run that couldn't fit the whole ritual.
issues: [andrew-waters/gannin#154, andrew-waters/gannin#156]
domains: [triage]
touches: [andrew-waters/gannin]
owner: andrew-waters
---

# Triage: the priority scheme

## Why this slice

andrew-waters/gannin#154 is the parent of eleven agreed tasks (#155 to #165) in
[Triage in Rituals](2026-10-10-a-new-triage-feature-in-rituals-the-idea.md). None had started. This run
had an hour, a budget, and no Mac to build on, so it takes one task that everything else stands on and
that unit tests can pin down: #156, the priority scheme model and team file (R1, R4).

#155 (extracting a shared `TrackedValue` from investments) is the other foundation, but it's a refactor
of working write code, and that's better done where it can be built and tried. So the scheme has its own
small `PriorityTracking` (labels, or a board field) for now; #155 can fold it into `TrackedValue`.

## Approach

- `Gannin/Triage/PriorityScheme.swift`: `PriorityBucket` (name, colour slot, `githubValue`),
  `PriorityTracking` (labels, or a single-select field on one board), `PriorityScheme` (ordered buckets,
  tracking, `lastPass`), all decoded leniently so a hand-edited file still loads.
- `PriorityScheme.reading(_:)` gives a `PriorityReading`: untriaged (no bucket's label or option), a
  bucket, or conflicting (labels of more than one bucket, in scheme order). Matching ignores case, and an
  empty value never matches.
- `.gannin/triage.json` as a project team file (`TeamFile.triage`), on `OrgConfig.priorityScheme`, laid
  on per project and cleared from the base config as recap is, so edits stage with the other pending
  harness changes.

## Tasks

- [x] Model, reading and lenient decoding
- [x] Team file, `OrgConfig` and the harness tour
- [x] Unit tests: decoding, keys sorted, by label, by field, untriaged, conflicting
- [ ] Build and run the tests on a Mac (not possible on this run)
- [ ] The rest of #154's tasks: #155, #157 to #165
