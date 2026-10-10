---
type: plan
status: In progress
summary: Quick Change starts work on a small change from a note and screenshots in a chosen repo, as Work on This does for an issue, with or without a GitHub issue (asked each time); one with an issue goes on the workflow board in progress.
issues: [andrew-waters/gannin#123]
domains: [sessions]
touches: [andrew-waters/gannin]
owner: andrew-waters
---

# Quick Change

## Context

Work on This needs an issue. For a snag, a tweak or a one-line fix, writing the issue is more
work than the change, so those were skipped or done outside Gannin. The issue asked for a way to
type what to do, attach screenshots, pick the repo and start straight away, and left open whether
an issue is made, the branch name, where screenshots live, the board and metrics, and a size
limit.

## Decisions

- **Called Quick Change.** New Quick Change opens a tab in the Claude Code window, as New Ask
  does, from the sidebar (beside New Ask), the Claude Code window's +, Agents' toolbar and the
  palette.
- **An issue is asked for each time**, with a Create an issue checkbox in the tab (remembered on
  this Mac, `quickChangeCreatesIssue`, on by default).
  - With one: Gannin creates it from the note when Start is pressed (the button says so; it's the
    confirmation), adds it to the project's workflow board and sets its Status to the board's
    first in-progress status, then starts the session as Work on This would: the branch
    `<number>-short-title`, `sessions/<repo>-<number>` in the harness, `Closes` in the PR, and it
    counts in workload, cycle time and investments like any issue.
  - Without one: the branch is `quick-<short-title>-<4 hex of the session ID>`, the harness
    folder `sessions/quick-<same>`, and the PR says "Quick change, no issue." in place of
    `Closes`. PR metrics still count it (found by `head:<branch>` as ever); issue metrics and
    the board can't.
- **Screenshots stay with the session**, never uploaded or committed: copied into the session's
  folder (`attachments/`), copied by `start.sh` into `.worktrees/<branch>/.gannin/attachments/`
  (which a sandbox mounts), and sent over the shared ssh connection to a server before its
  terminal starts. The brief lists them for claude to read. GitHub has no API to attach images
  to an issue, and they may show customer data.
- **Size limit is a nudge**: the brief says it's meant to be small, needs no plan document, and
  to stop and say so if it turns out not to be, suggesting a proper issue.

## Approach

- `QuickChangeInfo` on `CodeSession` (`quickChange`: note, attachments, slug, whether it has an
  issue). Without an issue, `issue` is a stand-in as an Ask's is (number 0, `quick-<id>`), named
  for the repo, so the session's repo is right.
- `SessionStore.startQuickChange` makes the session, copies the screenshots and writes the brief
  (`SessionBrief.make` with the note as the description, a Screenshots section and a Quick
  change section; `Working here` without `Closes` or a plan when there's no issue).
- `SessionStore.harnessFolder(for: CodeSession)` and `record` cope with no issue
  (`SessionRecord.issue` optional).
- `QuickChangeForm` / `NewQuickChangeView` (`Sessions/QuickChange.swift`) over a `PlanningDraft`
  with `isQuickChange`: project, repository, note, screenshots (drop, paste, Add), Create an
  issue, prompts and skills for work, Run in (with sandboxing on), Record in the harness, Start.
- Tab kind Quick Change; the panel shows the note and screenshots; no Open Issue without one.

## Tasks

- [x] `QuickChangeInfo`, `startQuickChange`, branch and harness folder without an issue
- [x] Brief: note, screenshots, quick change rules, PR rule without an issue
- [x] Screenshots copied by `start.sh`, sent to a server over ssh
- [x] New Quick Change tab and its entry points
- [x] Issue made, put on the workflow board in progress
- [x] Tab and panel
- [x] `skills/create-pull-request.md` and `CLAUDE.md`
- [x] Tests
