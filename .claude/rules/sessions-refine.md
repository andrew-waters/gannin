---
paths:
  - "Gannin/Sessions/Refine*"
  - "Gannin/Meetings/RefinePage.swift"
---

# Design and Refine sessions

- Always run on this Mac (`connect` nil): the page opens in a web view here, so a server or sandbox can't hold it.
- Its `issue` is a stand-in (number 0, `refine-<id>`). Check `isRefine` wherever Ask and planning are left out of issue-only UI (Open Issue, the Issue pane, harness sections, pair review), or it shows `#0`.
- Its branch is its folder, `refine-<date>-<slug>`, made unique against other sessions' slugs (`refineSlug`); never change the branch after start. The record's `RefineInfo.slug` may move to a free one at Agree, but only before any issue is made (issues link into `refines/<slug>/`); `refineSlug` only sees this Mac's sessions, so Agree checks the harness.
- Claude is a co-reviewer that reads `projects/` and edits nothing but `refine.json`; keep that in `refinePrompt` and `refineBrief` (`RefineState.instructions`) as features are added.
- `refine.json` is snake case and read leniently (`RefineState.read`): never drop the file over one bad entry. Update `RefineState.instructions` whenever its shape changes.
- Call `writeRoomFile` (or `tellReviewer`) after any change to findings or screenshots: Claude reads `findings.json`, and a pasted note can be lost while claude isn't running.
- New fields on `RefineInfo` and its nested types must be optional: `CodeSession` decodes `refine` with `try?`, so a missing key drops the whole session's findings.
- Never commit, upload or quote `transcript.txt` or `originals/` anywhere: the transcript stays on this Mac (R7), and originals are unmarked copies the room never ticked.
- Never rename, re-encode or delete a screenshot once `isLocked`: issues and the record link to it by file name.
