---
paths:
  - "Gannin/Sessions/Ask*"
  - "Gannin/Sessions/QuickChange*"
  - "Gannin/Sessions/PromptWriting*"
---
# Ask, Quick Change, Write with Claude

## Ask
- Always run on this Mac in the local harness checkout (`connect` nil). Folder layout is `.worktrees/ask-<date>-<id>/` with `.gannin/`, `files/` and `context/`; the brief and `AskFilesRefresh` depend on it.
- Rewrite `context/` on every start and resume (`writeAskContext`); never treat it as user data.
- Keep refreshing the Files pane on a timer (`refreshWhileActive`, so only while Gannin is the active app) as well as on `changed`: MCP writes fire no hook.
- Only Commit to Harness (`CommitToHarnessSheet`) commits an Ask's files, to `research/<date>-<id>/<name>` with a README. Cancel stays the default button so Return never commits, and Commit stays disabled until the sensitive-data box is ticked.
- Ask sessions never offer Finish and Clean Up. Delete, from the list or the Ask's own tab, removes the folder and its files.

## Quick Change
- Keep form state and Start progress on the store (`quickChangeForms`, `quickChangeProgress`), not the view: leaving mid-start must not start it twice.
- Read drags in `ScreenshotDropTarget` (AppKit), because the form's views take drags before SwiftUI drop destinations. Handle ⌘V only when the clipboard holds just pictures, so text still pastes.
- A failed board update is kept as `boardError`; the session must still start.
- Without an issue, `issue` is a stand-in (number 0): never show `#0`; use `shortReference` / `longReference`. Team prompts get empty `{{number}}` and `{{url}}`.
- Never upload screenshots to GitHub or commit them unless Add the screenshots to the issue is on.

## Write with Claude
- Send the whole current draft with every follow-up (`PromptWriting.followUp`), since the conversation has no tools and edits can be made by hand.

## Testing
`QuickChangeTests` and `PromptWritingTests` exist. Ask sessions and `CommitToHarnessSheet` have no tests.
