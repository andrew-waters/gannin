---
paths:
  - "Gannin/Sessions/Refine*"
  - "Gannin/Meetings/RefinePage.swift"
---

# Design and Refine sessions

- Always run on this Mac (`connect` nil): the page opens in a web view here, so a server or sandbox can't hold it.
- Its `issue` is a stand-in (number 0, `refine-<id>`). Check `isRefine` wherever Ask and planning are left out of issue-only UI (Open Issue, the Issue pane, harness sections, pair review), or it shows `#0`.
- Its branch is its folder, `refine-<date>-<slug>`, made unique against other sessions' slugs (`refineSlug`); the harness record reuses the slug as `refines/<slug>/`, so don't change it after start.
- Claude is a co-reviewer that reads `projects/` and edits nothing; keep that in `refinePrompt` and `refineBrief` as features are added.
