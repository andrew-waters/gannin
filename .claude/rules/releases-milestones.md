---
paths:
  - "Gannin/Releases/**"
---

# Releases and milestones

- Read-only: nothing is written to GitHub.
- `ReleaseStore` fetches in one paged query (`GitHubAPI.milestonesAndReleases`, 25 repos a page) every non-archived repo pushed to in the last year (`quietReach`): 25 open milestones, the ten most recent closed, stars, 25 newest releases with assets' `downloadCount`. Repos with more releases page to the end (`GitHubAPI.releases(repo:after:)`, 50 a page).
- Star history (`StarHistory`, `Stargazer`, `GitHubAPI.stargazers`) is fetched for repos with releases, newest first and only since the last sync. The first backfill stops at `ReleaseStore.starReach` and counts older stars at its start. A repo whose stars can't be read keeps what it had. Repos are processed four at a time (`eachRepo`).
- Cached as JSON in Application Support/Releases; refetched after its Settings › Sync interval, only once the page has been opened; Refresh then includes it. Its own sync run (milestones and releases, older releases, stars). Excluded repos no project names aren't kept (`unfetchedRepos`); views drop the rest via `repoExclusion`.
- GitHub keeps only running download totals, so each sync records the day's (`DownloadHistory`, Application Support/ReleaseDownloads, one snapshot a day, the last wins). It cannot be refetched: Storage's Clear and sign-out keep it; only Erase Everything removes it (`ReleaseStore.erase`). Keep that when touching clear paths.
- Milestones with the same title (case aside) across repos are one `MilestoneGroup` (counts summed, due the soonest open one's). Progress is GitHub's closed of all issues and PRs. `MilestoneActivity` adds in-progress and merged-PR counts from the issue history, looked up through `MilestoneGroup.index`, built once per render.
- `ReleaseLink` matches a milestone to the first published release whose tag or name equals its title (case and a leading `v` aside) in one of its repos. A milestone's issue list can be shorter than GitHub's count when closed ones predate the history.
- `StargazersSection` merges, searches and sorts only when inputs change and shows the first 500. Accounts GitHub won't describe count as stars but aren't listed.
- Drill-downs: `DetailSelection.milestone(title)` / `.release`; the page part is `releasesPart` per window, repo filter `releasesRepo` per window.
