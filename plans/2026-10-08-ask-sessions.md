---
type: plan
status: Done
summary: Ask sessions are open-ended Claude Code conversations in a tab of the Claude Code window, run in a project's harness on this Mac, replacing one-shot Ask, with their files committed to research/ only one at a time by hand.
issues: [andrew-waters/gannin#56, andrew-waters/gannin#57, andrew-waters/gannin#59, andrew-waters/gannin#60, andrew-waters/gannin#61]
domains: [sessions, harness]
touches: [andrew-waters/gannin]
owner: andrew-waters
---

# Ask sessions

## Context

The rest of [Ad hoc sessions in the Claude Code window](2026-10-08-in-the-window-with-plans-and-reviews-i.md)
after the Files pane ([2026-10-08-ask-files-pane.md](2026-10-08-ask-files-pane.md), #58): the
session itself (R2, R3, R11), starting one and replacing one-shot Ask (R1, R10), Commit to
Harness (R6), Research under Harness (R7), and keeping, resuming and deleting them (R8, R9).

## Decisions

- Called Ask throughout, as the plan's design decided: `CodeSession.ask` (`AskInfo`: title, slug,
  first message), not the issue's `adhoc`. Decoded with `decodeIfPresent`, so older sessions load.
- `startAsk` copies `startPlanning`: a synthetic `IssueReference` (`ask-<uuid>`, number 0), branch
  `ask-<date>-<id>` (the day it started and the first 8 characters of the session's ID, so it never clashes and matches the session), `connect` nil and the local harness
  checkout whatever Connect with says (R11), the first message as the prompt with a short note of
  where things are, and `launchInstructions(use: .ask)`.
- The org data is written by `SessionStore.writeAskContext` into the session's own folder in
  Application Support on every launch (start and resume), and the start script copies it into
  `.worktrees/ask-<date>-<id>/context/`. Writing it straight into the harness checkout would break the
  clone of a harness not checked out yet. The store gets it through `orgContext`, a closure the
  app sets, as it has the stores; the workload, metrics window and harness index are the defaults.
- A New Ask is a draft tab like New Plan (`PlanningDraft.isAsk`), so the tab plumbing is shared.
  The sidebar has no Ask row: a New Ask button at its top opens the tab straight away. A window
  saved on the old row shows Agents, which lists the Ask sessions.
- One-shot Ask (`AskOrgPage`, `AskConversations`) is gone; `OrgContext` stays.
- `HarnessChange` gains `data` (bytes, base64 as they are) with a 5 MB limit checked before
  sending; existing callers are unchanged.
- Commit to Harness is only in a file's menu in Files, after a divider, for files in the
  session's folder. Its sheet has Cancel as the default button and a tick box to enable Commit.
  The README for `research/<date>-<id>/`, named as the session's folder, is front matter (`type: research`, a summary) and the
  title, question and files as GitHub links; a later commit adds its line, read at the head.
- Research documents are each folder's README (`HarnessKind.research`); the Harness page has no
  New for them. `HarnessDocument.parserVersion` went up so cached indexes read them.
- Ask sessions don't offer Finish Session, which would delete their files after three quiet days.
  Delete, confirmed, is the only way they go.

## Tasks

- [x] #56 `AskInfo`, `startAsk`, the folder with `files/` and `context/`, the brief, Ask tab kind
- [x] #57 New Ask tab and form, the sidebar's New Ask button, + menu, Agents, palette; one-shot Ask removed
- [x] #59 Binary harness commits with a size limit; Commit to Harness sheet
- [x] #60 `HarnessKind.research`, listed under Harness and in the palette
- [x] #61 Ask sessions listed under Agents and the sidebar, with Open, Rename and Delete
- [x] CLAUDE.md
- [x] Check in the app: start one with Connect with set (runs here), `context/` holds the JSON, an
      old Sessions JSON loads, each entry point opens the draft, a CSV and a small PNG commit byte
      for byte with the README, an oversize file is refused, Research lists the folder, a
      relaunch lists and resumes Ask sessions, Delete leaves no folder
