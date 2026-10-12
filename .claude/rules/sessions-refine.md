---
paths:
  - "Gannin/Sessions/Refine*"
  - "Gannin/Meetings/RefinePage.swift"
---

# Design and Refine sessions

- Always run on this Mac (`connect` nil): the page opens in a web view here, so a server or sandbox can't hold it.
- Its `issue` is a stand-in (number 0, `refine-<id>`). Check `isRefine` wherever Ask and planning are left out of issue-only UI (Open Issue, the Issue pane, harness sections, pair review), or it shows `#0`.
- Its branch is its folder, `refine-<date>-<slug>`, made unique against other sessions' slugs (`refineSlug`); the harness record reuses the slug as `refines/<slug>/`, so don't change it after start.
- Claude is a co-reviewer that reads `projects/` and edits nothing but `refine.json`; keep that in `refinePrompt` and `refineBrief` (`RefineState.instructions`) as features are added.
- `refine.json` is snake case and read leniently (`RefineState.read`): never drop the file over one bad entry. Update `RefineState.instructions` whenever its shape changes.
- Call `writeRoomFile` (or `tellReviewer`) after any change to findings or screenshots: Claude reads `findings.json`, and a pasted note can be lost while claude isn't running.
- New fields on `RefineInfo` and its nested types must be optional: `CodeSession` decodes `refine` with `try?`, so a missing key drops the whole session's findings.
