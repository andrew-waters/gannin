---
type: plan
status: In Review
summary: An Ask session's tab lists the files it wrote, in its folder and elsewhere, beside the terminal in place of Changes, each to open, drag out, open with, reveal, save a copy of or copy.
issues: [andrew-waters/gannin#58]
domains: [sessions]
touches: [andrew-waters/gannin]
owner: andrew-waters
---

# Ask tab: Files pane

## Context

Part of [Ad hoc sessions in the Claude Code window](2026-10-08-in-the-window-with-plans-and-reviews-i.md),
satisfying R4 and R5: while an Ask session is open, every file written in its folder (by Claude's
edits, a script or an MCP tool) is listed within seconds with its name, size and time, and can be
opened, opened with, revealed, saved elsewhere or dragged into another app without Finder.

## Decisions

- Ask sessions themselves (`CodeSession.adhoc`, the `ask-<slug>` folder with `files/` and
  `context/`) come with andrew-waters/gannin#56, which hadn't landed. Until then
  `CodeSession.isAsk` goes by the branch, `ask-` and not a review or plan, so the pane can be tried
  on any session on such a branch; #56 can point it at its own info.
- The list is the session's folder walked off the main actor (`SessionFiles.scan`): everything
  but `.gannin/` and `context/` (Gannin's), `.git`, `node_modules` and `.DS_Store`, at most 1000
  files, plus the transcript's `filesEdited` outside the folder that still exist, under Elsewhere.
  Newest first. A file in a folder other than `files/` says which.
- It's read 400 ms after each `changed` signal, again when the transcript names a new file, and
  every two seconds while the pane shows, since an MCP tool's write fires no hook. The list only
  changes when what's found does, so the poll doesn't redraw it.
- Files replaces Changes in the pane picker for an Ask session (one remembered pane suits both),
  and the git read for Changes is skipped there: the folder isn't a worktree.
- Drag is an `NSItemProvider(contentsOf:)` for the file, which AppKit offers as a file promise as
  well as its URL. Copy puts the file URL on the pasteboard, as Finder's Copy does. Save a Copy
  asks with a save panel (Downloads first) and copies, the panel having asked about replacing.
- Commit to Harness isn't in the menu yet: andrew-waters/gannin#59 adds it, set apart at the end.

## Tasks

- [x] `SessionFiles`: scan the folder and transcript paths, kept per session in `SessionStore`
- [x] `SessionFilesPane`: rows with icon, name, location, size and time; click opens; drag out
- [x] Context menu: Open, Open With, Show in Finder, Save a Copy, Copy
- [x] Refresh on `changed`, on new transcript paths and on a two-second poll
- [x] Files in place of Changes for Ask sessions in `SessionTab`
- [x] CLAUDE.md
- [ ] Check in the app once #56 starts Ask sessions: Write, Bash and MCP files appear within seconds; drag into Mail attaches; Save a Copy writes elsewhere
