---
paths:
  - "Gannin/Sessions/Planning*"
---

# Planning sessions

- A planning session is `CodeSession.planning` (`PlanningInfo`); the New Plan tab is `NewPlanningView` over a `PlanningDraft` held in `SessionStore.planningDrafts` (not kept across launches; `replaceDraft` swaps the session in). Delete uses `SessionStore.finish` (Delete Anyway when the folder won't go).
- The editable prompt is what the session is told (as the choice's note). Saving commits it as a planning prompt (new, or an update of the one it came from) before the session starts.
- Stages are `PlanningStep`: Context, Requirements (`Criterion` with ids), Design, Tasks (each lists criteria it `satisfies`; `PlanningState.uncovered` = criteria no task covers), then Agree. The current stage is the `phase` claude writes (`PlanningState.step`).
- Moving forward approves the stages passed; moving back reopens one and marks later ones Recheck (`PlanningInfo.moved`, `stageRounds`, `approved`, `recheck`). Back sends a reason to claude.
- Claude keeps `.worktrees/<branch>/planning.json` (`PlanningState`, snake case, read leniently; shape and rules in `PlanningState.instructions`, appended after the team's guidance). It is re-read on every `changed` signal and held as `PlanningInfo.state`.
- Context: documents are copied into `.worktrees/<branch>/docs/` before claude starts (`SessionStore.copyDocuments`), briefed by `SessionStore.contextBrief`; links via `PlanningLink.parse`, places to look in `PlanningInfo.sources`.
- Questions: AskUserQuestion renders as `PlanningQuestionView`; style is `planningQuestionStyle` (Mac-local). Several questions are put one by one and answered together.
- `SessionStore.interject` sends "From the room" (closing any open question first) and stores it in `PlanningInfo.comments`. Dismissed findings: `PlanningInfo.dismissed`. The terminal/composer is a drawer (`planningShowsTerminal`); the tab starts claude itself.
- Agree (`PlanningAgreeSheet`): creates the parent (planned issue, or a new one) and sub-issues on the workflow board, then commits plan (`PlanningDocuments`, front matter `agreed_by`) and requirement in one commit, records `PlanningInfo.agreed`, tells claude.
- Documents dropped or picked are each confirmed in `ShareDocumentsSheet` (share, and separately may-be-committed), copied to `.worktrees/plan-<slug>/docs/` (Word/RTF also as a textutil `.txt`); claude is told which may go in `plans/assets/<slug>/`.
