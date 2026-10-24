---
type: plan
status: Done
summary: New Issue opens on Claude, with the conversation on the left and a read-only preview of the draft on the right, then moves to today's form, filled from the draft, to check the details and create it.
issues: [andrew-waters/gannin#500]
domains: [issues]
touches: [andrew-waters/gannin]
owner: andrew-waters
---

# New Issue: Claude first, then confirm

## Context

Draft with Claude was the last section of the New Issue sheet, below an empty form, and most
issues start as a rough line. The sheet is `Gannin/Issues/NewIssue.swift` (`NewIssueSheet`).

## Decisions

- **Two steps over one state.** Both steps edit the same `@State`, so Back keeps the form's edits,
  and the next revision improves on them (the draft prompt already sends what's written).
- **Claude step pickers**: Make, Repository, Board and Template, with Skills by the Ask field:
  everything that shapes the draft. The form keeps them too, on the same bindings.
- **Images on both steps**, one image set; their placeholders live in the description either way.
- **Escape**: Back on the form, and Cancel on the Claude step only while nothing's been asked or
  written (Cancel leaves the cancellation placement otherwise, as that gives Escape by itself), so it
  never throws a draft away. The Cancel button always closes. Create Another returns to the Claude step with the conversation cleared and
  the repo, board and parent kept.
- Nothing is written to GitHub before Create, as before.

## Tasks

- [x] Split `NewIssueSheet` into the Claude step (conversation, composer, preview) and the Confirm step
- [x] Toolbar per step: Cancel and Skip/Next; Back, Cancel, Create Another and Create
- [x] Docs: `guides/new-issue.md` (the other pages that say Draft with Claude are about other editors)
- [x] CHANGELOG
- [x] Review round 1: Escape only cancels a blank sheet, a note of what Create Another made, wrapping labels, the latest reply scrolled to, template footers, the shortcuts page
- [x] Review round 2: Cancel leaves the cancellation placement once there's a draft
- [x] New Issue in the Claude Code window: the + menu tile and ⌘N
