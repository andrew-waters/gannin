---
paths:
  - "Gannin/Sessions/Planning*"
---

# Planning sessions

- The current stage is the `phase` claude writes into `planning.json` (`PlanningState.phase`), not something Gannin tracks, so claude can move stages itself. Read it leniently; never crash or drop state on an unknown value.
- `.worktrees/<branch>/planning.json` is snake case. Update `PlanningState.instructions` (told to claude after the team's guidance) whenever its shape changes.
- Every task must name the criteria it `satisfies`; Agree must surface criteria no task covers (`PlanningState.uncovered`).
- Moving back reopens a stage and marks later ones Recheck; moving forward approves the stages passed. Send claude the reason when going back.
- Copy context documents into `.worktrees/<branch>/docs/` before claude starts (`SessionStore.copyDocuments`).
- Agree must commit the plan and requirement in one commit, with `agreed_by` front matter, and create the parent and sub-issues first.
- A dropped or picked document is shared with claude only after confirmation, and may go in `plans/assets/<slug>/` only if the user separately allowed committing it.
- Saving the editable prompt commits it as a planning prompt before the session starts.

## Testing
- No tests cover planning (`PlanningState`, stages, Agree). Add tests for lenient decoding if you change it.
