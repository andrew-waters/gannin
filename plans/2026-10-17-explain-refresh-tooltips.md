---
type: plan
status: In Review
summary: Refresh's tooltip and Full Refresh's menu item say what each syncs, and each row in the sync detail says what its number counts.
issues: [andrew-waters/gannin#393]
domains: [sync]
touches: [andrew-waters/gannin]
owner: andrew-waters
---

# Explain what Refresh and Full Refresh sync

## Context

`SyncFooter` already had a `.help` on Refresh, but it only said "fetch what's changed". Full Refresh
is reachable by Option-click or the right-click menu only. Step rows in the sync detail show a title
and a bare number ("Items 120").

## Decisions

- The scope text is one constant, `SyncFooter.refreshExplanation`, written from `OrgRefresh` and
  `OrgStore.refresh`. It covers both modes, because a context menu item can't be hovered before it is
  opened. The Retry state shares the tooltip, with the failure on top.
- Full Refresh's menu item also gets its own `.help`.
- Row meanings live in `SyncStepHelp`, keyed by run kind and step id, because ids repeat across runs.
  They go in the row's existing tooltip rather than renaming titles, so no sync code changes.
- The progress panel's scope is part of this issue: it's the same file and small.
- No VoiceOver change: `.help` already sets the accessibility hint.

## Tasks

- [x] Refresh tooltip and Full Refresh menu help
- [x] Per-row "counts" line in the sync detail
- [x] Docs (`guides/app-tour.md`; `keyboard-shortcuts.md` and the others need no change)
- [x] Changelog line
