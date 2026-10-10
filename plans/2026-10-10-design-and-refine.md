---
type: plan
status: in-progress
summary: "A ceremony for a team to step through a running app or web page together, capture improvement notes, screenshots and annotations, and scout the code, ending in issues."
issues: [andrew-waters/gannin#134, andrew-waters/gannin#135, andrew-waters/gannin#136, andrew-waters/gannin#137, andrew-waters/gannin#138, andrew-waters/gannin#139, andrew-waters/gannin#140, andrew-waters/gannin#141, andrew-waters/gannin#142]
touches: [andrew-waters/gannin]
owner: andrew-waters
agreed_by: [andrew-waters]
agreed_at: 2026-10-10
requirement: requirements/design-and-refine.md
---

# Design and Refine

A ceremony for a team to step through a running app or web page together, capture improvement notes, screenshots and annotations, and scout the code, ending in issues.

## Context

- Also looked at: This is a new feature for a cermony) that allows a team to come togehter, open a webpage (in gannin) or app outside of gannin, and then to step through it, capture notes for improvements, plus scouting the codebase. possible features include screenshots, annotations, meeting notes (trhese can come from external sources like google meet transcription) and anything else you can think of within this category. It's somewhere between plannign and issues. the list of thoughts is not exhaustive

## Requirement

In full in [requirements/design-and-refine.md](../requirements/design-and-refine.md).

**Problem:** When the team walks through UI it has already shipped (often Gannin itself) and spots rough edges, the notes end up in chat or in people's heads, and few of them become issues.

**Goal:** Every rough edge the team agrees on during a walk-through leaves the session as a GitHub issue on the workflow board, and the session itself is kept in the harness as a record linking them.

**Who it's for:** The team reviewing shipped UI together, one facilitator driving on the shared screen.

**Scope:**

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

**Out of scope:**

- Reviewing native apps (including Gannin itself) in the first version
- Fetching transcripts from Google Meet or Drive directly (no Google sign-in)
- Mapping URLs to repos in project settings, or Claude guessing the repo
- Asynchronous review: it's a live session run by one facilitator on the shared screen
- Hosting images on GitHub itself (#122)

**Acceptance criteria:**

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

**Decisions:**

- Who has the problem? **The team reviewing shipped UI together: rough edges get spotted, but the notes are lost and few become issues.**
- What does a session produce? **Issues for the agreed findings, plus a record of the session in the harness linking them.**
- What does the team step through in the first version? **Web pages, opened by URL in a web view inside Gannin, so pages can be screenshotted and annotated directly. Native apps are left out.**
- How do screenshots reach the issues? **Annotated screenshots are committed to the session's record folder in the harness and each issue links to its images there. Only people with harness access can see them.**
- Meeting notes from outside, such as a Google Meet transcript? **In v1 as paste or drop: Claude pulls candidate findings from the transcript for the room to keep or dismiss. No direct Google integration.**
- What does Claude do during the session? **Full co-reviewer: scouts each finding in the code, and looks at the screenshots to suggest findings the room missed. Suggestions are kept or dismissed by the room.**
- How does Claude know which repo's code a page comes from? **The repos are picked when the session starts (the project's first by default), as Quick Change does.**
- From the room **Who is in the meeting is recorded up front when the session starts, and kept in the record.**
- Are R1-R12 right for the first version? **Yes, approved as written.**

## Design

A new session kind, **Design and Refine**, built the way Planning sessions are: a draft tab in the Claude Code window, then a session in the project's harness with its own info on `CodeSession`, a workspace view instead of a bare terminal, and Claude keeping a JSON state file Gannin reads on each `changed`.

- **Start (R1, R12):** `NewRefineView` over a `PlanningDraft` with `isRefine`: project, repos (the project's first ticked), URL, attendees (the project's people to tick, names typed for others). `SessionStore.startRefine` makes the session with `RefineInfo` (url, repos, attendees, findings, screenshots, transcript name, agreed). Its folder is `.worktrees/refine-<date>-<slug>/`, outside git.
- **Workspace (R2-R4):** `RefineWorkspaceView`: the page in a SwiftUI `WebView` (`WebPage`, macOS 26) with back, forward, reload and an address field, beside a findings panel in a `FixedSplit`, the terminal in a drawer as planning has it. Capture: a note box (⌘↩) that stamps URL, title and time; Screenshot snaps the visible page into an annotation sheet (boxes, arrows, text drawn on a `Canvas`, kept as shapes so they can be edited, flattened to PNG with `ImageRenderer`). Files go in the session folder's `screenshots/`.
- **Claude as co-reviewer (R5-R7):** the session is told it's a refinement co-reviewer, runs in the harness root with the picked repos' clones in `projects/` to read, and edits nothing but `refine.json`. Each finding and screenshot is pasted to it as it's made (`SessionStore.submit`, queued while it works); it writes back per finding `scouting` (files, components, a line on why) and `suggestions` (its own findings, marked as Claude's, with the screenshot they came from). The room keeps or dismisses a suggestion and it joins the findings. A transcript dropped or pasted is saved as `transcript.txt` in the folder (never committed) and Claude proposes findings from it the same way.
- **Agree (R8-R10):** `RefineAgreeSheet`, modelled on `PlanningAgreeSheet`: each kept finding as an editable issue draft (title, body with scouting, repo), each screenshot with a preview, a sensitive-data warning and a tick (`CommitToHarnessSheet`'s pattern). On Agree: create the issues on the workflow board, each linking to its screenshots' paths, then one harness commit of the record and ticked screenshots (more than one commit if they pass the size limit), record `agreed` and tell claude.
- **Resume (R11):** `RefineInfo` is saved with the session, so findings and screenshots survive quitting; the web view reopens on the last URL.

Why this shape: it reuses the planning session's machinery (tabs, state file, `changed`, Agree, resume) rather than a new kind of page, and the paste-and-state-file loop is already proven local and over ssh.

- **Record (R9):** a new harness kind, `HarnessKind.refines`: `refines/<date>-<slug>/README.md` (front matter type `refine`, status, summary, attendees, url, issues, touches) with the ticked screenshots beside it. Listed as Refines under Harness in the sidebar and given a Harness page like the others; `HarnessSkeleton` and `HarnessTour` gain the folder so new harnesses have it.
- **Web logins:** each project gets its own persistent `WKWebsiteDataStore(forIdentifier:)`, its UUID kept on this Mac per harness repo, so a staging login lasts between sessions. Sign Out of Pages (in the session's bar and Settings › Storage) removes that store. `Info.plist` gains `NSAllowsArbitraryLoadsInWebContent` so http pages (localhost, staging) load in the web view only; the app's own requests stay under ATS.

**Areas it touches:**

- `andrew-waters/gannin` `Gannin/Sessions/SessionScript.swift#L28`: Reviewers run with edits disallowed. Claude here needs to write only its state file, so it runs as planning does (in the harness, no code repo worktrees), told not to edit code.

**Patterns to follow:**

- `andrew-waters/gannin` `Gannin/Meetings/FieldCapture.swift`: Prioritisation's capture panel: notes taken as they're said, kept per project as a team file, linked to or raised as issues. The nearest thing to capturing refinement notes.
- `andrew-waters/gannin` `Gannin/Sessions/QuickChange.swift`: Screenshot drop, paste and add (ScreenshotDropTarget, QuickChangeAttachment), kept with the session and never uploaded.
- `andrew-waters/gannin` `plans/2026-10-08-planning-ceremony.md`: Live ceremony on the shared screen, Claude working behind structured state, Agree writes to the harness and GitHub.
- `andrew-waters/gannin` `Gannin/Sessions/PlanningSession.swift#L6-L46`: PlanningInfo on CodeSession: a session kind with its own info, kept with the session across launches (so resume comes free, R11), started from a draft tab (PlanningDraft) in the Claude Code window. Design and Refine follows this as RefineInfo / isRefine.
- `andrew-waters/gannin` `Gannin/Sessions/PlanningWorkspace.swift#L245-L260`: Claude keeps a JSON state file in .worktrees/<branch>/ that Gannin reads again on each `changed` signal, local or over ssh. Claude's scouting and suggestions per finding go in refine.json the same way.
- `andrew-waters/gannin` `Gannin/Sessions/PlanningAgree.swift#L274-L350`: Agree: make the issues (createIssue, addToProject on the workflow board), then one harness commit, then record the agreement and tell claude. The Design and Refine Agree sheet copies this order, so issues can link to paths committed straight after.
- `andrew-waters/gannin` `Gannin/Sessions/AskCommit.swift#L64-L170`: CommitToHarnessSheet: Quick Look preview, sensitive-data warning, a box to tick, Cancel as default. Each screenshot gets the same treatment at Agree (R10).
- `andrew-waters/gannin` `Gannin/Sessions/QuickChange.swift#L48-L110`: Screenshots copied into the session's folder with safe names (attachmentNames); ScreenshotDropTarget for drop and paste. Reuse for screenshots and the transcript drop.
- `andrew-waters/gannin` `Gannin/Meetings/FieldCapture.swift#L10-L260`: Capture panel: type a note, ⌘↩ to add, rows with link-to-issue. The findings list follows its feel.

**Risks:**

- `andrew-waters/gannin` `andrew-waters/gannin#122`: GitHub has no public API to attach images to issues; screenshots in issues needs a hosting decision first.
- `andrew-waters/gannin` `Gannin/Sessions/AskCommit.swift`: Committing screenshots puts whatever is on screen into git history for good. Quick Change chose never to commit them for this reason; Ask's Commit to Harness has a preview, a sensitive-data warning and a box to tick, which this should follow.
- `andrew-waters/gannin` `project.yml`: No WebKit anywhere in the app yet. macOS 26 is the target, so SwiftUI's WebView/WebPage are available; snapshots may still need WKWebView.takeSnapshot. Plain http (localhost, staging) is blocked by App Transport Security without NSAllowsArbitraryLoadsInWebContent or NSAllowsLocalNetworking in Info.plist.
- `andrew-waters/gannin` `Gannin/Harness/HarnessWrites.swift#L14`: Harness commits refuse any file over 5 MB and go through GraphQL in one payload. Full-page retina PNGs can be large: screenshots should be the visible viewport, downscaled or JPEG, and many images may need more than one commit.
- `andrew-waters/gannin` `andrew-waters/gannin#122`: Images linked from issues to a private harness only render for people with access to it; anyone else sees a broken image.

**Decisions:**

- Where does a session's record go in the harness? **A new refines/ folder: refines/<date>-<slug>/README.md with its screenshots beside it, as its own harness kind.**
- Should web view sign-ins persist between sessions? **Yes, per project: each project has its own cookie and login store, with Sign Out of Pages to clear it.**
- Is the design right? **Yes, approved as written.**

## Tasks

1. [andrew-waters/gannin#135](https://github.com/andrew-waters/gannin/issues/135) Add refines/ as a harness kind (satisfies R9)
2. [andrew-waters/gannin#136](https://github.com/andrew-waters/gannin/issues/136) Start a Design and Refine session: project, repos, URL and attendees (satisfies R1, R12, R11)
3. [andrew-waters/gannin#137](https://github.com/andrew-waters/gannin/issues/137) Refine workspace: the page in a web view with per-project logins (satisfies R2, R11)
4. [andrew-waters/gannin#138](https://github.com/andrew-waters/gannin/issues/138) Capture findings in the refine workspace (satisfies R3, R11)
5. [andrew-waters/gannin#139](https://github.com/andrew-waters/gannin/issues/139) Screenshot and annotate the page (satisfies R4)
6. [andrew-waters/gannin#140](https://github.com/andrew-waters/gannin/issues/140) Claude as co-reviewer: scouting and suggested findings (satisfies R5, R6)
7. [andrew-waters/gannin#141](https://github.com/andrew-waters/gannin/issues/141) Paste or drop a meeting transcript (satisfies R7)
8. [andrew-waters/gannin#142](https://github.com/andrew-waters/gannin/issues/142) Agree: make the issues and commit the record (satisfies R8, R9, R10)

**Decisions:**

- Are the eight tasks right? **Yes, approved as written.**

## From the room

- we should record upfront who is in the meeting as well (requirements)
