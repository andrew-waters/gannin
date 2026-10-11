---
paths:
  - "Gannin/Releases/**"
---

# Releases and milestones

- Never write to GitHub from here; it is read-only.
- Never delete `DownloadHistory` on Clear or sign-out; only `ReleaseStore.erase` (Erase Everything) may. GitHub keeps only running download totals, so it can't be refetched.
- Page a repo's releases to the end when it has more than the first query returns, and keep a repo's old star history when its stars can't be read.
- Fetch only once the page has been opened for an org; skip excluded repos no project names (`unfetchedRepos`).
- Milestones with the same title (case aside) across repos are one `MilestoneGroup`; don't treat them separately.
- A milestone's issue list can be shorter than GitHub's count: closed issues may predate the issue history.

## Testing
- `StarHistoryTests.swift` covers star bucketing (`ReleaseUsage.newStars`). Milestones, release linking and downloads have no tests; check by hand.
