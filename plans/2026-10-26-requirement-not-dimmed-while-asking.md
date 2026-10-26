---
type: plan
status: In Review
summary: The requirement pane of a planning session stays at full opacity while a question is open; only the stage beside the question dims.
issues: [andrew-waters/gannin#513]
domains: [planning]
touches: [andrew-waters/gannin]
owner: andrew-waters
---

# Requirement pane not dimmed while a question is open

## Context

`PlanningWorkspaceView` applied `dimmedWhileAsking` to both the stage column and the Requirements
pane, fading each to 25% while Claude's question was open. The pane is what the room reads to answer
the question, and the overlay that lifts the dim also swallowed clicks on its content.

The issue's wording ("assignments") appears nowhere in the code. The reporter confirmed it means
the Requirements pane, and the issue now says so.

## Decisions

- Dim only the stage column, which is what the question replaces.
- Leave the Requirements pane at full opacity at all times.
- The stage column's dim is intended, and stays: while a question is open, fading the stage under
  way (including Tasks) keeps the room on the question. Clicking it lifts the dim for that
  question, and it isn't dimmed at all when looking back at an earlier stage (`isLookingBack`).
  The Requirements pane is different because it is reference material for answering the question,
  not the thing being replaced by it.

## Tasks

- [x] Remove `dimmedWhileAsking` from the Requirements pane
- [x] Update `docs-site/.../agents/planning.md`
- [x] Changelog line under Fixed
