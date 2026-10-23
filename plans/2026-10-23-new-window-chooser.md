---
type: plan
status: In Review
summary: File › New Window and New Tab ask which org and project the window opens on, starting on the window they were opened from, with a setting in Settings › General to copy that window instead.
issues: [andrew-waters/gannin#464]
domains: [app-shell]
touches: [andrew-waters/gannin]
owner: andrew-waters
---

# New windows ask which org and project to open

## Context

New Window and New Tab opened a main window with no scene storage, so it took `lastOrg` (the last
org picked in any window) and that org's last project. That's often not the window you were in.
Restored windows bring back their own org and project, and Open in New Window or New Tab from a
context menu or the palette already carries one through `WindowRequest.pending`.

## Decisions

- Only New Window and New Tab ask. Restored windows, the first window at launch and windows opened
  with a request don't: they already know where they're going.
- The chooser fills the window's content area rather than a sheet, with no org selected behind it,
  so nothing syncs for an org you didn't pick.
- It starts on the window it was opened from (a focused scene value), else the last org picked, so
  Return copies the current window.
- Esc (Same as Last Window) opens on that window's org and project: a new window never stays blank.
- With one account and no projects there's nothing to ask, so it opens straight away.
- Settings › General › Windows › Ask which organisation and project new windows open, on by
  default. Off, a new window copies the one it was opened from.

## Tasks

- [x] `WindowRequest.openBlank` and the focused window's place for New Window and New Tab
- [x] `WindowChooser` in a new window's content area, claimed in `MainView`
- [x] The setting in Settings › General
- [x] Docs: Orgs and projects, App tour, General settings; CHANGELOG; app-shell rule
