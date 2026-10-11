---
paths:
  - "Gannin/Sessions/Ask*"
  - "Gannin/Sessions/QuickChange*"
  - "Gannin/Sessions/PromptWriting*"
---
# Ask and Quick Change sessions

## Ask (`CodeSession.ask`, `AskInfo`)
- Always runs on this Mac (`connect` nil, local harness checkout), in the harness root with folder `.worktrees/ask-<date>-<id>/`: `.gannin/` (`askBrief`), `files/` (where claude is told to save output) and `context/` (`OrgContext.files` via `SessionStore.orgContext`, set by the app). `context/` is rewritten on every start and resume (`writeAskContext`) and copied in by the start script. Slug is the start day plus the first 8 characters of the session ID.
- `NewAskView` is a `PlanningDraft` with `isAsk`; prompts and skills come from `PromptUse.ask`. First prompt is the message plus a note of where things are (`askPrompt`).
- The Files pane (`SessionFiles`, `AskFilesRefresh`) lists everything in the folder except `.gannin/` and `context/` (max 1000) plus transcript `filesEdited` outside it. Refresh 400 ms after `changed`, when the transcript names a new file, and every 2s while shown, because MCP writes fire no hook.
- Only Commit to Harness (`CommitToHarnessSheet`, `AskCommit.swift`) commits an Ask's files, to `research/<date>-<id>/<name>` with a README (`ResearchFolder`). It needs a sensitive-data tickbox and Cancel is the default button so Return never commits.
- `finish` removes the folder and files (Delete Anyway when it won't go).
- Artifacts come from `SessionTranscript.artifacts` (results of the Artifact tool's publishes).

## Quick Change (`CodeSession.quickChange`, `QuickChangeInfo`)
- `NewQuickChangeView` over a `PlanningDraft` with `isQuickChange`. Form state is kept on the store by tab (`quickChangeForms`) and Start's progress and error too (`quickChangeProgress`), so leaving mid-start can't start it twice.
- `ScreenshotDropTarget` is an AppKit view reading the drag pasteboard (files, file promises, pictures) because the form's own views take a drag before SwiftUI drop destinations. Paste is ⌘V caught in the window only while the clipboard holds just pictures or image files, so text still pastes into the note. Images only, 20 MB each (`QuickChangeAttachment`).
- With an issue, Start files it assigned to you (`createIssue`), adds it to the workflow board (loading its definition if needed) and sets Status to the first in-progress option. A failure there is kept as `boardError` and shown; the session starts anyway.
- Without an issue, `issue` is a stand-in (number 0, `quick-<id>`), branch from `SessionStore.quickBranchName`, harness folder `sessions/<branch>` (`SessionRecord.issue` nil), and the brief says to put "Quick change, no issue." where `Closes` goes.
- Screenshots are copied into the session's `attachments/` (`attachmentNames`), then by `start.sh` into `.worktrees/<branch>/.gannin/attachments/` (a sandbox mounts it). To a server they go before the terminal starts, only those missing (`remoteAttachmentListScript`), one file per call on stdin through a part file (`remoteAttachmentScript`). Never uploaded to GitHub or committed unless Add the screenshots to the issue is on.
- Rows, notifications and helper prompts use `shortReference` / `longReference` (the picked repo, `issue.repo`, not the harness), never `#0`. Team prompts get `issueValues`: `{{issue}}` says quick change, `{{number}}` and `{{url}}` are empty.
- `quickChangePrompt` omits "propose a plan first"; with an issue it asks for it to be filled out with `gh issue edit` before changes, keeping images already in the description. Brief: `SessionBrief.quickChangeSections`.

## Write with Claude (`PromptWriting.swift`)
- One `ClaudeRunner` conversation (`--resume`, no tools); each reply is JSON with `message` and, once drafting, the whole `draft`. The current draft is sent with every later message (`PromptWriting.firstPrompt`, `followUp`, `reply`). `PromptWriting.Purpose` carries what's written and where it goes.
