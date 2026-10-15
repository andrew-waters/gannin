---
type: plan
status: In Review
summary: Right-clicking an Ask or Planning row in the sidebar offers the same menu as its list, sharing the delete confirmation instead of copying it.
issues: [andrew-waters/gannin#343]
touches: [andrew-waters/gannin]
owner: andrew-waters
---

# Context menu for Ask and Planning sidebar rows

## Approach

- [x] Ask: move the list's menu, rename alert and `deletesAsk` into one `askContextMenu(_:)` modifier, used by `AskSessionsList` and the sidebar.
- [x] Planning: move the delete confirmation and Delete Anyway alert out of `PlanningPage` into `deletesPlanning(_:)`; add `planningContextMenu(_:)` (Open, Delete) for the sidebar.
- [x] `SessionSidebarRows.row` picks the menu by session kind; other rows keep theirs.
- [x] Docs (`agents/ask.md`, `agents/planning.md`) and CHANGELOG.
