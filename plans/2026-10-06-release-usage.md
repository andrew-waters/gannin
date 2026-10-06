---
type: plan
status: In Review
summary: The Releases page lists every release of each repo, as a table, with downloads and stars per repo and downloads and stars over time at the top.
issues: [andrew-waters/gannin#24]
domains: [delivery]
touches: [andrew-waters/gannin]
owner: andrew-waters
---

# Every release, with downloads and stars

## Context

The Releases page only showed each repo's ten newest releases: the org query asked for
`releases(first: 10)` and never paged further. The page also gave no sign of use: no downloads or
stars.

## Decisions

- Every release: the org query takes each repo's first 25, and repos with more are paged to the
  end, 50 at a time, four repos at once. Every sync fetches every release again, as download counts
  change on old releases too.
- Downloads come from each release asset's `downloadCount`. GitHub only keeps running totals, so
  Gannin records each repo's total once a day (the day's last sync) in a file of its own,
  `ReleaseDownloads/<org>.json`, kept on this Mac. Storage's Clear and signing out keep it; Erase
  Everything removes it. The downloads line starts from the first sync. Until there's history,
  Downloads by release month (each release's downloads so far, by the month it came out) shows
  usage from day one.
- Stars over time are rebuilt from the stargazers connection's `starredAt`, fetched newest first
  and only since the last sync. The first backfill stops at 10,000 stars a repo, counting the rest
  at its start. Those who unstarred aren't in it, as in any star history built this way.
- "Main view" is the top of the Releases part of the Releases page, not the org Overview. Totals
  and charts cover repos with at least one release, pushed to in the last year and not excluded
  (narrowed to the window's project as everything else is).
- Releases and repos are `StatsTable`s, not a custom list.
- Downloads from gannin.ai don't reach the release's counts, as the site serves the DMG from
  andrew-waters/gannin-site. Moving the site and downloads here is andrew-waters/gannin#25.

## Tasks

- [x] Page every repo's releases, with assets and stars
- [x] Star history per repo, incremental, as its own sync step
- [x] Daily download snapshots, kept apart from the cache
- [x] Releases part: tiles, downloads and stars over time, Repositories and Releases tables
- [x] Release page: downloads and assets
- [x] CLAUDE.md
- [ ] Decisions noted on the issue
