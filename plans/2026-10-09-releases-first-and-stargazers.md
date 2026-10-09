---
type: plan
status: In Review
summary: The Releases page opens on Releases with Milestones second, fetches who starred each repo with releases, lists them, and charts new stars by week or month with releases marked, for every repo or one.
issues: [andrew-waters/gannin#69]
domains: [delivery]
touches: [andrew-waters/gannin]
owner: andrew-waters
---

# Releases first, and stargazers

## Context

Delivery › Releases opened on Milestones, with Releases second. Stars over time were already
there (andrew-waters/gannin#24): each repo with releases has its stargazers' `starredAt` fetched,
newest first and incrementally, drawn as one cumulative line across repos. Who starred wasn't
kept, there was no count of new stars per period, no way to look at one repo, and releases
weren't shown against the stars.

## Decisions

- Releases is the first part in the toolbar and where a window opens. Windows that saved
  Milestones keep it, as scene storage does elsewhere.
- Stargazer details come from the stargazers query already run for star dates: login, name,
  avatar, company, location and follower count on each edge's node. It stays one page of 100 a
  query (a point or two each), so the cost is about what it was. They're kept per repo, newest
  first, as far as the backfill reaches (`ReleaseStore.starReach`, 10,000). An account GitHub
  won't describe still counts as a star.
- The cache version goes to 4, so the next sync fetches milestones, releases and stars again
  once, with details. The download history is separate and unaffected.
- Only repos with releases, as before: every repo's stargazers would cost far more of the budget.
- A Repository menu in the Releases bar (All, or one repo, per window) narrows the tiles, charts
  and tables. Clicking a repo in the Repositories table picks it (and again shows them all), in
  place of filling the search.
- Stargazers is a table after Releases: avatar, login and name, repo, company, location,
  followers and when, newest first, sortable, searched by the bar's search, opening their
  profile. It shows the first 500 in the table's order, sorting before cutting so the most
  followed of all can be found.
- New stars are bars by week from Monday, by month once the history runs past six months, with
  quiet periods as zero. The cumulative line stays.
- Published releases (not drafts or pre-releases) are marked on the Stars line as dashed rules,
  named on hover; for one repo, or for all while there are no more than 30, so they never bury
  the line.

## Tasks

- [x] Releases first and the default part
- [x] Fetch stargazer details with their star dates, cache version 4
- [x] Repository menu narrowing the Releases part
- [x] Stargazers table
- [x] New stars by week or month, releases marked on the Stars line
- [x] Tests for the star history and buckets
- [x] CLAUDE.md
