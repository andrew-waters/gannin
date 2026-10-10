---
type: requirement
status: in-progress
summary: "Every rough edge the team agrees on during a walk-through leaves the session as a GitHub issue on the workflow board, and the session itself is kept in the harness as a record linking them."
issues: [andrew-waters/gannin#134]
plans: [plans/2026-10-10-design-and-refine.md]
---

# Design and Refine

## Problem

When the team walks through UI it has already shipped (often Gannin itself) and spots rough edges, the notes end up in chat or in people's heads, and few of them become issues.

## Goal

Every rough edge the team agrees on during a walk-through leaves the session as a GitHub issue on the workflow board, and the session itself is kept in the harness as a record linking them.

## Who it's for

The team reviewing shipped UI together, one facilitator driving on the shared screen.

## Requirements

1. Start a session from Rituals, picking the project, the repos whose code the page comes from (the project's first by default) and the page's URL
2. Record who is in the meeting when the session starts
3. Open a web page by URL in a web view inside Gannin and step through it together
4. Agreed findings become GitHub issues on the project's workflow board
5. The session is committed to the harness as a document linking its issues
6. Take screenshots of the page and annotate them (marks and text on the image)
7. Commit annotated screenshots to the session's record folder in the harness, with each issue linking to its images there
8. Paste or drop a meeting transcript (such as Google Meet's) after the session; Claude pulls candidate findings from it for the room to keep or dismiss
9. Claude scouts each captured finding in the code and adds where it lives (files, components) to it
10. Claude looks at the screenshots itself and suggests findings the room missed, for the room to keep or dismiss

## Out of scope

- Reviewing native apps (including Gannin itself) in the first version
- Fetching transcripts from Google Meet or Drive directly (no Google sign-in)
- Mapping URLs to repos in project settings, or Claude guessing the repo
- Asynchronous review: it's a live session run by one facilitator on the shared screen
- Hosting images on GitHub itself (#122)

## Acceptance criteria

- **R1** When the facilitator starts a Design and Refine session, the system shall ask for the project, one or more of its repos (the project's first by default) and a URL, and open the page in a web view inside Gannin.
- **R2** While a session is open, the system shall let the facilitator navigate the page (links, back, forward, reload, a new URL) without leaving the session.
- **R3** When the facilitator captures a finding, the system shall record its note, the page's URL and title at that moment, and the time.
- **R4** When the facilitator takes a screenshot, the system shall capture the visible page and let them annotate it with boxes, arrows and text before attaching it to a finding.
- **R5** When a finding is captured, Claude shall scout the picked repos and add to the finding where it most likely lives (files and components), without blocking further capture.
- **R6** When a screenshot is taken, Claude shall look at it and may suggest findings the room didn't raise; each suggestion shall be marked as Claude's until the room keeps or dismisses it.
- **R7** When the facilitator pastes or drops a meeting transcript, Claude shall propose candidate findings from it for the room to keep or dismiss, and the transcript itself shall stay on this Mac.
- **R8** When the room agrees the session, the system shall show every kept finding as an editable issue draft (title, description, repo) and, once confirmed, create each as a GitHub issue on the project's workflow board.
- **R9** When the room agrees the session, the system shall commit one record to the harness (a document listing the attendees and the findings with their issues, and the annotated screenshots beside it), and each issue shall link to its screenshots there.
- **R10** Before any screenshot is committed, the system shall show it with a sensitive-data warning and require it to be ticked, as Ask's Commit to Harness does; an unticked screenshot shall not be committed or linked.
- **R11** If Gannin quits or the session's tab closes before agreeing, the system shall keep the findings and screenshots on this Mac and resume the session when it is reopened.
- **R12** When the facilitator starts a session, the system shall ask who is in the meeting (the project's people to tick, plus names typed for anyone outside the org), let attendees be changed during the session, and list them in the harness record.

Planned in [plans/2026-10-10-design-and-refine.md](../plans/2026-10-10-design-and-refine.md).
